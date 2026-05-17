defmodule GoodAnalytics.Migrations.V06 do
  @moduledoc """
  Add api_request to the chk_event_type constraint.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "06",
    sql_path: "good_analytics/sql/versions"
end
