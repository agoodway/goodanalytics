defmodule GoodAnalytics.Core.Sessions.Session do
  @moduledoc """
  Aggregated visitor session record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  schema "ga_sessions" do
    field(:workspace_id, Ecto.UUID)
    field(:visitor_id, Ecto.UUID)
    field(:anonymous_id, :string)

    field(:started_at, :utc_datetime_usec)
    field(:last_event_at, :utc_datetime_usec)

    field(:entry_url, :string)
    field(:entry_page, :string)
    field(:exit_page, :string)

    field(:pageviews, :integer, default: 0)
    field(:events, :integer, default: 0)
    field(:duration_seconds, :integer, default: 0)
    field(:engaged_seconds, :integer, default: 0)

    field(:is_bounce, :boolean, default: true)
    field(:is_engaged, :boolean, default: false)

    field(:source_platform, :string)
    field(:source_medium, :string)
    field(:source_campaign, :string)
    field(:click_id, Ecto.UUID)

    field(:device_type, :string)
    field(:browser, :string)
    field(:os, :string)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required_fields [:workspace_id, :visitor_id, :started_at, :last_event_at]
  @defaulted_required_fields [
    :pageviews,
    :events,
    :duration_seconds,
    :engaged_seconds,
    :is_bounce,
    :is_engaged
  ]
  @metric_fields [:pageviews, :events, :duration_seconds, :engaged_seconds]
  @source_fields [:source_platform, :source_medium, :source_campaign]
  @optional_fields [
    :anonymous_id,
    :entry_url,
    :entry_page,
    :exit_page,
    :pageviews,
    :events,
    :duration_seconds,
    :engaged_seconds,
    :is_bounce,
    :is_engaged,
    :source_platform,
    :source_medium,
    :source_campaign,
    :click_id,
    :device_type,
    :browser,
    :os
  ]
  @max_source_field_length 255

  @doc """
  Changeset for creating or updating a session.
  """
  def changeset(session, attrs) do
    session
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields ++ @defaulted_required_fields)
    |> validate_metric_fields()
    |> validate_chronology()
    |> truncate_source_fields()
  end

  defp validate_metric_fields(changeset) do
    Enum.reduce(@metric_fields, changeset, fn field, changeset ->
      validate_number(changeset, field, greater_than_or_equal_to: 0)
    end)
  end

  defp validate_chronology(changeset) do
    started_at = get_field(changeset, :started_at)
    last_event_at = get_field(changeset, :last_event_at)

    if started_at && last_event_at && DateTime.compare(last_event_at, started_at) == :lt do
      add_error(changeset, :last_event_at, "must be at or after started_at")
    else
      changeset
    end
  end

  defp truncate_source_fields(changeset) do
    Enum.reduce(@source_fields, changeset, fn field, changeset ->
      update_change(changeset, field, &truncate_source_value/1)
    end)
  end

  defp truncate_source_value(value) when is_binary(value),
    do: String.slice(value, 0, @max_source_field_length)

  defp truncate_source_value(value), do: value
end
