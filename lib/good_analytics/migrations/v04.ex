defmodule GoodAnalytics.Migrations.V04 do
  @moduledoc """
  Add composite indexes for workspace-scoped link/event and visitor first-click lookups.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "04",
    sql_path: "good_analytics/sql/versions"
end
