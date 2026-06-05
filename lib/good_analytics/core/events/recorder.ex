defmodule GoodAnalytics.Core.Events.Recorder do
  @moduledoc """
  Records events into the unified event stream.

  Populates promoted columns from source classification at ingest time,
  generates UUIDv7 IDs, broadcasts workspace event notifications, and
  fires appropriate hooks after insert.

  The JS client may include an `event_id` idempotency key for host-app
  ingest layers. The recorder deliberately ignores that value for
  `ga_events.id`: the event stream primary key is `(id, inserted_at)` on a
  partitioned table, so idempotency must happen before this recorder runs.
  """

  alias GoodAnalytics.Connectors.{PostCommit, Signals}
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Events.UrlNormalizer
  alias GoodAnalytics.Core.Sessions
  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Devices
  alias GoodAnalytics.Hooks
  alias GoodAnalytics.Maps
  alias GoodAnalytics.PubSub
  alias GoodAnalytics.Repo

  import Ecto.Query

  @event_device_fields ~w(device_type browser os browser_version os_version device_brand device_model bot_name)a
  @event_device_field_strings Enum.map(@event_device_fields, &Atom.to_string/1)
  @record_drop_keys [
                      :connector_signals,
                      "connector_signals",
                      :url,
                      "url",
                      :user_agent,
                      "user_agent"
                    ] ++
                      @event_device_fields ++ @event_device_field_strings

  @doc """
  Records a generic event.

  ## Parameters

    * `visitor` - the visitor struct (must have `:id` and `:workspace_id`)
    * `event_type` - one of the valid event types
    * `attrs` - additional event attributes

  Returns `{:ok, event}` or `{:error, changeset}`.

  **Important:** Hooks are dispatched immediately after insert. Connector
  planning uses a durable post-commit handoff when available so caller-owned
  transactions do not leak dispatches on rollback.
  """
  def record(visitor, event_type, attrs \\ %{})

  def record(visitor, "engagement", attrs) do
    record_engagement_event(visitor, attrs)
  end

  def record(visitor, event_type, attrs) do
    repo = Repo.repo()
    now = DateTime.utc_now()

    connector_signals = Map.get(attrs, :connector_signals, %{})

    connector_source_context =
      if map_size(connector_signals) > 0 do
        Signals.build_source_context(connector_signals,
          visitor_id: visitor.id,
          event_type: event_type,
          source: Map.get(attrs, :source, %{}),
          amount_cents: Map.get(attrs, :amount_cents),
          currency: Map.get(attrs, :currency)
        )
      end

    raw_url = Map.get(attrs, :url) || Map.get(attrs, "url")
    raw_ua = Map.get(attrs, :user_agent) || Map.get(attrs, "user_agent")
    device = Devices.parse(raw_ua)

    event_attrs =
      attrs
      |> Map.drop(@record_drop_keys)
      |> Map.merge(%{
        workspace_id: visitor.workspace_id,
        visitor_id: visitor.id,
        event_type: event_type,
        url: raw_url,
        user_agent: raw_ua,
        host: UrlNormalizer.host(raw_url),
        path: UrlNormalizer.path(raw_url),
        source_platform: get_in_source(attrs, :platform),
        source_medium: get_in_source(attrs, :medium),
        source_campaign: get_in_source(attrs, :campaign),
        connector_source_context: connector_source_context
      })
      |> Map.merge(Devices.to_event_attrs(device))

    changeset =
      Event.changeset(
        %Event{id: Uniq.UUID.uuid7(), inserted_at: now},
        event_attrs
      )
      |> maybe_put_session_id(visitor, event_type, event_attrs, attrs, now)

    case repo.insert(changeset, prefix: GoodAnalytics.schema_name()) do
      {:ok, event} ->
        broadcast_event(event)
        maybe_enrich_device(visitor, device)
        dispatch_hook(event_type, event, visitor)
        PostCommit.maybe_dispatch(event, attrs)
        {:ok, event}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc "Records a link click event."
  def record_click(visitor, link, attrs) do
    {qr, attrs} = Map.pop(attrs, :qr)

    properties =
      attrs
      |> Map.get(:properties, %{})
      |> then(fn props -> if qr, do: Map.put(props, "qr", true), else: props end)

    attrs =
      attrs
      |> Map.put(:link_id, link.id)
      |> Map.put(:properties, properties)

    record(visitor, "link_click", attrs)
  end

  @doc "Records a pageview event."
  def record_pageview(visitor, attrs) do
    record(visitor, "pageview", attrs)
  end

  @doc "Records a lead event."
  def record_lead(visitor, attrs) do
    record(visitor, "lead", attrs)
  end

  @doc "Records a sale event."
  def record_sale(visitor, attrs) do
    record(visitor, "sale", attrs)
  end

  @doc "Records a custom event."
  def record_custom(visitor, event_name, attrs) do
    record(visitor, "custom", Map.put(attrs, :event_name, event_name))
  end

  @doc """
  Backfills fingerprint on a previously recorded link click by click_id.

  This is used by destination-page beacons after a redirect click creates the initial
  `link_click` row without browser-only fingerprint signals.
  """
  def backfill_link_click_fingerprint(click_id, fingerprint) do
    repo = Repo.repo()

    with {:ok, click_id} <- Ecto.UUID.cast(click_id),
         true <- is_binary(fingerprint) and String.trim(fingerprint) != "" do
      {updated, _} =
        from(e in Event,
          where: e.event_type == "link_click",
          where: e.click_id == type(^click_id, Ecto.UUID),
          where: is_nil(e.fingerprint)
        )
        |> repo.update_all([set: [fingerprint: fingerprint]], prefix: GoodAnalytics.schema_name())

      {:ok, updated}
    else
      _ -> {:ok, 0}
    end
  end

  # Extract source fields from the attrs map's :source key or promoted fields
  defp get_in_source(attrs, key) do
    case Maps.get_indifferent(attrs, key) do
      nil -> get_from_source_map(Map.get(attrs, :source), key)
      value -> normalize_source_value(value)
    end
  end

  defp get_from_source_map(%{} = source, key) do
    source
    |> Maps.get_indifferent(key)
    |> normalize_source_value()
  end

  defp get_from_source_map(_source, _key), do: nil

  defp normalize_source_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_source_value(value), do: value

  defp broadcast_event(event) do
    message = {:event_recorded, event}

    Phoenix.PubSub.broadcast(
      PubSub,
      "good_analytics:events:#{event.workspace_id}",
      message
    )
  end

  # First-event-wins device enrichment. Best-effort: runs after the insert has
  # committed, ignores the conditional-update result (0 rows just means already
  # populated), and never lets an enrichment error crash record/3 or skip the
  # downstream hook/connector dispatch.
  defp maybe_enrich_device(visitor, device) do
    Visitors.maybe_set_device(visitor.id, device)
    :ok
  rescue
    _ -> :ok
  end

  defp maybe_put_session_id(
         %Ecto.Changeset{valid?: false} = changeset,
         _visitor,
         _event_type,
         _event_attrs,
         _attrs,
         _now
       ) do
    changeset
  end

  defp maybe_put_session_id(changeset, visitor, event_type, event_attrs, attrs, now) do
    session_id =
      case maybe_sessionize(visitor, event_type, event_attrs, attrs, now) do
        {:ok, session} -> session.id
        _ -> nil
      end

    Ecto.Changeset.put_change(changeset, :session_id, session_id)
  end

  # Engagement events attach to an existing live session in Task 7. Keep this
  # path best-effort so a sessionization failure never drops the event.
  defp maybe_sessionize(_visitor, "engagement", _event_attrs, _attrs, _now), do: :no_session

  defp maybe_sessionize(visitor, event_type, event_attrs, attrs, now) do
    key = %{
      workspace_id: visitor.workspace_id,
      visitor_id: visitor.id,
      anonymous_id: Map.get(attrs, :anonymous_id) || Map.get(attrs, "anonymous_id")
    }

    Sessions.sessionize(key, event_type, Map.put(event_attrs, :__ts__, now))
  rescue
    error ->
      require Logger
      Logger.debug("GoodAnalytics: sessionize failed: #{inspect(error)}")
      :no_session
  end

  defp record_engagement_event(visitor, attrs) do
    key = %{
      workspace_id: visitor.workspace_id,
      visitor_id: visitor.id,
      anonymous_id: Map.get(attrs, :anonymous_id) || Map.get(attrs, "anonymous_id")
    }

    ts = DateTime.utc_now()
    changeset = engagement_event_changeset(visitor, nil, attrs, ts)

    if changeset.valid? do
      case Sessions.record_engagement(key, attrs, ts) do
        {:ok, session} -> insert_engagement_event(visitor, session, attrs, ts)
        :no_session -> {:ok, :dropped}
      end
    else
      {:error, changeset}
    end
  end

  defp insert_engagement_event(visitor, session, attrs, ts) do
    repo = Repo.repo()

    visitor
    |> engagement_event_changeset(session.id, attrs, ts)
    |> repo.insert(prefix: GoodAnalytics.schema_name())
  end

  defp engagement_event_changeset(visitor, session_id, attrs, ts) do
    properties =
      engagement_properties(attrs)

    raw_url = Map.get(attrs, :url) || Map.get(attrs, "url")

    event_attrs = %{
      workspace_id: visitor.workspace_id,
      visitor_id: visitor.id,
      session_id: session_id,
      event_type: "engagement",
      url: raw_url,
      host: UrlNormalizer.host(raw_url),
      path: UrlNormalizer.path(raw_url),
      properties: properties
    }

    %Event{id: Uniq.UUID.uuid7(), inserted_at: ts}
    |> Event.changeset(event_attrs)
  end

  defp engagement_properties(attrs) do
    case Map.get(attrs, :properties, %{}) do
      props when is_map(props) ->
        props
        |> put_if(attrs, :engaged_ms, "engaged_ms")
        |> put_if(attrs, :scroll_depth, "scroll_depth")

      other ->
        other
    end
  end

  defp put_if(props, attrs, key, string_key) do
    case Map.get(attrs, key) || Map.get(attrs, string_key) do
      nil -> props
      value -> Map.put(props, string_key, value)
    end
  end

  # Link click hooks are sync, but from the recorder they're async
  # (sync dispatch only happens in the redirect path directly)
  defp dispatch_hook("link_click", event, visitor) do
    Hooks.notify_async(:link_click, event, visitor)
  end

  defp dispatch_hook(event_type, event, visitor) do
    hook_type = String.to_existing_atom(event_type)
    Hooks.notify_async(hook_type, event, visitor)
  rescue
    ArgumentError -> :ok
  end
end
