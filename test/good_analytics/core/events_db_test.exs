defmodule GoodAnalytics.Core.EventsDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events

  describe "last_event/2" do
    test "returns most recent event of given type" do
      visitor = create_visitor!()
      _e1 = record_event!(visitor, "pageview", %{url: "https://first.com"})
      e2 = record_event!(visitor, "pageview", %{url: "https://second.com"})

      result = Events.last_event(visitor.id, "pageview")
      assert result.id == e2.id
    end

    test "filters by event_type" do
      visitor = create_visitor!()
      _pv = record_event!(visitor, "pageview")
      sale = record_event!(visitor, "sale", %{amount_cents: 1000, currency: "USD"})

      result = Events.last_event(visitor.id, "sale")
      assert result.id == sale.id
    end

    test "returns nil when no matching events" do
      visitor = create_visitor!()
      assert Events.last_event(visitor.id, "sale") == nil
    end
  end
end
