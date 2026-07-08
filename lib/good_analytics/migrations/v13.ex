defmodule GoodAnalytics.Migrations.V13 do
  @moduledoc """
  Add workspace-scoped custom event connector mappings.

  Mappings route custom `ga_events.event_name` values to connector-specific
  outbound conversion definitions. The custom-event partial index keeps
  reconciliation lookups bounded by workspace, event name, and event time.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "13",
    sql_path: "good_analytics/sql/versions"
end
