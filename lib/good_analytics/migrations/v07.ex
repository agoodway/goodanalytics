defmodule GoodAnalytics.Migrations.V07 do
  @moduledoc """
  Add host and path columns with indexes to ga_events.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "07",
    sql_path: "good_analytics/sql/versions"
end
