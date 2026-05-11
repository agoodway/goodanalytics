defmodule GoodAnalytics.Connectors.Dispatch do
  @moduledoc """
  Durable outbound connector dispatch record.

  Each dispatch tracks a single delivery attempt from a source event to an
  external ad platform connector. Dispatches store both a payload snapshot
  (what was sent) and a source context (what is needed to rebuild the payload
  for replay).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  # Maximum number of delivery attempts before a dispatch is treated as exhausted.
  @default_max_attempts 5
  @statuses ~w(pending delivering delivered failed credential_error rate_limited skipped_disabled permanently_failed)

  schema "ga_connector_dispatches" do
    field(:workspace_id, Ecto.UUID)

    # Connector identity
    field(:connector_type, :string)
    field(:connector_event_id, :string)

    # Source event reference
    field(:event_id, Ecto.UUID)
    field(:event_inserted_at, :utc_datetime_usec)

    # Visitor reference
    field(:visitor_id, Ecto.UUID)

    # Payload and rebuild context
    field(:payload_snapshot, :map, default: %{})
    field(:source_context, :map, default: %{})

    # Delivery status
    field(:status, :string, default: "pending")

    # Attempt tracking
    field(:attempts, :integer, default: 0)
    field(:max_attempts, :integer, default: @default_max_attempts)
    field(:last_attempted_at, :utc_datetime_usec)
    field(:next_retry_at, :utc_datetime_usec)

    # Response metadata
    field(:response_status, :integer)
    field(:response_body, :map)
    field(:error_type, :string)
    field(:error_message, :string)

    # Replay metadata
    field(:replayed_from_id, Ecto.UUID)
    field(:replayed_at, :utc_datetime_usec)

    timestamps()
  end

  @required_fields [
    :workspace_id,
    :connector_type,
    :connector_event_id,
    :event_id,
    :event_inserted_at,
    :visitor_id,
    :payload_snapshot,
    :source_context
  ]

  @optional_fields [
    :status,
    :attempts,
    :max_attempts,
    :last_attempted_at,
    :next_retry_at,
    :response_status,
    :response_body,
    :error_type,
    :error_message,
    :replayed_from_id,
    :replayed_at
  ]

  @doc "Changeset for creating a new dispatch record."
  def changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:connector_type, :connector_event_id],
      name: :idx_ga_connector_dispatches_event_id
    )
  end

  @doc "Changeset for updating delivery status and response metadata."
  def delivery_changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, [
      :status,
      :attempts,
      :last_attempted_at,
      :next_retry_at,
      :response_status,
      :response_body,
      :error_type,
      :error_message
    ])
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Changeset for marking a dispatch as replayed."
  def replay_changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, [:replayed_from_id, :replayed_at])
    |> validate_required([:replayed_from_id, :replayed_at])
  end
end
