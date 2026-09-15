defmodule GoodAnalytics.Core.Sessions.SessionFieldsTest do
  use ExUnit.Case, async: true

  import GoodAnalytics.TestHelpers

  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Core.Sessions.SessionFields

  defp t0, do: utc_now()

  defp new_session(attrs) do
    t = t0()

    base = %{
      workspace_id: "00000000-0000-0000-0000-000000000000",
      visitor_id: Uniq.UUID.uuid7(),
      started_at: t,
      last_event_at: t,
      pageviews: 0,
      events: 0,
      duration_seconds: 0,
      engaged_seconds: 0,
      is_bounce: true,
      is_engaged: false
    }

    struct(%Session{}, Map.merge(base, attrs))
  end

  describe "new_session_attrs/3 — first event" do
    test "seeds entry, source, device, started_at, and counters from a pageview" do
      t = t0()

      attrs = %{
        url: "https://x.test/landing",
        path: "/landing",
        source_platform: "google",
        source_medium: "cpc",
        device_type: "desktop",
        browser: "Chrome",
        os: "Mac"
      }

      seed = SessionFields.new_session_attrs("pageview", attrs, t)

      assert seed.started_at == t
      assert seed.last_event_at == t
      assert seed.entry_url == "https://x.test/landing"
      assert seed.entry_page == "/landing"
      assert seed.exit_page == "/landing"
      assert seed.pageviews == 1
      assert seed.events == 1
      assert seed.duration_seconds == 0
      assert seed.is_bounce == true
      assert seed.is_engaged == false
      assert seed.source_platform == "google"
      assert seed.device_type == "desktop"
    end

    test "derives entry and exit page from url when path is missing" do
      t = t0()

      seed =
        SessionFields.new_session_attrs(
          "pageview",
          %{url: "https://x.test/docs/getting-started?utm_source=seed#hero"},
          t
        )

      assert seed.entry_url == "https://x.test/docs/getting-started?utm_source=seed#hero"
      assert seed.entry_page == "/docs/getting-started"
      assert seed.exit_page == "/docs/getting-started"
    end

    test "a first non-pageview interactive event is not a bounce and counts only as an event" do
      t = t0()
      seed = SessionFields.new_session_attrs("lead", %{path: "/contact"}, t)

      assert seed.pageviews == 0
      assert seed.events == 1
      assert seed.is_bounce == false
      # A conversion makes the session engaged immediately.
      assert seed.is_engaged == true
    end

    test "a first non-interactive non-pageview event remains a bounce" do
      t = t0()
      seed = SessionFields.new_session_attrs("session_start", %{path: "/landing"}, t)

      assert seed.pageviews == 0
      assert seed.events == 1
      assert seed.is_bounce == true
      assert seed.is_engaged == false
    end
  end

  describe "update_session_attrs/4 — subsequent events" do
    test "second pageview flips bounce, bumps counters, sets exit, and recomputes duration" do
      t = t0()

      live =
        new_session(%{
          pageviews: 1,
          events: 1,
          entry_page: "/landing",
          exit_page: "/landing",
          started_at: t,
          last_event_at: t
        })

      ts = DateTime.add(t, 30, :second)

      changes = SessionFields.update_session_attrs(live, "pageview", %{path: "/pricing"}, ts)

      assert changes.last_event_at == ts
      assert changes.pageviews == 2
      assert changes.events == 2
      assert changes.exit_page == "/pricing"
      assert changes.is_bounce == false
      assert changes.duration_seconds == 30
      # 2 pageviews ⇒ engaged.
      assert changes.is_engaged == true
    end

    test "derives exit page from url when a later pageview has no path" do
      t = t0()

      live =
        new_session(%{
          pageviews: 1,
          events: 1,
          entry_page: "/landing",
          exit_page: "/landing",
          started_at: t,
          last_event_at: t
        })

      ts = DateTime.add(t, 30, :second)

      changes =
        SessionFields.update_session_attrs(
          live,
          "pageview",
          %{url: "https://x.test/pricing?utm_source=seed#plans"},
          ts
        )

      assert changes.exit_page == "/pricing"
    end

    test "an interactive non-pageview event flips bounce without incrementing pageviews" do
      t = t0()
      live = new_session(%{pageviews: 1, events: 1, started_at: t, last_event_at: t})
      ts = DateTime.add(t, 5, :second)

      changes = SessionFields.update_session_attrs(live, "lead", %{path: "/contact"}, ts)

      assert changes.pageviews == 1
      assert changes.events == 2
      assert changes.is_bounce == false
      assert changes.is_engaged == true
    end

    test "engagement events do not flip bounce" do
      t = t0()

      live =
        new_session(%{pageviews: 1, events: 1, is_bounce: true, started_at: t, last_event_at: t})

      ts = DateTime.add(t, 5, :second)

      changes = SessionFields.update_session_attrs(live, "engagement", %{path: "/landing"}, ts)

      assert changes.pageviews == 1
      assert changes.events == 2
      assert changes.exit_page == nil
      assert changes.is_bounce == true
    end

    test "non-interactive non-pageview events do not flip bounce" do
      t = t0()

      live =
        new_session(%{pageviews: 1, events: 1, is_bounce: true, started_at: t, last_event_at: t})

      ts = DateTime.add(t, 5, :second)

      changes = SessionFields.update_session_attrs(live, "session_start", %{path: "/landing"}, ts)

      assert changes.pageviews == 1
      assert changes.events == 2
      assert changes.is_bounce == true
    end

    test "duration is capped per-hop at 30 minutes (clock-skew guard)" do
      t = t0()

      live =
        new_session(%{
          pageviews: 1,
          events: 1,
          duration_seconds: 10,
          started_at: t,
          last_event_at: t
        })

      # 90-minute jump on a single hop.
      ts = DateTime.add(t, 90 * 60, :second)

      changes = SessionFields.update_session_attrs(live, "pageview", %{path: "/p2"}, ts)

      # started_at..last_event_at would be 90m, but the hop is capped at 30m,
      # so duration grows by at most 30m (1800s) on this event.
      assert changes.duration_seconds == 10 + 1800
    end

    test "engaged via 10s dwell threshold is decided by engaged_seconds, not duration" do
      t = t0()

      live =
        new_session(%{
          pageviews: 1,
          events: 1,
          engaged_seconds: 12,
          started_at: t,
          last_event_at: t
        })

      ts = DateTime.add(t, 5, :second)

      changes = SessionFields.update_session_attrs(live, "identify", %{path: "/p1"}, ts)

      assert changes.pageviews == 1
      assert changes.is_engaged == true
    end

    test "out-of-order timestamps do not reduce duration" do
      t = t0()

      live =
        new_session(%{
          pageviews: 1,
          events: 1,
          duration_seconds: 10,
          started_at: t,
          last_event_at: t
        })

      ts = DateTime.add(t, -5, :second)

      changes = SessionFields.update_session_attrs(live, "pageview", %{path: "/p2"}, ts)

      assert changes.duration_seconds == 10
    end
  end

  describe "engaged?/1" do
    test "true at >= 10 engaged seconds" do
      assert SessionFields.engaged?(new_session(%{engaged_seconds: 10}))
    end

    test "true at >= 2 pageviews" do
      assert SessionFields.engaged?(new_session(%{pageviews: 2}))
    end

    test "false for a single short pageview" do
      refute SessionFields.engaged?(new_session(%{pageviews: 1, engaged_seconds: 3}))
    end
  end
end
