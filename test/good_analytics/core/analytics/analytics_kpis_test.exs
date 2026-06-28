defmodule GoodAnalytics.Core.AnalyticsKpisTest do
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

  describe "kpis/2" do
    test "counts only events matching the filter" do
      twitter_visitor = create_visitor!(%{first_seen_at: ~U[2026-06-10 00:00:00.000000Z]})
      google_visitor = create_visitor!(%{first_seen_at: ~U[2026-06-10 00:00:00.000000Z]})

      record_event!(twitter_visitor, "pageview", %{platform: "twitter"})
      record_event!(google_visitor, "pageview", %{platform: "google"})

      kpis = Analytics.kpis(@ws, window: window(), filters: [{:source_platform, :eq, "twitter"}])

      assert kpis.visitors == 1
      assert kpis.new_visitors == 1
      assert kpis.pageviews == 1
    end

    test "no filters counts everything" do
      visitor = create_visitor!(%{})

      record_event!(visitor, "pageview", %{platform: "twitter"})
      record_event!(visitor, "pageview", %{platform: "google"})

      assert Analytics.kpis(@ws, window: window()).pageviews == 2
    end

    test "filters session headline metrics by supported session fields" do
      insert_session!(%{source_platform: "twitter", is_bounce: false, is_engaged: true})
      insert_session!(%{source_platform: "google", is_bounce: true, is_engaged: false})

      kpis = Analytics.kpis(@ws, window: window(), filters: [{:source_platform, :eq, "twitter"}])

      assert kpis.sessions == 1
      assert_in_delta kpis.engaged_rate, 1.0, 0.0001
      assert_in_delta kpis.bounce_rate, 0.0, 0.0001
    end

    test "computes visitors, new_visitors, pageviews, and revenue for the window" do
      v1 = create_visitor!(%{first_seen_at: ~U[2026-06-10 00:00:00.000000Z]})
      v2 = create_visitor!(%{first_seen_at: ~U[2026-05-01 00:00:00.000000Z]})

      record_event!(v1, "pageview", %{path: "/a"})
      record_event!(v1, "pageview", %{path: "/b"})
      record_event!(v2, "pageview", %{path: "/c"})
      record_event!(v2, "sale", %{path: "/buy", amount_cents: 5000})

      kpis = Analytics.kpis(@ws, window: window())

      assert kpis.visitors == 2
      assert kpis.new_visitors == 1
      assert kpis.pageviews == 3
      assert kpis.revenue == 5000
    end

    test "identification_rate is identified canonical visitors over total" do
      identified = create_visitor!(%{identified_at: ~U[2026-06-05 00:00:00.000000Z]})
      anon = create_visitor!(%{})

      record_event!(identified, "pageview", %{path: "/a"})
      record_event!(anon, "pageview", %{path: "/b"})

      kpis = Analytics.kpis(@ws, window: window())

      assert_in_delta kpis.identification_rate, 0.5, 0.0001
    end

    test "folds in session headline metrics" do
      # Seed only the session row directly: recording an event would itself
      # derive a session at ingest (sessions, #2), double-counting here. The
      # explicit session is all that's needed to prove kpis/2 folds in the
      # session headline metrics.
      insert_session!(%{is_bounce: false, is_engaged: true, duration_seconds: 30})

      kpis = Analytics.kpis(@ws, window: window())

      assert kpis.sessions == 1
      assert_in_delta kpis.engaged_rate, 1.0, 0.0001
      assert_in_delta kpis.bounce_rate, 0.0, 0.0001
      assert_in_delta kpis.avg_duration, 30.0, 0.0001
    end

    test "zeroed KPIs for an empty window" do
      kpis = Analytics.kpis(@ws, window: window())

      assert kpis.visitors == 0
      assert kpis.pageviews == 0
      assert kpis.revenue == 0
      assert kpis.identification_rate == 0.0
      assert kpis.sessions == 0
    end

    test "folds identification_rate into the same scan as visitors and pageviews" do
      # Guards the Task 1 refactor: identification_rate is now computed in the
      # same ga_events JOIN ga_visitors scan as visitors/pageviews, so assert
      # all three are mutually consistent from a single kpis/2 call.
      identified = create_visitor!(%{identified_at: ~U[2026-06-05 00:00:00.000000Z]})
      anon = create_visitor!(%{})

      record_event!(identified, "pageview", %{path: "/a"})
      record_event!(identified, "pageview", %{path: "/b"})
      record_event!(anon, "pageview", %{path: "/c"})

      kpis = Analytics.kpis(@ws, window: window())

      assert kpis.visitors == 2
      assert kpis.pageviews == 3
      assert_in_delta kpis.identification_rate, 0.5, 0.0001
    end
  end
end
