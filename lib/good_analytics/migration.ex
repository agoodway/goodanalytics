defmodule GoodAnalytics.Migration do
  @moduledoc """
  Manages database migrations for GoodAnalytics tables.

  Uses EctoEvolver for versioned, library-owned PostgreSQL migrations.
  All tables live in the `good_analytics` schema with `ga_` prefix.

  ## Usage in Host App

  Generate an Ecto migration in your host application:

      defmodule MyApp.Repo.Migrations.SetupGoodAnalytics do
        use Ecto.Migration

        def up, do: GoodAnalytics.Migration.up()
        def down, do: GoodAnalytics.Migration.down()
      end

  Or use the Mix task:

      mix good_analytics.setup

  """

  use EctoEvolver,
    otp_app: :good_analytics,
    default_prefix: Application.compile_env(:good_analytics, :schema_prefix, "good_analytics"),
    versions: [
      GoodAnalytics.Migrations.V01,
      GoodAnalytics.Migrations.V02,
      GoodAnalytics.Migrations.V03,
      GoodAnalytics.Migrations.V04
    ],
    tracking_object: {:view, "ga_version"}
end
