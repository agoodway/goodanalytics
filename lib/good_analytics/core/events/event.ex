defmodule GoodAnalytics.Core.Events.Event do
  @moduledoc """
  Unified event stream record.

  Events are append-only and partitioned by month. Source classification
  fields (`source_platform`, `source_medium`, `source_campaign`) and
  revenue fields (`amount_cents`, `currency`) are promoted to top-level
  columns for OLAP readiness.
  """

  use Ecto.Schema
  import Ecto.Changeset

  # Composite primary key matches the DB definition `(id, inserted_at)`,
  # required by Postgres for partitioned tables. Use
  # `GoodAnalytics.Core.Events.get_by_id/1` when you only have an id;
  # `Repo.get(Event, id)` is unsafe with composite keys.
  @primary_key false
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @event_types ~w(link_click pageview session_start identify lead sale share engagement custom api_request)
  @ingest_types ~w(link_click pageview session_start identify lead sale share engagement custom)

  @doc "Returns the canonical list of all event types (for DB validation)."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @doc "Returns event types accepted via public ingest surfaces (beacon, API)."
  @spec ingest_types() :: [String.t()]
  def ingest_types, do: @ingest_types

  schema "ga_events" do
    field(:id, Ecto.UUID, primary_key: true, autogenerate: false)

    field(:workspace_id, Ecto.UUID)
    field(:visitor_id, Ecto.UUID)

    # Event classification
    field(:event_type, :string)
    field(:event_name, :string)

    # Link context
    field(:link_id, Ecto.UUID)
    field(:click_id, Ecto.UUID)

    # Partner attribution snapshot (immutable after insert)
    field(:partner_id, Ecto.UUID)
    field(:referral_link_id, Ecto.UUID)
    field(:referral_click_id, Ecto.UUID)

    # Page context
    field(:url, :string)
    field(:host, :string)
    field(:path, :string)
    field(:referrer, :string)
    field(:referrer_url, :string)

    # Source classification (promoted for OLAP)
    field(:source_platform, :string)
    field(:source_medium, :string)
    field(:source_campaign, :string)
    field(:source, :map, default: %{})

    # Raw capture data
    field(:fingerprint, :string)
    field(:ip_address, EctoNetwork.INET)
    field(:user_agent, :string)

    # Promoted properties
    field(:amount_cents, :integer)
    field(:currency, :string)

    # Flexible properties
    field(:properties, :map, default: %{})

    # Connector source context snapshot (for deterministic payload rebuilds)
    field(:connector_source_context, :map)

    field(:inserted_at, :utc_datetime_usec,
      primary_key: true,
      autogenerate: {DateTime, :utc_now, []}
    )
  end

  @required_fields [:workspace_id, :visitor_id, :event_type]
  @optional_fields [
    :event_name,
    :link_id,
    :click_id,
    :partner_id,
    :referral_link_id,
    :referral_click_id,
    :url,
    :host,
    :path,
    :referrer,
    :referrer_url,
    :source_platform,
    :source_medium,
    :source_campaign,
    :source,
    :fingerprint,
    :ip_address,
    :user_agent,
    :amount_cents,
    :currency,
    :properties,
    :connector_source_context
  ]

  # Cap on free-form source-classification strings. They derive from
  # client-controlled `utm_*` params with no upstream length bound, so we
  # truncate (never reject — ingest events are append-only and must not be
  # dropped) to keep the columns and breakdown outputs from being bloated.
  @max_source_field_length 255

  @doc """
  Changeset for recording an event.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
    |> validate_length(:host, max: 2083)
    |> validate_length(:path, max: 2083)
    |> truncate_source_fields()
  end

  defp truncate_source_fields(changeset) do
    changeset
    |> update_change(:source_platform, &truncate_source_value/1)
    |> update_change(:source_medium, &truncate_source_value/1)
    |> update_change(:source_campaign, &truncate_source_value/1)
    |> update_change(:source, &truncate_source_map/1)
  end

  defp truncate_source_value(value) when is_binary(value),
    do: String.slice(value, 0, @max_source_field_length)

  defp truncate_source_value(value), do: value

  defp truncate_source_map(%{} = source),
    do: Map.new(source, fn {key, value} -> {key, truncate_source_value(value)} end)

  defp truncate_source_map(source), do: source
end
