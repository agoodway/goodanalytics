defmodule GoodAnalytics.Migrations.V12 do
  @moduledoc """
  Add a workspace-leading partial index on ga_events for per-session path
  aggregation.

  The query scans ga_events by `workspace_id` + `inserted_at` range, restricted
  to node-eligible rows (`event_type IN ('pageview','lead','sale')` AND
  `session_id IS NOT NULL`), then aggregates per session. Without this index the
  planner falls back to the global `(event_type, inserted_at)` index and applies
  `workspace_id` as a heap filter — scanning every tenant's events for the
  window. This partial, workspace-leading index serves the scan directly.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "12",
    sql_path: "good_analytics/sql/versions"
end
