defmodule GoodAnalytics.Core.Links.LinkTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Links.Link

  @valid_attrs %{
    domain: "mybrand.link",
    key: "promo",
    url: "https://example.com/landing",
    workspace_id: "00000000-0000-0000-0000-000000000000"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Link.changeset(%Link{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Link.changeset(%Link{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert %{domain: ["can't be blank"]} = errors
      assert %{key: ["can't be blank"]} = errors
      assert %{url: ["can't be blank"]} = errors
      assert %{workspace_id: ["can't be blank"]} = errors
    end

    test "invalid link_type" do
      attrs = Map.put(@valid_attrs, :link_type, "invalid")
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "accepts all valid link types" do
      for type <- ~w(short referral campaign) do
        changeset = Link.changeset(%Link{}, Map.put(@valid_attrs, :link_type, type))
        assert changeset.valid?, "expected #{type} to be valid"
      end
    end

    test "rejects invalid URL" do
      attrs = Map.put(@valid_attrs, :url, "not-a-url")
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
      assert %{url: ["must be a valid HTTP or HTTPS URL"]} = errors_on(changeset)
    end

    test "rejects ftp URL" do
      attrs = Map.put(@valid_attrs, :url, "ftp://files.example.com/file")
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "accepts http URL" do
      attrs = Map.put(@valid_attrs, :url, "http://example.com")
      changeset = Link.changeset(%Link{}, attrs)
      assert changeset.valid?
    end

    test "validates ios_url if present" do
      attrs = Map.put(@valid_attrs, :ios_url, "not-a-url")
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "accepts UTM fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          utm_source: "twitter",
          utm_medium: "social",
          utm_campaign: "winter-promo"
        })

      changeset = Link.changeset(%Link{}, attrs)
      assert changeset.valid?
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
