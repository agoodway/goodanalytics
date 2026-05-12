defmodule GoodAnalytics.Core.EventsFilteredTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events

  @workspace_id GoodAnalytics.default_workspace_id()

  setup do
    visitor = create_visitor!()
    now = DateTime.utc_now()

    e1 =
      record_event!(visitor, "pageview", %{
        url: "https://example.com/pricing",
        source: %{platform: "google", medium: "cpc"}
      })

    e2 =
      record_event!(visitor, "sale", %{
        url: "https://example.com/checkout",
        source: %{platform: "direct"},
        amount_cents: 4900,
        currency: "USD"
      })

    e3 =
      record_event!(visitor, "lead", %{
        url: "https://example.com/signup",
        source: %{platform: "google"},
        event_name: "signup_form"
      })

    %{visitor: visitor, events: [e1, e2, e3], now: now}
  end

  describe "list_events/2" do
    test "returns events within default date range", %{events: events} do
      results = Events.list_events(@workspace_id)
      assert length(results) == 3
      # Ordered by inserted_at desc
      ids = Enum.map(results, & &1.id)
      expected_ids = events |> Enum.reverse() |> Enum.map(& &1.id)
      assert ids == expected_ids
    end

    test "filters by event_type {:in, types}", %{events: [_pv, sale, _lead]} do
      results = Events.list_events(@workspace_id, event_type: {:in, ["sale"]})
      assert length(results) == 1
      assert hd(results).id == sale.id
    end

    test "filters by event_type {:not_in, types}", %{events: [pv, _sale, lead]} do
      results = Events.list_events(@workspace_id, event_type: {:not_in, ["sale"]})
      ids = Enum.map(results, & &1.id)
      assert pv.id in ids
      assert lead.id in ids
      assert length(results) == 2
    end

    test "filters by source_platform {:in, platforms}", %{events: [pv, _sale, lead]} do
      results = Events.list_events(@workspace_id, source_platform: {:in, ["google"]})
      ids = Enum.map(results, & &1.id)
      assert pv.id in ids
      assert lead.id in ids
      assert length(results) == 2
    end

    test "filters by visitor_id", %{visitor: visitor, events: events} do
      results = Events.list_events(@workspace_id, visitor_id: visitor.id)
      assert length(results) == length(events)

      # Different visitor returns nothing
      other_visitor = create_visitor!()
      results = Events.list_events(@workspace_id, visitor_id: other_visitor.id)
      assert results == []
    end

    test "filters by search ILIKE on event_name", %{events: [_pv, _sale, lead]} do
      results = Events.list_events(@workspace_id, search: "signup")
      ids = Enum.map(results, & &1.id)
      assert lead.id in ids
    end

    test "filters by search ILIKE on url", %{events: [pv, _sale, _lead]} do
      results = Events.list_events(@workspace_id, search: "pricing")
      assert length(results) == 1
      assert hd(results).id == pv.id
    end

    test "respects pagination limit and offset", %{events: events} do
      results = Events.list_events(@workspace_id, limit: 2, offset: 0)
      assert length(results) == 2

      results = Events.list_events(@workspace_id, limit: 2, offset: 2)
      assert length(results) == 1
      assert hd(results).id == hd(events).id
    end

    test "respects explicit date range bounds" do
      visitor = create_visitor!()
      # This event is old enough to be outside a 7-day window
      _old_event = record_event!(visitor, "pageview", %{url: "https://old.com"})

      far_past = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      results = Events.list_events(@workspace_id, start_at: far_past)
      # Should include all events (the 3 from setup + old_event)
      assert length(results) >= 4
    end

    test "applies multiple filters simultaneously", %{events: [_pv, _sale, lead]} do
      # lead has event_type=lead, source_platform=google, event_name=signup_form
      results =
        Events.list_events(@workspace_id,
          event_type: {:in, ["lead"]},
          source_platform: {:in, ["google"]},
          search: "signup"
        )

      assert length(results) == 1
      assert hd(results).id == lead.id

      # Conflicting filters should return nothing
      results =
        Events.list_events(@workspace_id,
          event_type: {:in, ["sale"]},
          source_platform: {:in, ["google"]}
        )

      assert results == []
    end

    test "search escapes ILIKE wildcards" do
      visitor = create_visitor!()
      record_event!(visitor, "pageview", %{event_name: "100% off sale"})
      record_event!(visitor, "pageview", %{event_name: "regular event"})

      # Searching for literal "%" should match the event containing it
      results = Events.list_events(@workspace_id, search: "100%")
      assert length(results) == 1
      assert hd(results).event_name == "100% off sale"

      # Searching for just "%" should not match everything
      results = Events.list_events(@workspace_id, search: "%")
      # Only matches events that literally contain "%" in name or url
      assert length(results) == 1
    end
  end

  describe "count_events/2" do
    test "returns total count matching filters", %{events: _events} do
      assert Events.count_events(@workspace_id) == 3
      assert Events.count_events(@workspace_id, event_type: {:in, ["sale"]}) == 1
      assert Events.count_events(@workspace_id, event_type: {:in, ["pageview", "lead"]}) == 2
    end

    test "matches list_events result count with same filters" do
      list_count = length(Events.list_events(@workspace_id, source_platform: {:in, ["google"]}))
      count = Events.count_events(@workspace_id, source_platform: {:in, ["google"]})
      assert list_count == count
    end
  end

  describe "filter_options/1" do
    test "returns distinct event types and source platforms", %{events: _events} do
      options = Events.filter_options(@workspace_id)
      assert "pageview" in options.event_types
      assert "sale" in options.event_types
      assert "lead" in options.event_types
      assert "google" in options.source_platforms
      assert "direct" in options.source_platforms
    end

    test "excludes nil source_platforms" do
      visitor = create_visitor!()
      record_event!(visitor, "pageview", %{url: "https://example.com"})

      options = Events.filter_options(@workspace_id)
      refute nil in options.source_platforms
    end

    test "returns empty lists for workspace with no events" do
      empty_workspace_id = Ecto.UUID.generate()
      options = Events.filter_options(empty_workspace_id)
      assert options.event_types == []
      assert options.source_platforms == []
    end
  end

  describe "get_event/2" do
    test "returns event in same workspace", %{events: [event | _]} do
      result = Events.get_event(@workspace_id, event.id)
      assert result.id == event.id
    end

    test "returns nil for event in different workspace", %{events: [event | _]} do
      other_workspace_id = Ecto.UUID.generate()
      assert Events.get_event(other_workspace_id, event.id) == nil
    end

    test "returns nil for non-existent event id" do
      assert Events.get_event(@workspace_id, Ecto.UUID.generate()) == nil
    end

    test "returns nil for invalid UUID format" do
      assert Events.get_event(@workspace_id, "not-a-uuid") == nil
    end
  end
end
