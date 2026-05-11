defmodule GoodAnalytics.Connectors.ReplayTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.{EventId, Replay}

  test "Replay module is defined and compiles" do
    assert Code.ensure_loaded?(Replay)
  end

  test "replay ids are fresh and namespaced by connector" do
    id1 = EventId.replay(:meta)
    id2 = EventId.replay("meta")

    assert id1 != id2
    assert String.starts_with?(id1, "meta_replay_")
    assert String.starts_with?(id2, "meta_replay_")
  end
end
