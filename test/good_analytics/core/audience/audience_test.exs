defmodule GoodAnalytics.Core.AudienceTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Audience
  alias GoodAnalytics.Core.Events.Event

  @ws GoodAnalytics.default_workspace_id()

  # A wide-open window covering all seeded rows.
  defp window do
    %{start_at: ~U[2026-06-01 00:00:00.000000Z], end_at: ~U[2026-06-30 00:00:00.000000Z]}
  end

  # Seeds one pageview for a fresh visitor with the given device columns.
  # Uses a direct Event insert so explicit device_type values are preserved;
  # Recorder.record/3 drops device fields and re-derives them from user_agent.
  defp seed_pageview!(device_attrs) do
    visitor = create_visitor!()

    attrs =
      Map.merge(
        %{
          workspace_id: @ws,
          visitor_id: visitor.id,
          event_type: "pageview",
          url: "https://x.test/p",
          path: "/p"
        },
        device_attrs
      )

    %Event{id: Uniq.UUID.uuid7(), inserted_at: ~U[2026-06-15 12:00:00.000000Z]}
    |> Event.changeset(attrs)
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")

    visitor
  end

  # Seeds one event for the GIVEN visitor with explicit device columns.
  # Like seed_pageview!/1 it inserts via Event.changeset directly so explicit
  # device_type/browser/etc. survive (Recorder.record/3 drops and re-derives
  # them from user_agent). Used for the cross-device / merged-visitor cases
  # where multiple events must share one visitor.
  defp seed_event!(visitor, event_type, attrs) do
    {path, attrs} = Map.pop(attrs, :path, "/p")

    base = %{
      workspace_id: @ws,
      visitor_id: visitor.id,
      event_type: event_type,
      url: "https://x.test#{path}",
      path: path
    }

    inserted_at = seed_clock()

    %Event{id: Uniq.UUID.uuid7(), inserted_at: inserted_at}
    |> Event.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  # Monotonic-ish clock inside window/0 so each seeded row is distinct.
  defp seed_clock do
    n = System.unique_integer([:positive, :monotonic])
    DateTime.add(~U[2026-06-15 12:00:00.000000Z], n, :microsecond)
  end

  defp fetch(rows, value), do: Enum.find(rows, &(&1.value == value))

  describe "breakdown/3 — :device_type with :events" do
    test "buckets events by the event's own device_type" do
      seed_pageview!(%{device_type: "desktop"})
      seed_pageview!(%{device_type: "desktop"})
      seed_pageview!(%{device_type: "mobile"})

      rows = Audience.breakdown(@ws, :device_type, window: window(), metrics: [:events])

      assert fetch(rows, "desktop").events == 2
      assert fetch(rows, "mobile").events == 1
    end

    test "null device_type is bucketed as (not set)" do
      seed_pageview!(%{})

      rows = Audience.breakdown(@ws, :device_type, window: window(), metrics: [:events])

      assert fetch(rows, "(not set)").events == 1
    end

    test "raises ArgumentError on an unknown dimension" do
      assert_raise ArgumentError, fn ->
        Audience.breakdown(@ws, :nonsense, window: window(), metrics: [:events])
      end
    end

    test "raises ArgumentError on an unknown metric" do
      assert_raise ArgumentError, fn ->
        Audience.breakdown(@ws, :device_type, window: window(), metrics: [:bogus])
      end
    end

    test "returns [] for an empty window" do
      seed_pageview!(%{device_type: "desktop"})

      empty = %{
        start_at: ~U[2030-01-01 00:00:00.000000Z],
        end_at: ~U[2030-01-02 00:00:00.000000Z]
      }

      assert Audience.breakdown(@ws, :device_type, window: empty, metrics: [:events]) == []
    end
  end

  describe "breakdown/3 — :events and :pageviews" do
    test "pageviews counts only pageview events" do
      visitor = create_visitor!()
      seed_event!(visitor, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(visitor, "lead", %{path: "/a", device_type: "desktop"})

      rows =
        Audience.breakdown(@ws, :device_type, window: window(), metrics: [:events, :pageviews])

      row = fetch(rows, "desktop")

      assert row.events == 2
      assert row.pageviews == 1
    end
  end

  describe "breakdown/3 — :users non-additivity (cross-device)" do
    test "one cross-device visitor is counted in both device buckets" do
      # A single visitor active on BOTH desktop and mobile.
      cross = create_visitor!()
      seed_event!(cross, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(cross, "pageview", %{path: "/b", device_type: "mobile"})

      # A second visitor only on desktop.
      only_desktop = create_visitor!()
      seed_event!(only_desktop, "pageview", %{path: "/c", device_type: "desktop"})

      rows = Audience.breakdown(@ws, :device_type, window: window(), metrics: [:users])

      desktop_users = fetch(rows, "desktop").users
      mobile_users = fetch(rows, "mobile").users

      # cross + only_desktop on desktop = 2; cross on mobile = 1.
      assert desktop_users == 2
      assert mobile_users == 1

      # NON-ADDITIVE: bucket-sum (3) exceeds the 2 distinct people.
      assert desktop_users + mobile_users == 3
      distinct_people = 2
      assert desktop_users + mobile_users > distinct_people
    end

    test "merged_into_id collapses merged visitors into one user" do
      primary = create_visitor!()
      secondary = create_visitor!(%{merged_into_id: primary.id, status: "merged"})

      seed_event!(primary, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(secondary, "pageview", %{path: "/b", device_type: "desktop"})

      rows = Audience.breakdown(@ws, :device_type, window: window(), metrics: [:users])
      # Two visitor rows, two events, but one canonical person.
      assert fetch(rows, "desktop").users == 1
    end
  end

  describe "breakdown/3 — :country (visitor geo)" do
    test "buckets events by visitor geo country_code with a (not set) bucket" do
      us = create_visitor!(%{geo: %{"country_code" => "US", "country" => "United States"}})
      fr = create_visitor!(%{geo: %{"country_code" => "FR", "country" => "France"}})
      unknown = create_visitor!(%{geo: %{}})

      record_event!(us, "pageview", %{path: "/a"})
      record_event!(us, "pageview", %{path: "/b"})
      record_event!(fr, "pageview", %{path: "/c"})
      record_event!(unknown, "pageview", %{path: "/d"})

      rows = Audience.breakdown(@ws, :country, window: window(), metrics: [:events, :users])

      assert fetch(rows, "US").events == 2
      assert fetch(rows, "US").users == 1
      assert fetch(rows, "FR").events == 1
      assert fetch(rows, "(not set)").events == 1
    end

    test "requesting a session metric for :country raises ArgumentError" do
      create_visitor!(%{geo: %{"country_code" => "US"}})

      assert_raise ArgumentError, fn ->
        Audience.breakdown(@ws, :country, window: window(), metrics: [:sessions])
      end
    end
  end

  describe "breakdown/3 — filters, order, limit" do
    test "filters drill down to a single dimension value" do
      d = create_visitor!()
      seed_event!(d, "pageview", %{path: "/a", device_type: "desktop", browser: "Chrome"})
      seed_event!(d, "pageview", %{path: "/b", device_type: "mobile", browser: "Safari"})

      rows =
        Audience.breakdown(@ws, :browser,
          window: window(),
          metrics: [:events],
          filters: [device_type: "desktop"]
        )

      assert fetch(rows, "Chrome").events == 1
      assert fetch(rows, "Safari") == nil
    end

    test "orders by the first requested metric descending and limits rows" do
      big = create_visitor!()
      for _ <- 1..3, do: seed_event!(big, "pageview", %{path: "/x", device_type: "desktop"})

      small = create_visitor!()
      seed_event!(small, "pageview", %{path: "/y", device_type: "mobile"})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events],
          limit: 1
        )

      assert length(rows) == 1
      assert hd(rows).value == "desktop"
    end

    test "explicit order_by ascending" do
      big = create_visitor!()
      for _ <- 1..3, do: seed_event!(big, "pageview", %{path: "/x", device_type: "desktop"})

      small = create_visitor!()
      seed_event!(small, "pageview", %{path: "/y", device_type: "mobile"})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events],
          order_by: {:events, :asc}
        )

      assert hd(rows).value == "mobile"
    end
  end

  describe "breakdown/3 — filter + session metric validation" do
    test "raises when a session metric is requested with a filter on a session-less dimension" do
      assert_raise ArgumentError, fn ->
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:sessions],
          filters: [country: "US"]
        )
      end
    end
  end

  describe "breakdown/3 — session-grain metrics" do
    alias GoodAnalytics.Core.Sessions.Session

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

    test "sessions, bounce_rate, avg_duration, and engaged_rate per device bucket" do
      # Desktop: 2 sessions — one bounced/not-engaged 0s, one not-bounced/engaged 30s.
      insert_session!(%{
        device_type: "desktop",
        is_bounce: true,
        is_engaged: false,
        duration_seconds: 0
      })

      insert_session!(%{
        device_type: "desktop",
        is_bounce: false,
        is_engaged: true,
        duration_seconds: 30
      })

      # Mobile: 1 bounced/not-engaged session.
      insert_session!(%{
        device_type: "mobile",
        is_bounce: true,
        is_engaged: false,
        duration_seconds: 0
      })

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:sessions, :bounce_rate, :avg_duration, :engaged_rate]
        )

      desktop = fetch(rows, "desktop")
      assert desktop.sessions == 2
      assert_in_delta desktop.bounce_rate, 0.5, 0.0001
      assert_in_delta desktop.avg_duration, 15.0, 0.0001
      assert_in_delta desktop.engaged_rate, 0.5, 0.0001

      mobile = fetch(rows, "mobile")
      assert mobile.sessions == 1
      assert_in_delta mobile.bounce_rate, 1.0, 0.0001
    end

    test "mixes event/person and session metrics in one call" do
      visitor = create_visitor!()
      seed_event!(visitor, "pageview", %{path: "/a", device_type: "desktop"})

      insert_session!(%{device_type: "desktop", is_bounce: false, duration_seconds: 10})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events, :users, :sessions, :avg_duration]
        )

      desktop = fetch(rows, "desktop")
      assert desktop.events == 1
      assert desktop.users == 1
      assert desktop.sessions == 1
      assert_in_delta desktop.avg_duration, 10.0, 0.0001
    end

    test "a dimension value present only in sessions still appears with zeroed event metrics" do
      insert_session!(%{device_type: "tablet", is_bounce: true, duration_seconds: 0})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events, :sessions]
        )

      tablet = fetch(rows, "tablet")
      assert tablet.sessions == 1
      assert tablet.events == 0
    end

    test "a dimension value present only in events defaults its session metric" do
      # One event on "desktop" with no matching session row.
      visitor = create_visitor!()
      seed_event!(visitor, "pageview", %{path: "/a", device_type: "desktop"})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events, :sessions]
        )

      desktop = fetch(rows, "desktop")
      assert desktop.events == 1
      # Session metrics for an event-only value fall back to the documented
      # default from merge_metric_values, which is nil.
      assert desktop.sessions == nil
    end
  end

  describe "breakdown/3 — single-grain ordering and limit" do
    test "event-only breakdown returns the top-N buckets ordered by the metric" do
      desk = create_visitor!()
      seed_event!(desk, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(desk, "pageview", %{path: "/b", device_type: "desktop"})
      seed_event!(desk, "pageview", %{path: "/c", device_type: "desktop"})

      mob = create_visitor!()
      seed_event!(mob, "pageview", %{path: "/d", device_type: "mobile"})

      tab = create_visitor!()
      seed_event!(tab, "pageview", %{path: "/e", device_type: "tablet"})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events],
          order_by: {:events, :desc},
          limit: 2
        )

      assert length(rows) == 2
      assert hd(rows).value == "desktop"
      assert hd(rows).events == 3
      # desktop (3) is rank 1; mobile and tablet tie at 1 event, so exactly one of
      # them fills rank 2 — assert the metric, not which tied value wins.
      assert Enum.at(rows, 1).events == 1
    end

    test "ascending order returns the smallest bucket first" do
      desk = create_visitor!()
      seed_event!(desk, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(desk, "pageview", %{path: "/b", device_type: "desktop"})

      mob = create_visitor!()
      seed_event!(mob, "pageview", %{path: "/c", device_type: "mobile"})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events],
          order_by: {:events, :asc},
          limit: 1
        )

      assert length(rows) == 1
      assert hd(rows).value == "mobile"
    end

    test "session-only breakdown pushes ORDER BY/LIMIT and returns the top-N buckets" do
      insert_session!(%{device_type: "desktop", is_bounce: false, duration_seconds: 10})
      insert_session!(%{device_type: "desktop", is_bounce: false, duration_seconds: 20})
      insert_session!(%{device_type: "desktop", is_bounce: true, duration_seconds: 0})
      insert_session!(%{device_type: "mobile", is_bounce: true, duration_seconds: 0})

      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:sessions, :bounce_rate],
          order_by: {:sessions, :desc},
          limit: 1
        )

      assert length(rows) == 1
      assert hd(rows).value == "desktop"
      assert hd(rows).sessions == 3
    end

    test "out-of-grain order metric does not push down and does not crash" do
      v = create_visitor!()
      seed_event!(v, "pageview", %{path: "/a", device_type: "desktop"})

      # metrics is event-only but order_by names a session metric; this must not
      # raise (the session metric is simply absent from the rows).
      rows =
        Audience.breakdown(@ws, :device_type,
          window: window(),
          metrics: [:events],
          order_by: {:sessions, :desc}
        )

      assert [%{value: "desktop", events: 1}] = rows
    end
  end
end
