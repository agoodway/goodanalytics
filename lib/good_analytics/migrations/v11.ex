defmodule GoodAnalytics.Migrations.V11 do
  @moduledoc """
  Add per-dimension composite indexes to ga_sessions for session-grain audience
  breakdowns (device_type, browser, os, source_platform, source_medium,
  source_campaign), mirroring the ga_events dimension indexes from v04/v09.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "11",
    sql_path: "good_analytics/sql/versions"
end
