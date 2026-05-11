defmodule GoodAnalyticsTest do
  use ExUnit.Case

  describe "default_workspace_id/0" do
    test "returns the sentinel UUID" do
      assert GoodAnalytics.default_workspace_id() == "00000000-0000-0000-0000-000000000000"
    end

    test "returns a valid UUID format" do
      id = GoodAnalytics.default_workspace_id()
      assert {:ok, _} = Ecto.UUID.cast(id)
    end
  end
end
