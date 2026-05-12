defmodule GoodAnalytics.Core.Links.Link do
  @moduledoc """
  Short links, referral links, and campaign links.

  Each link maps a `domain/key` pair to a destination URL.
  Archived links free up their key for reuse.

  ## geo_targeting

  `geo_targeting` is a `%{country_code => url}` map. Keys are normalized
  to uppercase ISO-3166-1 alpha-2 codes on write. Values are validated as
  HTTP/HTTPS URLs by the changeset; any other scheme (e.g. `javascript:`)
  is rejected. Lookups at redirect time match against the uppercase form
  of the resolved country code.
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
    |> validate_and_normalize_geo_targeting()
    |> unique_constraint([:domain, :key], name: :idx_ga_links_domain_key)
  end

  @doc false
  def seed_changeset(link, attrs) do
    link
    |> changeset(attrs)
    |> cast(attrs, @counter_fields)
  end

  @doc """
  Returns true when `url` is a non-empty string with an `http` or `https`
  scheme and a non-empty host. Public so the redirect path can apply the
  same check at read time as a defense-in-depth against data that bypassed
  the changeset.
  """
  @spec valid_http_url?(term()) :: boolean()
  def valid_http_url?(url) when is_binary(url) and url != "" do
    uri = URI.parse(url)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  end

  def valid_http_url?(_), do: false

  defp validate_url(changeset, field) do
    validate_change(changeset, field, fn _, value ->
      if valid_http_url?(value),
        do: [],
        else: [{field, "must be a valid HTTP or HTTPS URL"}]
    end)
  end

  defp validate_and_normalize_geo_targeting(changeset) do
    case fetch_change(changeset, :geo_targeting) do
      {:ok, value} -> apply_geo_targeting(changeset, value)
      :error -> changeset
    end
  end

  defp apply_geo_targeting(changeset, nil), do: put_change(changeset, :geo_targeting, %{})

  defp apply_geo_targeting(changeset, targeting) when is_map(targeting) do
    normalized = normalize_geo_targeting(targeting)

    if all_valid_geo_targets?(normalized) do
      put_change(changeset, :geo_targeting, normalized)
    else
      add_error(changeset, :geo_targeting, "all values must be valid HTTP or HTTPS URLs")
    end
  end

  defp apply_geo_targeting(changeset, _other) do
    add_error(changeset, :geo_targeting, "must be a map of country code to URL")
  end

  defp normalize_geo_targeting(targeting) do
    Map.new(targeting, fn {k, v} -> {normalize_cc(k), v} end)
  end

  defp all_valid_geo_targets?(targeting) do
    Enum.all?(targeting, fn {cc, url} ->
      is_binary(cc) and cc != "" and valid_http_url?(url)
    end)
  end

  defp normalize_cc(cc) when is_binary(cc), do: String.upcase(cc)
  defp normalize_cc(other), do: other
end
