import Config

config :good_analytics, GoodAnalytics.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "good_analytics_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Point the library at the test repo
config :good_analytics, repo: GoodAnalytics.TestRepo

config :good_analytics, api_key_secret: "test-only-secret-not-for-prod!!!"

# Tests opt out of background partition creation. The shared sandbox
# would otherwise let the GenServer see in-flight inserts and emit
# `check_violation` warnings during ConnCase tests. Suites that need
# the partition path call `PartitionManager.create_partitions_direct/0`
# explicitly.
config :good_analytics, auto_create_partitions: false

config :logger, level: :warning
