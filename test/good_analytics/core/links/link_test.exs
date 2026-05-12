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

    test "rejects geo_targeting with javascript: URL" do
      attrs = Map.put(@valid_attrs, :geo_targeting, %{"US" => "javascript:alert(1)"})
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?

      assert %{geo_targeting: ["all values must be valid HTTP or HTTPS URLs"]} =
               errors_on(changeset)
    end

    test "rejects geo_targeting with data: URL" do
      attrs = Map.put(@valid_attrs, :geo_targeting, %{"US" => "data:text/html,<script>"})
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "rejects geo_targeting with empty string value" do
      attrs = Map.put(@valid_attrs, :geo_targeting, %{"US" => ""})
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "rejects geo_targeting with nil value" do
      attrs = Map.put(@valid_attrs, :geo_targeting, %{"US" => nil})
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "rejects geo_targeting with non-string value" do
      attrs = Map.put(@valid_attrs, :geo_targeting, %{"US" => 42})
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
    end

    test "rejects geo_targeting that is not a map" do
      # `cast` already rejects non-map values for a :map field — Ecto emits
      # "is invalid" before our `validate_change` runs. Either error is fine
      # as long as the value is rejected.
      attrs = Map.put(@valid_attrs, :geo_targeting, "not a map")
      changeset = Link.changeset(%Link{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:geo_targeting] != nil
    end

    test "nil geo_targeting becomes empty map" do
      attrs = Map.put(@valid_attrs, :geo_targeting, nil)
      changeset = Link.changeset(%Link{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :geo_targeting) == %{}
    end

    test "normalizes geo_targeting keys to uppercase" do
      attrs =
        Map.put(@valid_attrs, :geo_targeting, %{
          "de" => "https://de.example.com",
          "fr" => "https://fr.example.com"
        })

      changeset = Link.changeset(%Link{}, attrs)
      assert changeset.valid?

      assert Ecto.Changeset.get_field(changeset, :geo_targeting) == %{
               "DE" => "https://de.example.com",
               "FR" => "https://fr.example.com"
             }
    end

    test "accepts geo_targeting with valid HTTPS URLs" do
      attrs =
        Map.put(@valid_attrs, :geo_targeting, %{
          "US" => "https://us.example.com",
          "GB" => "http://gb.example.com"
        })

      changeset = Link.changeset(%Link{}, attrs)
      assert changeset.valid?
    end
  end

  describe "valid_http_url?/1" do
    test "accepts http and https URLs with hosts" do
      assert Link.valid_http_url?("https://example.com")
      assert Link.valid_http_url?("http://example.com/path?x=1")
    end

    test "rejects javascript and data URIs" do
      refute Link.valid_http_url?("javascript:alert(1)")
      refute Link.valid_http_url?("data:text/html,<x>")
    end

    test "rejects URLs without a host" do
      refute Link.valid_http_url?("https://")
      refute Link.valid_http_url?("http:/no-host")
    end

    test "rejects non-binary input" do
      refute Link.valid_http_url?(nil)
      refute Link.valid_http_url?(42)
      refute Link.valid_http_url?(%{})
    end

    test "rejects empty string" do
      refute Link.valid_http_url?("")
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
