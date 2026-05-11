defmodule GoodAnalytics.Migrations.V02 do
  @moduledoc """
  Connector dispatch persistence and signal columns.

  Tables created:
  - `ga_connector_dispatches` — durable outbound connector delivery records

  Columns added:
  - `ga_visitors.connector_identifiers` — browser connector identifiers (JSONB)
  - `ga_events.connector_source_context` — event-time connector payload rebuild context (JSONB)
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "02",
    sql_path: "good_analytics/sql/versions"
end
