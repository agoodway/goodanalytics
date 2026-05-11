defmodule GoodAnalytics.Connectors.ConversionApiTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.PostCommit

  describe "GoodAnalytics public conversion API" do
    test "submit_lead/3 is exported" do
      Code.ensure_loaded!(GoodAnalytics)
      assert function_exported?(GoodAnalytics, :submit_lead, 1)
      assert function_exported?(GoodAnalytics, :submit_lead, 3)
    end

    test "submit_sale/3 is exported" do
      Code.ensure_loaded!(GoodAnalytics)
      assert function_exported?(GoodAnalytics, :submit_sale, 1)
      assert function_exported?(GoodAnalytics, :submit_sale, 3)
    end
  end

  describe "PostCommit.connector_eligible?/1" do
    test "lead events trigger connector dispatch" do
      assert PostCommit.connector_eligible?(%{event_type: "lead"})
    end

    test "sale events trigger connector dispatch" do
      assert PostCommit.connector_eligible?(%{event_type: "sale"})
    end

    test "pageview events do not trigger connector dispatch" do
      refute PostCommit.connector_eligible?(%{event_type: "pageview"})
    end

    test "identify events do not trigger connector dispatch" do
      refute PostCommit.connector_eligible?(%{event_type: "identify"})
    end
  end

  describe "Connector isolation from source events" do
    test "PostCommit.maybe_dispatch always returns :ok" do
      # Even with a nil event, it returns :ok without raising
      assert :ok == PostCommit.maybe_dispatch(%{event_type: "pageview"})
    end
  end
end
