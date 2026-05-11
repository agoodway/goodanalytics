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
  alias GoodAnalytics.Hooks
  alias GoodAnalytics.Maps
  alias GoodAnalytics.PubSub
  alias GoodAnalytics.Repo

  import Ecto.Query

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
  def record(visitor, event_type, attrs \\ %{}) do
    repo = Repo.repo()

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

    event_attrs =
      attrs
      |> Map.drop([:connector_signals])
      |> Map.merge(%{
        workspace_id: visitor.workspace_id,
        visitor_id: visitor.id,
        event_type: event_type,
        source_platform: get_in_source(attrs, :platform),
        source_medium: get_in_source(attrs, :medium),
        source_campaign: get_in_source(attrs, :campaign),
        connector_source_context: connector_source_context
      })

    changeset =
      Event.changeset(
        %Event{id: Uniq.UUID.uuid7(), inserted_at: DateTime.utc_now()},
        event_attrs
      )

    case repo.insert(changeset, prefix: GoodAnalytics.schema_name()) do
      {:ok, event} ->
        broadcast_event(event)
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
