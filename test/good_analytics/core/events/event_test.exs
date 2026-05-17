defmodule GoodAnalytics.Core.Events.EventTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Events.Event

  @valid_attrs %{
    workspace_id: "00000000-0000-0000-0000-000000000000",
    visitor_id: "11111111-1111-1111-1111-111111111111",
    event_type: "pageview"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Event.changeset(%Event{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Event.changeset(%Event{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert %{workspace_id: _} = errors
      assert %{visitor_id: _} = errors
      assert %{event_type: _} = errors
    end

    test "invalid event_type" do
      attrs = Map.put(@valid_attrs, :event_type, "invalid_type")
      changeset = Event.changeset(%Event{}, attrs)
      refute changeset.valid?
    end

    test "accepts all valid event types" do
      for type <- Event.event_types() do
        changeset = Event.changeset(%Event{}, %{@valid_attrs | event_type: type})
        assert changeset.valid?, "expected #{type} to be valid"
      end
    end

    test "ingest_types excludes api_request" do
      refute "api_request" in Event.ingest_types()
      assert "pageview" in Event.ingest_types()
      assert "custom" in Event.ingest_types()
    end

    test "ingest_types is a subset of event_types" do
      for type <- Event.ingest_types() do
        assert type in Event.event_types()
      end
    end

    test "accepts source classification fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          source_platform: "google",
          source_medium: "organic",
          source_campaign: "summer-2026",
          source: %{"term" => "analytics"}
        })

      changeset = Event.changeset(%Event{}, attrs)
      assert changeset.valid?
    end

    test "accepts promoted revenue fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          event_type: "sale",
          amount_cents: 4900,
          currency: "USD"
        })

      changeset = Event.changeset(%Event{}, attrs)
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
