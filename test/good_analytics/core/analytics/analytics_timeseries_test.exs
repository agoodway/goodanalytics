defmodule GoodAnalytics.Core.AnalyticsTimeseriesTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics
  alias GoodAnalytics.Core.Events.Event

  @ws GoodAnalytics.default_workspace_id()
  @hour %{key: :hour, label: "1h", seconds: 60 * 60}

  defp t0 do
    utc_now() |> truncate_hour() |> DateTime.add(-2, :hour)
  end

  # A 2-hour window with explicit hourly bucketing for deterministic buckets.
  defp hour_window do
    start = t0()
    %{start_at: start, end_at: DateTime.add(start, 2, :hour)}
  end

  defp opts do
    [
      window: hour_window(),
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
      base = t0()
      seed_pageview!(DateTime.add(base, 15, :minute))
      seed_pageview!(DateTime.add(base, 45, :minute))
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
      base = t0()
      v = create_visitor!()
      seed_event!(v, "pageview", DateTime.add(base, 10, :minute), %{path: "/a"})
      seed_event!(v, "pageview", DateTime.add(base, 20, :minute), %{path: "/b"})

      buckets = Analytics.timeseries(@ws, :visitors, opts())

      assert Enum.at(buckets, 0).value == 1
    end
  end

  describe "timeseries/3 — :revenue" do
    test "sums sale amount_cents per bucket" do
      base = t0()
      v = create_visitor!()

      seed_event!(v, "sale", DateTime.add(base, 30, :minute), %{
        path: "/buy",
        amount_cents: 2500
      })

      buckets = Analytics.timeseries(@ws, :revenue, opts())

      assert Enum.at(buckets, 0).value == 2500
    end
  end

  describe "timeseries/3 — filters" do
    test "an :eq filter narrows the series to matching events" do
      base = t0()
      v = create_visitor!()
      seed_event!(v, "pageview", DateTime.add(base, 15, :minute), %{source_campaign: "spring"})
      seed_event!(v, "pageview", DateTime.add(base, 45, :minute), %{source_campaign: "summer"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, :eq, "spring"}])
        )

      assert Enum.at(buckets, 0).value == 1
    end

    test "a bare {field, value} filter is treated as :eq (legacy contract)" do
      base = t0()
      v = create_visitor!()
      seed_event!(v, "pageview", DateTime.add(base, 15, :minute), %{source_campaign: "spring"})
      seed_event!(v, "pageview", DateTime.add(base, 45, :minute), %{source_campaign: "summer"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, "spring"}])
        )

      assert Enum.at(buckets, 0).value == 1
    end

    test "an :ilike filter escapes % as a literal, not a wildcard" do
      base = t0()
      v = create_visitor!()
      seed_event!(v, "pageview", DateTime.add(base, 15, :minute), %{source_campaign: "50%off"})

      seed_event!(v, "pageview", DateTime.add(base, 45, :minute), %{
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
      base = t0()
      v = create_visitor!()
      seed_event!(v, "pageview", DateTime.add(base, 15, :minute), %{source_campaign: "spring"})
      seed_event!(v, "pageview", DateTime.add(base, 45, :minute), %{source_campaign: "summer"})

      buckets =
        Analytics.timeseries(
          @ws,
          :pageviews,
          Keyword.put(opts(), :filters, [{:source_campaign, :neq, "spring"}])
        )

      assert Enum.at(buckets, 0).value == 1
    end

    test "a :not_in filter excludes the given set" do
      base = t0()
      v = create_visitor!()
      seed_event!(v, "pageview", DateTime.add(base, 10, :minute), %{source_campaign: "spring"})
      seed_event!(v, "pageview", DateTime.add(base, 20, :minute), %{source_campaign: "summer"})
      seed_event!(v, "pageview", DateTime.add(base, 30, :minute), %{source_campaign: "fall"})

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
    # America/Chicago springs forward on the second Sunday in March: the local
    # hour 02:00..03:00 does not exist (clocks jump 01:59:59 CST -> 03:00:00 CDT).
    # Buckets are built on naive local time, so generate_series still emits a
    # 02:00-local bucket; converting that non-existent local time back to UTC
    # resolves it to the same instant as 03:00 CDT (08:00Z), yielding a
    # zero-width, always-empty bucket. Real event hours bucket and zero-fill
    # normally around it.
    @chicago "America/Chicago"

    defp second_sunday_of_march(year) do
      march1 = Date.new!(year, 3, 1)
      offset_to_first_sunday = rem(7 - Date.day_of_week(march1) + 7, 7)
      Date.add(march1, offset_to_first_sunday + 7)
    end

    defp dst_window do
      year = Date.utc_today().year
      spring_day = second_sunday_of_march(year)

      # 01:00 CST = 07:00Z; 03:00 CDT = 09:00Z on US spring-forward Sunday.
      start_utc = DateTime.new!(spring_day, ~T[07:00:00.000000], "Etc/UTC")
      end_utc = DateTime.new!(spring_day, ~T[09:00:00.000000], "Etc/UTC")

      %{
        spring_day: spring_day,
        start_at: start_utc,
        end_at: end_utc
      }
    end

    defp dst_opts do
      window = dst_window()

      [
        window: Map.take(window, [:start_at, :end_at]),
        timezone: @chicago,
        bucket_interval: @hour
      ]
    end

    test "buckets and zero-fills around the non-existent local hour" do
      %{spring_day: spring_day, start_at: start_utc} = dst_window()
      v = create_visitor!()
      # +30 min -> first local bucket (01:00..02:00 local)
      seed_event!(v, "pageview", DateTime.add(start_utc, 30, :minute))
      # +90 min -> last local bucket (03:00..04:00 local)
      seed_event!(v, "pageview", DateTime.add(start_utc, 90, :minute))

      buckets = Analytics.timeseries(@ws, :pageviews, dst_opts())

      # Three local bucket starts: 01:00, the skipped 02:00, and 03:00 local.
      assert length(buckets) == 3

      [first, gap, last] = buckets

      # The two real wall-clock hours carry their single event each.
      assert first.value == 1
      assert last.value == 1

      # The skipped 02:00 local hour resolves to a zero-width, empty bucket: it
      # maps to the same UTC instant (08:00Z on spring-forward day) on both
      # edges and never matches an event row.
      gap_expected = DateTime.new!(spring_day, ~T[08:00:00.000000], "Etc/UTC")

      assert gap.value == 0
      assert DateTime.compare(gap.bucket_start, gap.bucket_end) == :eq
      assert DateTime.to_iso8601(gap.bucket_start) == DateTime.to_iso8601(gap_expected)

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
      base = t0()

      insert_session!(%{
        started_at: DateTime.add(base, 10, :minute),
        last_event_at: DateTime.add(base, 12, :minute),
        is_engaged: true
      })

      insert_session!(%{
        started_at: DateTime.add(base, 40, :minute),
        last_event_at: DateTime.add(base, 41, :minute),
        is_engaged: false
      })

      buckets = Analytics.timeseries(@ws, :sessions, opts())

      assert Enum.at(buckets, 0).value == 2
      assert Enum.at(buckets, 1).value == 0
    end

    test "buckets engaged-session counts by started_at" do
      base = t0()

      insert_session!(%{
        started_at: DateTime.add(base, 10, :minute),
        last_event_at: DateTime.add(base, 12, :minute),
        is_engaged: true
      })

      insert_session!(%{
        started_at: DateTime.add(base, 40, :minute),
        last_event_at: DateTime.add(base, 41, :minute),
        is_engaged: false
      })

      buckets = Analytics.timeseries(@ws, :engaged, opts())

      assert Enum.at(buckets, 0).value == 1
    end
  end
end
