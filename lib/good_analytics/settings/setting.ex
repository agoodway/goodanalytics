defmodule GoodAnalytics.Settings.Setting do
  @moduledoc """
  Per-workspace runtime settings.

  Settings are key-value pairs stored as JSONB, scoped by workspace.
  They are cached via Nebulex with a configurable TTL.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  schema "ga_settings" do
    field(:workspace_id, Ecto.UUID)
    field(:key, :string)
    field(:value, :map)

    timestamps()
  end

  @doc "Returns an Ecto changeset for creating or updating a setting."
  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:workspace_id, :key, :value])
    |> validate_required([:workspace_id, :key, :value])
    |> unique_constraint([:workspace_id, :key])
  end
end
