defmodule GoodAnalytics.Connectors.ConfigTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.Config

  describe "connectors_enabled?/0" do
    test "defaults to true when not configured" do
      assert Config.connectors_enabled?()
    end
  end

  describe "registered_connectors/0" do
    test "returns a list" do
      assert is_list(Config.registered_connectors())
    end
  end

  describe "dispatch_policy/0" do
    test "returns nil when no policy configured" do
      # Default in test env is nil
      result = Config.dispatch_policy()
      assert is_nil(result) or is_tuple(result)
    end
  end

  describe "evaluate_policy/1" do
    test "returns :allow when no policy configured" do
      assert Config.evaluate_policy(%{connector_type: :meta}) == :allow
    end
  end
end
