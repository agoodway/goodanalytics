defmodule GoodAnalytics.SettingsDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Settings

  @workspace_id GoodAnalytics.default_workspace_id()

  describe "put/3 and get/3" do
    test "stores and retrieves a string value" do
      assert {:ok, _} = Settings.put(@workspace_id, "test_key", "hello")
      assert Settings.get(@workspace_id, "test_key") == "hello"
    end

    test "stores and retrieves a map value" do
      value = %{"nested" => "map", "count" => 42}
      assert {:ok, _} = Settings.put(@workspace_id, "map_key", value)
      assert Settings.get(@workspace_id, "map_key") == value
    end

    test "stores and retrieves an integer value" do
      assert {:ok, _} = Settings.put(@workspace_id, "int_key", 99)
      assert Settings.get(@workspace_id, "int_key") == 99
    end

    test "returns default when key not found" do
      assert Settings.get(@workspace_id, "missing_key", "default_val") == "default_val"
    end

    test "returns nil when key not found and no default" do
      assert Settings.get(@workspace_id, "missing_key_2") == nil
    end

    test "upsert overwrites existing key" do
      Settings.put(@workspace_id, "upsert_key", "first")
      Settings.put(@workspace_id, "upsert_key", "second")
      assert Settings.get(@workspace_id, "upsert_key") == "second"
    end
  end

  describe "delete/2" do
    test "removes setting" do
      Settings.put(@workspace_id, "del_key", "value")
      assert {:ok, _} = Settings.delete(@workspace_id, "del_key")
      assert Settings.get(@workspace_id, "del_key") == nil
    end

    test "returns {:ok, 0} for nonexistent key" do
      assert {:ok, 0} = Settings.delete(@workspace_id, "nonexistent_key")
    end
  end
end
