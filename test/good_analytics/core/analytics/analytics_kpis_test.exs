defmodule GoodAnalytics.Core.AnalyticsKpisTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics
  alias GoodAnalytics.Core.Sessions.Session

  @ws GoodAnalytics.default_workspace_id()

  defp window, do: query_window()

  defp event_time, do: ~U[2026-06-10 12:00:00.000000Z]

  defp insert_session!(attrs) do
    t = utc_now()

    base = %{
      workspace_id: @ws,
      visitor_id: Uniq.UUID.uuid7(),
      started_at: t,
      last_event_at: t
    }

    %Session{id: Uniq.UUID.uuid7()}
    |> Session.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
  end

  describe "kpis/2" do
    test "counts only events matching the filter" do
      t = utc_now()
      twitter_visitor = create_visitor!(%{first_seen_at: t})
      google_visitor = create_visitor!(%{first_seen_at: t})

      record_event!(twitter_visitor, "pageview", %{platform: "twitter", inserted_at: event_time()})

      record_event!(google_visitor, "pageview", %{platform: "google", inserted_at: event_time()})

      kpis = Analytics.kpis(@ws, window: window(), filters: [{:source_platform, :eq, "twitter"}])

      assert kpis.visitors == 1
      assert kpis.new_visitors == 1
      assert kpis.pageviews == 1
    end

    test "no filters counts everything" do
      visitor = create_visitor!(%{})

      record_event!(visitor, "pageview", %{platform: "twitter", inserted_at: event_time()})
      record_event!(visitor, "pageview", %{platform: "google", inserted_at: event_time()})

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
      t = utc_now()
      # New in window
      v1 = create_visitor!(%{first_seen_at: t})
      # Returning — first seen before the window
      v2 = create_visitor!(%{first_seen_at: at(-30, :day)})

      record_event!(v1, "pageview", %{path: "/a", inserted_at: event_time()})
      record_event!(v1, "pageview", %{path: "/b", inserted_at: event_time()})
      record_event!(v2, "pageview", %{path: "/c", inserted_at: event_time()})
      record_event!(v2, "sale", %{path: "/buy", amount_cents: 5000, inserted_at: event_time()})

      kpis = Analytics.kpis(@ws, window: window())

      assert kpis.visitors == 2
      assert kpis.new_visitors == 1
      assert kpis.pageviews == 3
      assert kpis.revenue == 5000
    end

    test "identification_rate is identified canonical visitors over total" do
      t = utc_now()
      identified = create_visitor!(%{identified_at: DateTime.add(t, -5, :day)})
      anon = create_visitor!(%{})

      record_event!(identified, "pageview", %{path: "/a", inserted_at: event_time()})
      record_event!(anon, "pageview", %{path: "/b", inserted_at: event_time()})

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
      t = utc_now()
      identified = create_visitor!(%{identified_at: DateTime.add(t, -5, :day)})
      anon = create_visitor!(%{})

      record_event!(identified, "pageview", %{path: "/a", inserted_at: event_time()})
      record_event!(identified, "pageview", %{path: "/b", inserted_at: event_time()})
      record_event!(anon, "pageview", %{path: "/c", inserted_at: event_time()})

      kpis = Analytics.kpis(@ws, window: window())

      assert kpis.visitors == 2
      assert kpis.pageviews == 3
      assert_in_delta kpis.identification_rate, 0.5, 0.0001
    end
  end
end
