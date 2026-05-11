defmodule GoodAnalytics.Domains.Domain do
  @moduledoc """
  Custom short link domains.

  A domain must be verified (DNS check) before it can be used
  for short link redirects.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  schema "ga_domains" do
    field(:workspace_id, Ecto.UUID)
    field(:domain, :string)
    field(:verified, :boolean, default: false)
    field(:verified_at, :utc_datetime_usec)
    field(:default_url, :string)

    timestamps(updated_at: false)
  end

  @doc "Returns an Ecto changeset for creating or updating a domain."
  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:workspace_id, :domain, :verified, :verified_at, :default_url])
    |> validate_required([:domain])
    |> unique_constraint(:domain)
  end
end
