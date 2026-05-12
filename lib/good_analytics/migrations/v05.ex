defmodule GoodAnalytics.Migrations.V05 do
  @moduledoc """
  Add ga_funnels table for workspace-scoped funnel definitions.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "05",
    sql_path: "good_analytics/sql/versions"
end
