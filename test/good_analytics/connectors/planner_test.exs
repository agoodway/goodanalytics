defmodule GoodAnalytics.Connectors.PlannerTest do
  use ExUnit.Case, async: false

  alias GoodAnalytics.Connectors.{EventId, Planner}

  describe "EventId.derive/3" do
    test "produces deterministic IDs" do
      event_id = "11111111-1111-1111-1111-111111111111"
      ts = ~U[2026-04-21 12:00:00Z]

      id1 = EventId.derive(event_id, ts, :meta)
      id2 = EventId.derive(event_id, ts, :meta)
      assert id1 == id2
    end

    test "different connector types produce different IDs" do
      event_id = "11111111-1111-1111-1111-111111111111"
      ts = ~U[2026-04-21 12:00:00Z]

      meta_id = EventId.derive(event_id, ts, :meta)
      google_id = EventId.derive(event_id, ts, :google)
      assert meta_id != google_id
    end

    test "includes connector type prefix" do
      id = EventId.derive("abc", ~U[2026-01-01 00:00:00Z], :tiktok)
      assert String.starts_with?(id, "tiktok_")
    end

    test "different events produce different IDs" do
      ts = ~U[2026-04-21 12:00:00Z]
      id1 = EventId.derive("event-1", ts, :meta)
      id2 = EventId.derive("event-2", ts, :meta)
      assert id1 != id2
    end
  end

  describe "Planner.plan/4 — kill switch" do
    test "returns skip when connectors disabled" do
      # Temporarily set connectors_enabled to false
      original = Application.get_env(:good_analytics, :connectors_enabled)
      Application.put_env(:good_analytics, :connectors_enabled, false)

      event = fake_event("lead")
      result = Planner.plan(event, %{}, %{})
      assert result == {:skip, :connectors_disabled}

      # Restore
      if original do
        Application.put_env(:good_analytics, :connectors_enabled, original)
      else
        Application.delete_env(:good_analytics, :connectors_enabled)
      end
    end
  end

  describe "Planner.plan/4 — no connectors configured" do
    test "returns empty list when no connectors registered" do
      event = fake_event("lead")
      assert {:ok, []} = Planner.plan(event, %{"_fbp" => "fb.1.123"}, %{})
    end
  end

  describe "PostCommit.connector_eligible?/1" do
    alias GoodAnalytics.Connectors.PostCommit

    test "lead events are connector eligible" do
      assert PostCommit.connector_eligible?(%{event_type: "lead"})
    end

    test "sale events are connector eligible" do
      assert PostCommit.connector_eligible?(%{event_type: "sale"})
    end

    test "pageview events are not connector eligible" do
      refute PostCommit.connector_eligible?(%{event_type: "pageview"})
    end

    test "custom events are not connector eligible" do
      refute PostCommit.connector_eligible?(%{event_type: "custom"})
    end
  end

  defp fake_event(event_type) do
    %{
      id: "11111111-1111-1111-1111-111111111111",
      workspace_id: "00000000-0000-0000-0000-000000000000",
      visitor_id: "22222222-2222-2222-2222-222222222222",
      event_type: event_type,
      inserted_at: ~U[2026-04-21 12:00:00.000000Z],
      connector_source_context: %{}
    }
  end
end
