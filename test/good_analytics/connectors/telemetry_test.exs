defmodule GoodAnalytics.Connectors.TelemetryTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.Telemetry

  test "event_names returns all expected telemetry events" do
    names = Telemetry.event_names()

    assert length(names) == 6

    assert [:good_analytics, :connector, :dispatch, :created] in names
    assert [:good_analytics, :connector, :dispatch, :skipped] in names
    assert [:good_analytics, :connector, :delivery, :attempt] in names
    assert [:good_analytics, :connector, :delivery, :success] in names
    assert [:good_analytics, :connector, :delivery, :failure] in names
    assert [:good_analytics, :connector, :reconciliation, :scan] in names
  end

  test "all event names are lists of atoms" do
    for name <- Telemetry.event_names() do
      assert is_list(name)
      assert Enum.all?(name, &is_atom/1)
    end
  end
end
