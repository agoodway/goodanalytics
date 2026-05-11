defmodule GoodAnalytics.Migrations.V03 do
  @moduledoc """
  Rename `customer_*` columns on `ga_visitors` to `person_*`.

  The original `customer_` prefix prejudged the host's relationship type
  and overlapped semantically with the `customer` value in the `status`
  enum. The neutral `person_` prefix accurately describes these as the
  host-app's projection of who the visitor is, regardless of lifecycle
  stage.

  Columns renamed:
  - `ga_visitors.customer_external_id` → `person_external_id`
  - `ga_visitors.customer_email` → `person_email`
  - `ga_visitors.customer_name` → `person_name`
  - `ga_visitors.customer_metadata` → `person_metadata`

  Indexes renamed:
  - `idx_ga_visitors_customer` → `idx_ga_visitors_person_external_id`
  - `idx_ga_visitors_email` → `idx_ga_visitors_person_email`

  Renames take a brief AccessExclusiveLock per ALTER but no data
  movement (PostgreSQL renames are catalog-only).
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "03",
    sql_path: "good_analytics/sql/versions"
end
