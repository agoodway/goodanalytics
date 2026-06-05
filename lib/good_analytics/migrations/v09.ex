defmodule GoodAnalytics.Migrations.V09 do
  @moduledoc """
  Add event-grain device columns and breakdown indexes to ga_events.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "09",
    sql_path: "good_analytics/sql/versions"
end
