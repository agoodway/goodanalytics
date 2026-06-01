defmodule GoodAnalytics.Core.Partners.Partner do
  @moduledoc """
  Core-owned referral partner identity.

  Partners are workspace-scoped records that back referral links.
  Core owns partner identity and attribution; GoodPartners and host
  apps own onboarding, rewards, payouts, and partner-facing UI.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @statuses ~w(active disabled archived)

  schema "ga_partners" do
    field(:workspace_id, Ecto.UUID)
    field(:key, :string)
    field(:name, :string)
    field(:status, :string, default: "active")
    field(:external_id, :string)
    field(:metadata, :map, default: %{})
    field(:archived_at, :utc_datetime_usec)

    timestamps()
  end

  @required_fields [:workspace_id, :key, :name]
  @optional_fields [:status, :external_id, :metadata, :archived_at]
  @update_fields [:name, :status, :external_id, :metadata]

  @doc "Changeset for creating a new partner."
  def changeset(partner, attrs) do
    partner
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:key, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_format(:key, ~r/\A[a-zA-Z0-9_-]+\z/,
      message: "must contain only letters, numbers, hyphens, and underscores"
    )
    |> unique_constraint([:workspace_id, :key], name: :idx_ga_partners_workspace_key)
    |> unique_constraint([:workspace_id, :external_id],
      name: :idx_ga_partners_workspace_external_id
    )
  end

  @doc "Changeset for updating an existing partner. Does not allow workspace_id changes."
  def update_changeset(partner, attrs) do
    partner
    |> cast(attrs, @update_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:name, min: 1, max: 255)
    |> unique_constraint([:workspace_id, :key], name: :idx_ga_partners_workspace_key)
    |> unique_constraint([:workspace_id, :external_id],
      name: :idx_ga_partners_workspace_external_id
    )
  end

  @doc "Changeset for archiving a partner."
  def archive_changeset(partner) do
    partner
    |> change(%{status: "archived", archived_at: DateTime.utc_now(:microsecond)})
  end
end
