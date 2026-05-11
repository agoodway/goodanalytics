defmodule GoodAnalytics.Connectors.Telemetry do
  @moduledoc """
  Telemetry event definitions for the connector subsystem.

  All connector telemetry events are namespaced under `[:good_analytics, :connector, ...]`.

  ## Events

  | Event | Measurements | Metadata |
  |-------|-------------|----------|
  | `[:good_analytics, :connector, :dispatch, :created]` | `%{count: 1}` | connector_type, workspace_id, event_id |
  | `[:good_analytics, :connector, :dispatch, :skipped]` | `%{count: 1}` | connector_type, workspace_id, reason |
  | `[:good_analytics, :connector, :delivery, :attempt]` | `%{count: 1}` | connector_type, workspace_id, attempt |
  | `[:good_analytics, :connector, :delivery, :success]` | `%{duration: native}` | connector_type, workspace_id |
  | `[:good_analytics, :connector, :delivery, :failure]` | `%{count: 1}` | connector_type, workspace_id, error_class, attempt |
  | `[:good_analytics, :connector, :reconciliation, :scan]` | `%{events_scanned: n, dispatches_created: n}` | workspace_id |
  """

  @doc "Returns all telemetry event names for documentation and testing."
  def event_names do
    [
      [:good_analytics, :connector, :dispatch, :created],
      [:good_analytics, :connector, :dispatch, :skipped],
      [:good_analytics, :connector, :delivery, :attempt],
      [:good_analytics, :connector, :delivery, :success],
      [:good_analytics, :connector, :delivery, :failure],
      [:good_analytics, :connector, :reconciliation, :scan]
    ]
  end
end
