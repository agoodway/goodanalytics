defmodule GoodAnalytics.Migrations.V15 do
  @moduledoc """
  Repair the string `'nil'` in event and session source columns.

  Older recorders stored the literal text `'nil'` in `source_platform`,
  `source_medium` and `source_campaign` when a request had no source. This
  sets those exact values to NULL on `ga_events` and `ga_sessions`. Real
  sources are untouched and the repair is idempotent. Rolling down is a no-op.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "15",
    sql_path: "good_analytics/sql/versions"
end
