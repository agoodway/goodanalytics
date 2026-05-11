defmodule GoodAnalytics.TestMigration do
  @moduledoc false
  use Ecto.Migration

  def up, do: GoodAnalytics.Migration.up()
  def down, do: GoodAnalytics.Migration.down()
end
