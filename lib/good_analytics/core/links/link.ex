defmodule GoodAnalytics.Core.Links.Link do
  @moduledoc """
  Short links, referral links, and campaign links.

  Each link maps a `domain/key` pair to a destination URL.
  Archived links free up their key for reuse.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @link_types ~w(short referral campaign)

  schema "ga_links" do
    field(:workspace_id, Ecto.UUID)

    # Link definition
    field(:domain, :string)
    field(:key, :string)
    field(:url, :string)

    # Link type
    field(:link_type, :string, default: "short")

    # Campaign tracking
    field(:utm_source, :string)
    field(:utm_medium, :string)
    field(:utm_campaign, :string)
    field(:utm_content, :string)
    field(:utm_term, :string)

    # Configuration
    field(:password_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:ios_url, :string)
    field(:android_url, :string)
    field(:geo_targeting, :map, default: %{})
    field(:og_title, :string)
    field(:og_description, :string)
    field(:og_image, :string)

    # Analytics rollups
    field(:total_clicks, :integer, default: 0)
    field(:unique_clicks, :integer, default: 0)
    field(:total_leads, :integer, default: 0)
    field(:total_sales, :integer, default: 0)
    field(:total_revenue_cents, :integer, default: 0)

    # Metadata
    field(:tags, {:array, :string}, default: [])
    field(:external_id, :string)
    field(:metadata, :map, default: %{})

    # Timestamps
    field(:archived_at, :utc_datetime_usec)

    timestamps()
  end

  @required_fields [:domain, :key, :url, :workspace_id]
  @optional_fields [
    :link_type,
    :utm_source,
    :utm_medium,
    :utm_campaign,
    :utm_content,
    :utm_term,
    :password_hash,
    :expires_at,
    :ios_url,
    :android_url,
    :geo_targeting,
    :og_title,
    :og_description,
    :og_image,
    :tags,
    :external_id,
    :metadata,
    :archived_at
  ]

  @counter_fields [
    :total_clicks,
    :unique_clicks,
    :total_leads,
    :total_sales,
    :total_revenue_cents
  ]

  @doc """
  Changeset for creating or updating a link.
  """
  def changeset(link, attrs) do
    link
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:link_type, @link_types)
    |> validate_url(:url)
    |> validate_url(:ios_url)
    |> validate_url(:android_url)
    |> unique_constraint([:domain, :key], name: :idx_ga_links_domain_key)
  end

  @doc false
  def seed_changeset(link, attrs) do
    link
    |> changeset(attrs)
    |> cast(attrs, @counter_fields)
  end

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      uri = URI.parse(value)

      if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
        []
      else
        [{field, "must be a valid HTTP or HTTPS URL"}]
      end
    end)
  end
end
