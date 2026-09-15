defmodule GoodAnalytics.Core.AnalyticsCountsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics

  @ws GoodAnalytics.default_workspace_id()

  defp window, do: query_window()

  defp event_time, do: ~U[2026-06-10 12:00:00.000000Z]

  describe "pageviews/2" do
    test "counts only pageview events in the window" do
      v = create_visitor!()
      record_event!(v, "pageview", %{path: "/a", inserted_at: event_time()})
      record_event!(v, "pageview", %{path: "/b", inserted_at: event_time()})
      record_event!(v, "sale", %{path: "/buy", amount_cents: 100, inserted_at: event_time()})

      assert Analytics.pageviews(@ws, window: window()) == 2
    end

    # Window semantics are inclusive at start_at, exclusive at end_at
    # (inserted_at >= start_at and inserted_at < end_at). These pin the
    # boundaries so an accidental > / <= flip is caught.
    test "includes an event exactly at start_at, excludes one just before" do
      v = create_visitor!()
      record_event!(v, "pageview", %{path: "/at", inserted_at: ~U[2026-06-01 00:00:00.000000Z]})

      record_event!(v, "pageview", %{
        path: "/before",
        inserted_at: ~U[2026-05-31 23:59:59.999999Z]
      })

      assert Analytics.pageviews(@ws, window: window()) == 1
    end

    test "excludes an event exactly at end_at, includes one just before" do
      v = create_visitor!()
      record_event!(v, "pageview", %{path: "/end", inserted_at: ~U[2026-06-30 00:00:00.000000Z]})
      record_event!(v, "pageview", %{path: "/in", inserted_at: ~U[2026-06-29 23:59:59.999999Z]})

      assert Analytics.pageviews(@ws, window: window()) == 1
    end
  end

  describe "revenue/2" do
    test "sums sale amount_cents in the window" do
      v = create_visitor!()
      record_event!(v, "sale", %{path: "/buy", amount_cents: 1500, inserted_at: event_time()})
      record_event!(v, "sale", %{path: "/buy", amount_cents: 500, inserted_at: event_time()})
      record_event!(v, "pageview", %{path: "/a", inserted_at: event_time()})

      assert Analytics.revenue(@ws, window: window()) == 2000
    end

    test "revenue is 0 for an empty window" do
      assert Analytics.revenue(@ws, window: window()) == 0
    end
  end
end
