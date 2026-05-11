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

  @event_types ~w(link_click pageview session_start identify lead sale share engagement custom)

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

    # Page context
    field(:url, :string)
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
    :url,
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

  @doc """
  Changeset for recording an event.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:event_type, @event_types)
  end
end
