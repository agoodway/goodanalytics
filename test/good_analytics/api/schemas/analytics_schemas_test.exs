defmodule GoodAnalytics.Api.Schemas.AnalyticsSchemasTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Api.Schemas.AnalyticsSummaryResponse
  alias GoodAnalytics.Api.Schemas.BreakdownResponse
  alias GoodAnalytics.Api.Schemas.BreakdownRow
  alias GoodAnalytics.Api.Schemas.TimeseriesPoint
  alias GoodAnalytics.Api.Schemas.TimeseriesResponse

  test "BreakdownRow schema declares value + metric properties" do
    schema = BreakdownRow.schema()
    assert schema.type == :object
    assert Map.has_key?(schema.properties, :value)
    assert Map.has_key?(schema.properties, :events)
    assert Map.has_key?(schema.properties, :users)
    assert Map.has_key?(schema.properties, :bounce_rate)
  end

  test "BreakdownResponse wraps a dimension + rows array" do
    schema = BreakdownResponse.schema()
    assert schema.type == :object
    assert schema.properties.dimension.type == :string
    assert schema.properties.rows.type == :array
  end

  test "TimeseriesPoint has bucket bounds and a numeric value" do
    schema = TimeseriesPoint.schema()
    assert schema.properties.bucket_start.format == :"date-time"
    assert schema.properties.bucket_end.format == :"date-time"
    assert schema.properties.value.type == :number
  end

  test "TimeseriesResponse wraps metric + interval + points" do
    schema = TimeseriesResponse.schema()
    assert schema.properties.metric.type == :string
    assert schema.properties.points.type == :array
  end

  test "AnalyticsSummaryResponse declares the KPI fields" do
    schema = AnalyticsSummaryResponse.schema()

    for key <- [
          :visitors,
          :new_visitors,
          :pageviews,
          :revenue,
          :identification_rate,
          :sessions,
          :bounce_rate,
          :avg_duration,
          :engaged_rate
        ] do
      assert Map.has_key?(schema.properties, key), "missing #{key}"
    end
  end
end
