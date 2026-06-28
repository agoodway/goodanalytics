defmodule GoodAnalytics.Core.AnalyticsMetaTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Analytics

  describe "breakdown_dimensions/0" do
    test "lists exactly the supported breakdown dimensions" do
      assert Analytics.breakdown_dimensions() == [
               :channel,
               :source_platform,
               :source_medium,
               :source_campaign,
               :url,
               :click_id_param,
               :device_type,
               :browser,
               :os,
               :country,
               :city,
               :short_link
             ]
    end
  end

  describe "event_filter_fields/0" do
    test "lists exactly the allowlisted event filter fields" do
      assert Analytics.event_filter_fields() == [
               :inserted_at,
               :event_type,
               :source_platform,
               :source_medium,
               :source_campaign,
               :url,
               :click_id,
               :link_id
             ]
    end
  end

  describe "bucket_interval/1" do
    test "picks a sub-hour bucket for a one-hour window" do
      window = %{
        start_at: ~U[2026-06-01 00:00:00.000000Z],
        end_at: ~U[2026-06-01 01:00:00.000000Z]
      }

      assert Analytics.bucket_interval(window).key == :minute
    end

    test "picks an hourly bucket for a one-day window" do
      window = %{
        start_at: ~U[2026-06-01 00:00:00.000000Z],
        end_at: ~U[2026-06-02 00:00:00.000000Z]
      }

      assert Analytics.bucket_interval(window).key == :hour
    end

    test "falls back to the coarsest bucket for a very long window" do
      window = %{
        start_at: ~U[2020-01-01 00:00:00.000000Z],
        end_at: ~U[2026-01-01 00:00:00.000000Z]
      }

      assert Analytics.bucket_interval(window).key == :month
    end

    test "crosses the sub-hour regime edge just past one hour" do
      # 61 minutes: just over the <= 1h target-of-60 regime, so the target drops
      # to 24 buckets and the ladder picks the 5-minute interval.
      window = %{
        start_at: ~U[2026-06-01 00:00:00.000000Z],
        end_at: ~U[2026-06-01 01:01:00.000000Z]
      }

      assert Analytics.bucket_interval(window).key == :minute_5
    end

    test "crosses the multi-hour regime edge just past one day" do
      # 25 hours: past the <= 1d target-of-24 regime, so the target rises to 60
      # buckets and the ladder picks the 30-minute interval.
      window = %{
        start_at: ~U[2026-06-01 00:00:00.000000Z],
        end_at: ~U[2026-06-02 01:00:00.000000Z]
      }

      assert Analytics.bucket_interval(window).key == :minute_30
    end
  end

  describe "conversion_dimensions/0" do
    test "lists exactly the supported conversion dimensions" do
      assert Analytics.conversion_dimensions() == [
               :device_type,
               :browser,
               :os,
               :source_platform,
               :source_medium,
               :source_campaign
             ]
    end
  end
end
