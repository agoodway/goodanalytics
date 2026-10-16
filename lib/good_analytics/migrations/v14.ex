defmodule GoodAnalytics.Migrations.V14 do
  @moduledoc """
  Recover anonymous IDs, fingerprints, and click IDs from existing merge chains.

  Follows only same-workspace edges ending at a non-merged survivor. Cycles,
  dangling targets, and cross-workspace edges are left untouched. Host-owned
  references and historical attribution/profile values are not rewritten.
  The repair locks visitor writes for its transaction and is idempotent.
  Rolling down keeps the recovered memberships.
  """

  use EctoEvolver.Version,
    otp_app: :good_analytics,
    version: "14",
    sql_path: "good_analytics/sql/versions"
end
