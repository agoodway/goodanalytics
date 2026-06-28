defmodule GoodAnalytics.Migrations.V10 do
  @moduledoc """
  Add the ga_sessions table and ga_events.session_id.

  Sessions are server-derived per-visitor visits (30-min sliding inactivity +
  acquisition-change boundary). ga_sessions is a mutable, NON-partitioned
  OLTP row UPDATEd in place on every event, unlike append-only ga_events.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "10",
    sql_path: "good_analytics/sql/versions"
end
