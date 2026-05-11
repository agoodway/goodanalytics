defmodule GoodAnalytics.Auth.ApiKeyTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Auth.ApiKey

  describe "generate_key/1" do
    test "generates secret key with ga_sk_ prefix" do
      {raw_key, hash} = ApiKey.generate_key("secret")
      assert String.starts_with?(raw_key, "ga_sk_")
      assert is_binary(hash)
      assert String.length(hash) == 64
    end

    test "generates publishable key with ga_pk_ prefix" do
      {raw_key, hash} = ApiKey.generate_key("publishable")
      assert String.starts_with?(raw_key, "ga_pk_")
      assert is_binary(hash)
    end

    test "generates unique keys each time" do
      {key1, _} = ApiKey.generate_key("secret")
      {key2, _} = ApiKey.generate_key("secret")
      refute key1 == key2
    end
  end

  describe "hash_key/1" do
    test "produces consistent hash for same input" do
      raw = "ga_sk_test_key_123"
      assert ApiKey.hash_key(raw) == ApiKey.hash_key(raw)
    end

    test "matches hash from generate_key" do
      {raw_key, expected_hash} = ApiKey.generate_key("secret")
      assert ApiKey.hash_key(raw_key) == expected_hash
    end
  end

  describe "changeset/2" do
    test "valid with required fields" do
      {_raw, hash} = ApiKey.generate_key("secret")

      changeset =
        ApiKey.changeset(%ApiKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          key_type: "secret",
          key_hash: hash,
          key_prefix: "ga_sk_"
        })

      assert changeset.valid?
    end

    test "invalid key_type" do
      changeset =
        ApiKey.changeset(%ApiKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          key_type: "admin",
          key_hash: "abc",
          key_prefix: "ga_ak_"
        })

      refute changeset.valid?
    end

    test "rejects mismatched prefix and type" do
      {_raw, hash} = ApiKey.generate_key("secret")

      changeset =
        ApiKey.changeset(%ApiKey{}, %{
          workspace_id: Ecto.UUID.generate(),
          key_type: "secret",
          key_hash: hash,
          key_prefix: "ga_pk_"
        })

      refute changeset.valid?
      assert %{key_prefix: _} = errors_on(changeset)
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
