defmodule GoodAnalytics.Core.Sessions.LiveCacheTest do
  use ExUnit.Case, async: false

  alias GoodAnalytics.Core.Sessions.LiveCache

  setup do
    LiveCache.ensure_table()
    LiveCache.clear()
    :ok
  end

  @ws "00000000-0000-0000-0000-000000000000"

  test "put then get returns the cached entry" do
    vid = Uniq.UUID.uuid7()
    entry = %{session_id: Uniq.UUID.uuid7(), last_event_at: DateTime.utc_now()}

    assert LiveCache.get(@ws, vid) == :miss
    LiveCache.put(@ws, vid, entry)
    assert {:ok, ^entry} = LiveCache.get(@ws, vid)
  end

  test "delete removes the entry" do
    vid = Uniq.UUID.uuid7()
    LiveCache.put(@ws, vid, %{session_id: Uniq.UUID.uuid7(), last_event_at: DateTime.utc_now()})
    LiveCache.delete(@ws, vid)
    assert LiveCache.get(@ws, vid) == :miss
  end
end
