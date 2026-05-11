defmodule Mix.Tasks.GoodAnalytics.Gen.Migration do
  @moduledoc """
  Generates an Ecto migration to apply pending GoodAnalytics schema changes.

  ## Usage

      mix good_analytics.gen.migration

  This creates a migration file in your host application that calls
  `GoodAnalytics.Migration.up/0` and `GoodAnalytics.Migration.down/0`.
  EctoEvolver tracks which versions have already been applied, so only
  new versions will run.

  Then run `mix ecto.migrate` as usual.
  """

  use Mix.Task

  alias GoodAnalytics.MixTaskHelpers

  @shortdoc "Generates an Ecto migration for pending GoodAnalytics schema changes"

  @impl Mix.Task
  def run(_args) do
    repo = MixTaskHelpers.get_repo()
    MixTaskHelpers.ensure_migrations_dir(repo)

    timestamp = MixTaskHelpers.timestamp()
    filename = "#{timestamp}_update_good_analytics.exs"
    migrations_path = Path.join(MixTaskHelpers.migrations_dir(repo), filename)

    content = migration_content(repo)

    File.write!(migrations_path, content)
    Mix.shell().info("Created migration: #{migrations_path}")
    Mix.shell().info("Run `mix ecto.migrate` to apply.")
  end

  defp migration_content(repo) do
    """
    defmodule #{inspect(repo)}.Migrations.UpdateGoodAnalytics do
      use Ecto.Migration

      def up, do: GoodAnalytics.Migration.up()
      def down, do: GoodAnalytics.Migration.down()
    end
    """
  end
end
