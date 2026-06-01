defmodule GoodAnalytics.SQLTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.SQL

  describe "escape_like/1" do
    test "escapes the % wildcard" do
      assert SQL.escape_like("50%off") == "50\\%off"
    end

    test "escapes the _ wildcard" do
      assert SQL.escape_like("a_b") == "a\\_b"
    end

    test "escapes a literal backslash" do
      assert SQL.escape_like("a\\b") == "a\\\\b"
    end

    test "escapes every metacharacter in one pass (order-independent)" do
      assert SQL.escape_like("100\\%_") == "100\\\\\\%\\_"
    end

    test "leaves text without metacharacters untouched" do
      assert SQL.escape_like("organic") == "organic"
      assert SQL.escape_like("") == ""
    end
  end
end
