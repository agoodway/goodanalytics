defmodule GoodAnalytics.Migrations.V08 do
  @moduledoc """
  Add Core referral partner schema and partner attribution columns.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "08",
    sql_path: "good_analytics/sql/versions"
end
