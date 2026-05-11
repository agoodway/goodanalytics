ExUnit.start()

# Start the test repo and run migrations
{:ok, _} = GoodAnalytics.TestRepo.start_link()

Ecto.Migrator.up(
  GoodAnalytics.TestRepo,
  0,
  GoodAnalytics.TestMigration,
  log: false
)

Ecto.Adapters.SQL.Sandbox.mode(GoodAnalytics.TestRepo, :manual)
