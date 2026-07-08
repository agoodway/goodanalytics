defmodule GoodAnalytics.Api.AnalyticsSpecTest do
  use ExUnit.Case, async: true

  test "spec exposes the analytics paths" do
    spec = GoodAnalytics.ApiSpec.spec()
    paths = Map.keys(spec.paths)

    assert "/analytics/breakdown" in paths
    assert "/analytics/timeseries" in paths
    assert "/analytics/summary" in paths
  end

  test "spec still exposes the previously-missing partners paths" do
    spec = GoodAnalytics.ApiSpec.spec()
    paths = Map.keys(spec.paths)

    assert "/partners" in paths
  end

  test "breakdown operation declares required params and documents 401" do
    spec = GoodAnalytics.ApiSpec.spec()
    op = spec.paths["/analytics/breakdown"].get
    param_names = Enum.map(op.parameters, & &1.name)

    assert :dimension in param_names
    assert :from in param_names
    assert :to in param_names
    assert Map.has_key?(op.responses, 401)
  end

  test "analytics schemas resolve in the spec components" do
    spec = GoodAnalytics.ApiSpec.spec()
    schemas = Map.keys(spec.components.schemas)

    assert "BreakdownResponse" in schemas
    assert "TimeseriesResponse" in schemas
    assert "AnalyticsSummaryResponse" in schemas
  end
end
