defmodule GoodAnalytics.Core.AnalyticsTimeseriesTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics
  alias GoodAnalytics.Core.Events.Event

  @ws GoodAnalytics.default_workspace_id()
  @hour %{key: :hour, label: "1h", seconds: 60 * 60}

  # A 2-hour window with explicit hourly bucketing for deterministic buckets.
  defp opts do
    [
      window: %{
        start_at: ~U[2026-06-10 00:00:00.000000Z],
        end_at: ~U[2026-06-10 02:00:00.000000Z]
      },
      timezone: "Etc/UTC",
      bucket_interval: @hour
    ]
  end

  # Seeds one event at an EXACT inserted_at via a direct Event insert.
  # Recorder.record/3 stamps its own system inserted_at and does not cast the
  # attr, so deterministic bucketing requires setting inserted_at on the struct
  # (mirrors seed_event!/3 in the audience tests).
  defp seed_event!(visitor, event_type, at, attrs \\ %{}) do
    base = %{
      workspace_id: @ws,
      visitor_id: visitor.id,
      event_type: event_type,
      url: "https://x.test/p",
      path: "/p"
    }

    %Event{id: Uniq.UUID.uuid7(), inserted_at: at}
    |> Event.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  defp seed_pageview!(at) do
    visitor = create_visitor!()
    seed_event!(visitor, "pageview", at)
    visitor
  end

  describe "timeseries/3 — :pageviews" do
    test "buckets pageviews per hour, zero-filling empty buckets" do
      seed_pageview!(~U[2026-06-10 00:15:00.000000Z])
      seed_pageview!(~U[2026-06-10 00:45:00.000000Z])
      # second hour intentionally empty

      buckets = Analytics.timeseries(@ws, :pageviews, opts())

      assert length(buckets) == 2
      assert Enum.at(buckets, 0).value == 2
      assert Enum.at(buckets, 1).value == 0
      assert %DateTime{} = Enum.at(buckets, 0).bucket_start
      assert %DateTime{} = Enum.at(buckets, 0).bucket_end
    end
  end

  describe "timeseries/3 — :visitors" do
    test "counts distinct canonical visitors per bucket" do
      v = create_visitor!()
      seed_event!(v, "pageview", ~U[2026-06-10 00:10:00.000000Z], %{path: "/a"})
      seed_event!(v, "pageview", ~U[2026-06-10 00:20:00.000000Z], %{path: "/b"})

      buckets = Analytics.timeseries(@ws, :visitors, opts())

      assert Enum.at(buckets, 0).value == 1
    end
  end

  describe "timeseries/3 — :revenue" do
    test "sums sale amount_cents per bucket" do
      v = create_visitor!()

      seed_event!(v, "sale", ~U[2026-06-10 00:30:00.000000Z], %{
        path: "/buy",
        amount_cents: 2500
      })

      buckets = Analytics.timeseries(@ws, :revenue, opts())

      assert Enum.at(buckets, 0).value == 2500
    end
  end

  describe "timeseries/3 — filters" do
    test "an :eq filter narrows the series to matching events" do
      v = create_visitor!()
      seed_event!(v, "pageview", ~U[2026-06-10 00:15:00.000000Z], %{source_campaign: "spring"})
      seed_event!(v, "pageview", ~U[2026-06-10 00:45:00.000000Z], %{source_campaign: "summer"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, :eq, "spring"}])
        )

      assert Enum.at(buckets, 0).value == 1
    end

    test "a bare {field, value} filter is treated as :eq (legacy contract)" do
      v = create_visitor!()
      seed_event!(v, "pageview", ~U[2026-06-10 00:15:00.000000Z], %{source_campaign: "spring"})
      seed_event!(v, "pageview", ~U[2026-06-10 00:45:00.000000Z], %{source_campaign: "summer"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, "spring"}])
        )

      assert Enum.at(buckets, 0).value == 1
    end

    test "an :ilike filter escapes % as a literal, not a wildcard" do
      v = create_visitor!()
      seed_event!(v, "pageview", ~U[2026-06-10 00:15:00.000000Z], %{source_campaign: "50%off"})

      seed_event!(v, "pageview", ~U[2026-06-10 00:45:00.000000Z], %{
        source_campaign: "50-summer-off"
      })

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, :ilike, "50%off"}])
        )

      # With % escaped, only the literal "50%off" event matches → 1, not 2.
      assert Enum.at(buckets, 0).value == 1
    end

    test "a :neq filter excludes matching events" do
      v = create_visitor!()
      seed_event!(v, "pageview", ~U[2026-06-10 00:15:00.000000Z], %{source_campaign: "spring"})
      seed_event!(v, "pageview", ~U[2026-06-10 00:45:00.000000Z], %{source_campaign: "summer"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, :neq, "spring"}])
        )

      assert Enum.at(buckets, 0).value == 1
    end

    test "a :not_in filter excludes the given set" do
      v = create_visitor!()
      seed_event!(v, "pageview", ~U[2026-06-10 00:10:00.000000Z], %{source_campaign: "spring"})
      seed_event!(v, "pageview", ~U[2026-06-10 00:20:00.000000Z], %{source_campaign: "summer"})
      seed_event!(v, "pageview", ~U[2026-06-10 00:30:00.000000Z], %{source_campaign: "fall"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, :not_in, ["spring", "summer"]}])
        )

      # only the "fall" event survives the exclusion
      assert Enum.at(buckets, 0).value == 1
    end
  end

  describe "timeseries/3 — non-UTC DST window" do
    # America/Chicago springs forward on 2026-03-08: the local hour 02:00..03:00
    # does not exist (clocks jump 01:59:59 CST -> 03:00:00 CDT). Buckets are
    # built on naive local time, so generate_series still emits a 02:00-local
    # bucket; converting that non-existent local time back to UTC resolves it to
    # the same instant as 03:00 CDT (08:00Z), yielding a zero-width, always-empty
    # bucket. Real event hours bucket and zero-fill normally around it.
    @chicago "America/Chicago"

    defp dst_opts do
      [
        # 01:00 CST = 07:00Z; 03:00 CDT = 09:00Z. The naive-local span 01:00..03:00
        # spans three local bucket starts: 01:00, 02:00 (skipped), 03:00.
        window: %{
          start_at: ~U[2026-03-08 07:00:00.000000Z],
          end_at: ~U[2026-03-08 09:00:00.000000Z]
        },
        timezone: @chicago,
        bucket_interval: @hour
      ]
    end

    test "buckets and zero-fills around the non-existent local hour" do
      v = create_visitor!()
      # 01:30 CST = 07:30Z -> first local bucket (01:00..02:00 local)
      seed_event!(v, "pageview", ~U[2026-03-08 07:30:00.000000Z])
      # 03:30 CDT = 08:30Z -> last local bucket (03:00..04:00 local)
      seed_event!(v, "pageview", ~U[2026-03-08 08:30:00.000000Z])

      buckets = Analytics.timeseries(@ws, :pageviews, dst_opts())

      # Three local bucket starts: 01:00, the skipped 02:00, and 03:00 local.
      assert length(buckets) == 3

      [first, gap, last] = buckets

      # The two real wall-clock hours carry their single event each.
      assert first.value == 1
      assert last.value == 1

      # The skipped 02:00 local hour resolves to a zero-width, empty bucket: it
      # maps to the same UTC instant (08:00Z) on both edges and never matches an
      # event row.
      assert gap.value == 0
      assert DateTime.compare(gap.bucket_start, gap.bucket_end) == :eq
      assert DateTime.to_iso8601(gap.bucket_start) == "2026-03-08T08:00:00.000000Z"

      # The real data buckets sit one UTC hour apart (01:00 CST -> 03:00 CDT is
      # 60 wall-clock minutes across the spring-forward gap).
      assert DateTime.diff(last.bucket_start, first.bucket_start, :second) == 3600
    end
  end

  describe "timeseries/3 — validation" do
    test "raises ArgumentError on an unsupported metric" do
      assert_raise ArgumentError, fn ->
        Analytics.timeseries(@ws, :bogus, opts())
      end
    end
  end

  describe "timeseries/3 — session metrics" do
    alias GoodAnalytics.Core.Sessions.Session

    defp insert_session!(attrs) do
      base = %{workspace_id: @ws, visitor_id: Uniq.UUID.uuid7()}

      %Session{id: Uniq.UUID.uuid7()}
      |> Session.changeset(Map.merge(base, attrs))
      |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
    end

    test "buckets session counts by started_at" do
      insert_session!(%{
        started_at: ~U[2026-06-10 00:10:00.000000Z],
        last_event_at: ~U[2026-06-10 00:12:00.000000Z],
        is_engaged: true
      })

      insert_session!(%{
        started_at: ~U[2026-06-10 00:40:00.000000Z],
        last_event_at: ~U[2026-06-10 00:41:00.000000Z],
        is_engaged: false
      })

      buckets = Analytics.timeseries(@ws, :sessions, opts())

      assert Enum.at(buckets, 0).value == 2
      assert Enum.at(buckets, 1).value == 0
    end

    test "buckets engaged-session counts by started_at" do
      insert_session!(%{
        started_at: ~U[2026-06-10 00:10:00.000000Z],
        last_event_at: ~U[2026-06-10 00:12:00.000000Z],
        is_engaged: true
      })

      insert_session!(%{
        started_at: ~U[2026-06-10 00:40:00.000000Z],
        last_event_at: ~U[2026-06-10 00:41:00.000000Z],
        is_engaged: false
      })

      buckets = Analytics.timeseries(@ws, :engaged, opts())

      assert Enum.at(buckets, 0).value == 1
    end
  end
end
