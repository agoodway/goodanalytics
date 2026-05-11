defmodule GoodAnalytics.SettingsTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Settings

  describe "wrap/unwrap value" do
    # DB-dependent tests are in integration tests.
    # Unit tests verify module compiles and public API shape is correct.
    test "module exports expected functions" do
      Code.ensure_loaded!(Settings)
      assert function_exported?(Settings, :get, 2)
      assert function_exported?(Settings, :get, 3)
      assert function_exported?(Settings, :put, 3)
      assert function_exported?(Settings, :delete, 2)
    end
  end
end
