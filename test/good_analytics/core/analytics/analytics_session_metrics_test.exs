defmodule GoodAnalytics.Core.AnalyticsSessionMetricsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics
  alias GoodAnalytics.Core.Sessions.Session

  @ws GoodAnalytics.default_workspace_id()

  defp window do
    %{start_at: ~U[2026-06-01 00:00:00.000000Z], end_at: ~U[2026-06-30 00:00:00.000000Z]}
  end

  defp insert_session!(attrs) do
    now = ~U[2026-06-10 12:00:00.000000Z]

    base = %{
      workspace_id: @ws,
      visitor_id: Uniq.UUID.uuid7(),
      started_at: now,
      last_event_at: now
    }

    %Session{id: Uniq.UUID.uuid7()}
    |> Session.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
  end

  describe "session_metrics/2" do
    test "aggregates sessions, bounce_rate, avg_duration, engaged_rate over the window" do
      insert_session!(%{is_bounce: true, is_engaged: false, duration_seconds: 0})
      insert_session!(%{is_bounce: false, is_engaged: true, duration_seconds: 40})

      m = Analytics.session_metrics(@ws, window: window())

      assert m.sessions == 2
      assert_in_delta m.bounce_rate, 0.5, 0.0001
      assert_in_delta m.avg_duration, 20.0, 0.0001
      assert_in_delta m.engaged_rate, 0.5, 0.0001
    end

    test "returns zeroed metrics for an empty window" do
      m = Analytics.session_metrics(@ws, window: window())

      assert m.sessions == 0
      assert m.bounce_rate == 0.0
      assert m.avg_duration == 0.0
      assert m.engaged_rate == 0.0
    end

    test "tallies entry and exit pages" do
      insert_session!(%{entry_page: "/home", exit_page: "/pricing", duration_seconds: 10})
      insert_session!(%{entry_page: "/home", exit_page: "/checkout", duration_seconds: 20})

      m = Analytics.session_metrics(@ws, window: window())

      assert m.entry_pages["/home"] == 2
      assert m.exit_pages["/pricing"] == 1
      assert m.exit_pages["/checkout"] == 1
    end

    test "include_page_tallies: false omits entry_pages/exit_pages but keeps headline metrics" do
      insert_session!(%{
        is_bounce: false,
        is_engaged: true,
        duration_seconds: 30,
        entry_page: "/a",
        exit_page: "/b"
      })

      result = Analytics.session_metrics(@ws, window: window(), include_page_tallies: false)

      assert result.sessions == 1
      assert is_float(result.bounce_rate)
      assert is_float(result.avg_duration)
      assert is_float(result.engaged_rate)
      refute Map.has_key?(result, :entry_pages)
      refute Map.has_key?(result, :exit_pages)
    end

    test "page tallies are included by default" do
      insert_session!(%{entry_page: "/a", exit_page: "/b", duration_seconds: 5})

      result = Analytics.session_metrics(@ws, window: window())

      assert Map.has_key?(result, :entry_pages)
      assert Map.has_key?(result, :exit_pages)
    end
  end
end
