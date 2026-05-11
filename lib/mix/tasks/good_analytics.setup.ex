defmodule Mix.Tasks.GoodAnalytics.Setup do
  @moduledoc """
  Generates an Ecto migration that sets up GoodAnalytics tables.

  ## Usage

      mix good_analytics.setup

  This creates a migration file in your host application that calls
  `GoodAnalytics.Migration.up/0` and `GoodAnalytics.Migration.down/0`.

  Then run `mix ecto.migrate` as usual.
  """

  use Mix.Task

  alias GoodAnalytics.MixTaskHelpers

  @shortdoc "Generates an Ecto migration for GoodAnalytics"

  @impl Mix.Task
  def run(_args) do
    repo = MixTaskHelpers.get_repo()
    MixTaskHelpers.ensure_migrations_dir(repo)

    case existing_setup_migrations(repo) do
      [] ->
        generate_migration(repo)

      [existing] ->
        Mix.shell().info("GoodAnalytics setup migration already exists: #{existing}")

        Mix.shell().info(
          "Skipping. Use `mix good_analytics.gen.migration` to generate update migrations for new library versions."
        )

      [_ | _] = duplicates ->
        Mix.raise("""
        Multiple GoodAnalytics setup migrations found:

        #{Enum.map_join(duplicates, "\n", &"  * #{&1}")}

        Delete all but one and re-run `mix ecto.migrate`.
        """)
    end
  end

  defp generate_migration(repo) do
    timestamp = MixTaskHelpers.timestamp()
    filename = "#{timestamp}_setup_good_analytics.exs"
    migrations_path = Path.join(MixTaskHelpers.migrations_dir(repo), filename)

    content = migration_content(repo)

    File.write!(migrations_path, content)
    Mix.shell().info("Created migration: #{migrations_path}")
    Mix.shell().info("Run `mix ecto.migrate` to apply.")
  end

  defp existing_setup_migrations(repo) do
    MixTaskHelpers.migrations_dir(repo)
    |> Path.join("*_setup_good_analytics.exs")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp migration_content(repo) do
    """
    defmodule #{inspect(repo)}.Migrations.SetupGoodAnalytics do
      use Ecto.Migration

      def up do
        GoodAnalytics.Migration.up()
        GoodAnalytics.PartitionManager.ensure_initial_partitions()
      end

      def down, do: GoodAnalytics.Migration.down()
    end
    """
  end
end
