defmodule GoodAnalytics.Auth.ApiKey do
  @moduledoc """
  Two-tier API key authentication.

  Keys are either `secret` (server-side) or `publishable` (client-side).
  Only the hash is stored; the raw key is returned once at creation time.
  The `key_prefix` (`ga_sk_` or `ga_pk_`) allows identifying key type
  without a database lookup.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @key_types ~w(secret publishable)
  @key_prefixes %{"secret" => "ga_sk_", "publishable" => "ga_pk_"}

  schema "ga_api_keys" do
    field(:workspace_id, Ecto.UUID)
    field(:key_type, :string)
    field(:key_hash, :string)
    field(:key_prefix, :string)
    field(:allowed_hostnames, {:array, :string}, default: [])
    field(:name, :string)
    field(:last_used_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)

    timestamps(updated_at: false)
  end

  @doc """
  Returns an Ecto changeset for creating or updating an API key. Validates
  the key type, ensures the prefix matches the type, and enforces hash
  uniqueness on non-revoked keys.
  """
  def changeset(api_key, attrs) do
    api_key
    |> cast(attrs, [
      :workspace_id,
      :key_type,
      :key_hash,
      :key_prefix,
      :allowed_hostnames,
      :name,
      :expires_at
    ])
    |> validate_required([:workspace_id, :key_type, :key_hash, :key_prefix])
    |> validate_inclusion(:key_type, @key_types)
    |> validate_prefix_matches_type()
    |> unique_constraint(:key_hash, name: :idx_ga_api_keys_hash)
  end

  @doc """
  Generates a new API key string and its hash.

  Returns `{raw_key, hash}`. The raw key should be shown to the user
  once and never stored.
  """
  def generate_key(key_type) when key_type in @key_types do
    prefix = Map.fetch!(@key_prefixes, key_type)
    random = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    raw_key = prefix <> random
    hash = hash_key(raw_key)
    {raw_key, hash}
  end

  @doc """
  Hashes a raw API key for lookup using HMAC-SHA256.
  """
  def hash_key(raw_key) do
    :crypto.mac(:hmac, :sha256, hmac_secret(), raw_key) |> Base.encode16(case: :lower)
  end

  @doc """
  Verifies a raw API key against a stored hash using timing-safe comparison.
  """
  def verify_key(raw_key, stored_hash) do
    Plug.Crypto.secure_compare(hash_key(raw_key), stored_hash)
  end

  # NOTE: Changing from SHA-256 to HMAC-SHA256 invalidates any previously stored hashes.
  # Existing API keys will need to be regenerated after this change.
  defp hmac_secret do
    Application.fetch_env!(:good_analytics, :api_key_secret)
  end

  defp validate_prefix_matches_type(changeset) do
    key_type = get_field(changeset, :key_type)
    key_prefix = get_field(changeset, :key_prefix)

    expected = Map.get(@key_prefixes, key_type)

    if expected && key_prefix && key_prefix != expected do
      add_error(changeset, :key_prefix, "must match key_type (expected #{expected})")
    else
      changeset
    end
  end
end
