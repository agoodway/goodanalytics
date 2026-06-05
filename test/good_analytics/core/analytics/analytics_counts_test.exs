defmodule GoodAnalytics.Core.AnalyticsCountsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics

  @ws GoodAnalytics.default_workspace_id()

  defp window do
    %{start_at: ~U[2026-06-01 00:00:00.000000Z], end_at: ~U[2026-06-30 00:00:00.000000Z]}
  end

  describe "pageviews/2" do
    test "counts only pageview events in the window" do
      v = create_visitor!()
      record_event!(v, "pageview", %{path: "/a"})
      record_event!(v, "pageview", %{path: "/b"})
      record_event!(v, "sale", %{path: "/buy", amount_cents: 100})

      assert Analytics.pageviews(@ws, window: window()) == 2
    end
  end

  describe "revenue/2" do
    test "sums sale amount_cents in the window" do
      v = create_visitor!()
      record_event!(v, "sale", %{path: "/buy", amount_cents: 1500})
      record_event!(v, "sale", %{path: "/buy", amount_cents: 500})
      record_event!(v, "pageview", %{path: "/a"})

      assert Analytics.revenue(@ws, window: window()) == 2000
    end

    test "revenue is 0 for an empty window" do
      assert Analytics.revenue(@ws, window: window()) == 0
    end
  end
end
