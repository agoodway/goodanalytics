defmodule GoodAnalytics.Core.Visitors.Visitor do
  @moduledoc """
  The central identity graph record.

  Each visitor accumulates identity signals (fingerprints, anonymous IDs,
  click IDs, ga_id) over time. When signals match across visitors, they
  are merged into a single record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @statuses ~w(anonymous identified lead customer churned merged)

  schema "ga_visitors" do
    field(:workspace_id, Ecto.UUID)

    # Identity Signals
    field(:fingerprints, {:array, :string}, default: [])
    field(:anonymous_ids, {:array, :string}, default: [])
    field(:click_ids, {:array, Ecto.UUID}, default: [])
    field(:ga_id, :string)

    # Resolved Identity (host-app projection — distinct from `status`,
    # which is the lifecycle stage; these may be populated long before
    # the visitor reaches `customer` status).
    field(:person_external_id, :string)
    field(:person_email, :string)
    field(:person_name, :string)
    field(:person_metadata, :map, default: %{})

    # First-Touch Attribution
    field(:first_source, :map)
    field(:first_click_id, Ecto.UUID)
    field(:first_partner_id, Ecto.UUID)
    field(:first_seen_at, :utc_datetime_usec)

    # Last-Touch Attribution
    field(:last_source, :map)
    field(:last_click_id, Ecto.UUID)
    field(:last_partner_id, Ecto.UUID)
    field(:last_seen_at, :utc_datetime_usec)

    # Multi-Touch Attribution
    field(:attribution_path, {:array, :map}, default: [])

    # Ad Platform Click IDs
    field(:click_id_params, :map, default: %{})

    # Connector browser identifiers (e.g., _fbp, _fbc)
    field(:connector_identifiers, :map, default: %{})

    # Geo & Device
    field(:geo, :map, default: %{})
    field(:device, :map, default: %{})

    # Behavioral Summary
    field(:total_sessions, :integer, default: 0)
    field(:total_pageviews, :integer, default: 0)
    field(:total_events, :integer, default: 0)
    field(:total_time_seconds, :integer, default: 0)
    field(:avg_scroll_depth, :decimal)
    field(:top_pages, {:array, :map}, default: [])

    # Scores
    field(:lead_quality_score, :decimal)
    field(:fraud_risk_score, :decimal)

    # Lifecycle
    field(:status, :string, default: "anonymous")
    field(:merged_into_id, Ecto.UUID)
    field(:identified_at, :utc_datetime_usec)
    field(:converted_at, :utc_datetime_usec)
    field(:ltv_cents, :integer, default: 0)

    timestamps()
  end

  @required_fields [:workspace_id]
  @optional_fields [
    :fingerprints,
    :anonymous_ids,
    :click_ids,
    :ga_id,
    :person_external_id,
    :person_email,
    :person_name,
    :person_metadata,
    :first_source,
    :first_click_id,
    :first_partner_id,
    :first_seen_at,
    :last_source,
    :last_click_id,
    :last_partner_id,
    :last_seen_at,
    :attribution_path,
    :click_id_params,
    :connector_identifiers,
    :geo,
    :device,
    :total_sessions,
    :total_pageviews,
    :total_events,
    :total_time_seconds,
    :avg_scroll_depth,
    :top_pages,
    :lead_quality_score,
    :fraud_risk_score,
    :status,
    :merged_into_id,
    :identified_at,
    :converted_at,
    :ltv_cents
  ]

  @doc """
  Changeset for creating a new visitor.
  """
  def changeset(visitor, attrs) do
    visitor
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workspace_id, :person_external_id],
      name: :idx_ga_visitors_person_external_id
    )
  end

  @doc """
  Changeset for identifying a visitor with person attributes.
  """
  def identify_changeset(visitor, attrs) do
    visitor
    |> cast(attrs, [
      :person_external_id,
      :person_email,
      :person_name,
      :person_metadata,
      :status,
      :identified_at
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:workspace_id, :person_external_id],
      name: :idx_ga_visitors_person_external_id
    )
  end
end
