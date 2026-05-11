defmodule GoodAnalytics.Connectors.HTTPTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.HTTP

  test "HTTP module is defined and compiles" do
    assert Code.ensure_loaded?(HTTP)
  end

  test "ReqAdapter module is defined and compiles" do
    assert Code.ensure_loaded?(GoodAnalytics.Connectors.HTTP.ReqAdapter)
  end
end
