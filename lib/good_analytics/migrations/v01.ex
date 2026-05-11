defmodule GoodAnalytics.Migrations.V01 do
  @moduledoc """
  Initial GoodAnalytics schema — creates all core tables.

  Tables created:
  - `ga_visitors` — visitor identity graph
  - `ga_links` — short links, referral links, campaign links
  - `ga_events` — unified event stream (partitioned by month)
  - `ga_domains` — custom short link domains
  - `ga_api_keys` — two-tier API key auth
  - `ga_settings` — per-workspace runtime settings
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "01",
    sql_path: "good_analytics/sql/versions"
end
