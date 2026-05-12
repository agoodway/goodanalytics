defmodule GoodAnalytics.Core.Funnels.FilterTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Funnels.Filter

  describe "event filter changeset" do
    test "valid with event_type" do
      changeset = Filter.changeset(%Filter{}, %{type: "event", event_type: "pageview"})
      assert changeset.valid?
    end

    test "valid with event_type and event_name" do
      changeset = Filter.changeset(%Filter{}, %{type: "event", event_type: "custom", event_name: "signup"})
      assert changeset.valid?
    end

    test "rejects unknown event_type" do
      changeset = Filter.changeset(%Filter{}, %{type: "event", event_type: "unknown_type"})
      refute changeset.valid?
      assert errors_on(changeset)[:event_type]
    end

    test "requires event_type" do
      changeset = Filter.changeset(%Filter{}, %{type: "event"})
      refute changeset.valid?
      assert errors_on(changeset)[:event_type]
    end
  end

  describe "url filter changeset" do
    test "valid with match and value" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "equals", value: "/pricing"})
      assert changeset.valid?
    end

    test "valid with starts_with" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "starts_with", value: "/blog"})
      assert changeset.valid?
    end

    test "valid with regex" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "regex", value: "/posts/\\d+"})
      assert changeset.valid?
    end

    test "rejects invalid regex syntax" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "regex", value: "["})
      refute changeset.valid?
      assert errors_on(changeset)[:value]
    end

    test "rejects regex longer than 200 chars" do
      long_regex = String.duplicate("a", 201)
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "regex", value: long_regex})
      refute changeset.valid?
      assert errors_on(changeset)[:value]
    end

    test "rejects unknown match mode" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "contains", value: "test"})
      refute changeset.valid?
      assert errors_on(changeset)[:match]
    end

    test "requires match" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", value: "/pricing"})
      refute changeset.valid?
      assert errors_on(changeset)[:match]
    end

    test "requires value" do
      changeset = Filter.changeset(%Filter{}, %{type: "url", match: "equals"})
      refute changeset.valid?
      assert errors_on(changeset)[:value]
    end
  end

  describe "property filter changeset" do
    test "valid with eq op" do
      changeset = Filter.changeset(%Filter{}, %{type: "property", key: "plan", op: "eq", value: "pro"})
      assert changeset.valid?
    end

    test "valid with in op and values list" do
      changeset = Filter.changeset(%Filter{}, %{type: "property", key: "plan", op: "in", values: ["pro", "enterprise"]})
      assert changeset.valid?
    end

    test "rejects key longer than 255 chars" do
      long_key = String.duplicate("k", 256)
      changeset = Filter.changeset(%Filter{}, %{type: "property", key: long_key, op: "eq", value: "x"})
      refute changeset.valid?
      assert errors_on(changeset)[:key]
    end

    test "rejects value longer than 1000 chars" do
      long_value = String.duplicate("v", 1001)
      changeset = Filter.changeset(%Filter{}, %{type: "property", key: "k", op: "eq", value: long_value})
      refute changeset.valid?
      assert errors_on(changeset)[:value]
    end

    test "rejects values list with more than 100 items" do
      values = for i <- 1..101, do: "val#{i}"
      changeset = Filter.changeset(%Filter{}, %{type: "property", key: "k", op: "in", values: values})
      refute changeset.valid?
      assert errors_on(changeset)[:values]
    end

    test "rejects unknown op" do
      changeset = Filter.changeset(%Filter{}, %{type: "property", key: "plan", op: "gt", value: "5"})
      refute changeset.valid?
      assert errors_on(changeset)[:op]
    end

    test "requires key" do
      changeset = Filter.changeset(%Filter{}, %{type: "property", op: "eq", value: "x"})
      refute changeset.valid?
      assert errors_on(changeset)[:key]
    end
  end

  describe "source filter changeset" do
    test "valid with platform" do
      changeset = Filter.changeset(%Filter{}, %{type: "source", platform: "google"})
      assert changeset.valid?
    end

    test "valid with medium" do
      changeset = Filter.changeset(%Filter{}, %{type: "source", medium: "cpc"})
      assert changeset.valid?
    end

    test "valid with campaign" do
      changeset = Filter.changeset(%Filter{}, %{type: "source", campaign: "spring_sale"})
      assert changeset.valid?
    end

    test "valid with all three fields" do
      changeset = Filter.changeset(%Filter{}, %{type: "source", platform: "google", medium: "cpc", campaign: "spring"})
      assert changeset.valid?
    end

    test "rejects source filter with no fields" do
      changeset = Filter.changeset(%Filter{}, %{type: "source"})
      refute changeset.valid?
    end
  end

  describe "type validation" do
    test "rejects unknown filter type" do
      changeset = Filter.changeset(%Filter{}, %{type: "unknown"})
      refute changeset.valid?
      assert errors_on(changeset)[:type]
    end

    test "requires type" do
      changeset = Filter.changeset(%Filter{}, %{})
      refute changeset.valid?
      assert errors_on(changeset)[:type]
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
