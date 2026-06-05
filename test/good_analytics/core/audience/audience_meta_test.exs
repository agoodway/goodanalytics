defmodule GoodAnalytics.Core.AudienceMetaTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Audience

  describe "dimensions/0" do
    test "lists exactly the supported breakdown dimensions" do
      assert Audience.dimensions() == [
               :device_type,
               :browser,
               :os,
               :source_platform,
               :source_medium,
               :source_campaign,
               :country
             ]
    end
  end

  describe "metrics/0" do
    test "lists every supported metric" do
      assert Audience.metrics() == [
               :events,
               :pageviews,
               :users,
               :sessions,
               :bounce_rate,
               :avg_duration,
               :engaged_rate
             ]
    end
  end
end
