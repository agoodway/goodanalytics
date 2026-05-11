defmodule GoodAnalytics.SchemaPrefixTest do
  @moduledoc """
  Regression coverage for the configurable `:schema_prefix` config knob.

  The prefix is read at compile time (`Application.compile_env/3`), so this
  test cannot toggle it dynamically — instead it asserts that every place
  that should agree on the prefix actually does, and that the compiled
  Ecto metadata matches the configured value.

  Running the full migration / partition manager / query suite against an
  alternate prefix is a CI concern: set
  `config :good_analytics, :schema_prefix, "alt_schema"` in a separate
  build, recompile, and run the suite — every place wired through
  `Application.compile_env/3` flows from the new value.
  """

  use ExUnit.Case, async: true

  alias GoodAnalytics.Auth.ApiKey
  alias GoodAnalytics.Connectors.Dispatch
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Links.Link
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Domains.Domain
  alias GoodAnalytics.PartitionManager
  alias GoodAnalytics.Settings.Setting

  @configured_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  describe "GoodAnalytics.schema_name/0" do
    test "returns the configured schema prefix" do
      assert GoodAnalytics.schema_name() == @configured_prefix
    end
  end

  describe "Ecto schemas" do
    test "Event uses the configured prefix" do
      assert Event.__schema__(:prefix) == @configured_prefix
    end

    test "Visitor uses the configured prefix" do
      assert Visitor.__schema__(:prefix) == @configured_prefix
    end

    test "Link uses the configured prefix" do
      assert Link.__schema__(:prefix) == @configured_prefix
    end

    test "Dispatch uses the configured prefix" do
      assert Dispatch.__schema__(:prefix) == @configured_prefix
    end

    test "Setting uses the configured prefix" do
      assert Setting.__schema__(:prefix) == @configured_prefix
    end

    test "Domain uses the configured prefix" do
      assert Domain.__schema__(:prefix) == @configured_prefix
    end

    test "ApiKey uses the configured prefix" do
      assert ApiKey.__schema__(:prefix) == @configured_prefix
    end
  end

  describe "Event composite primary key" do
    test "declares (id, inserted_at) as the composite primary key" do
      assert Event.__schema__(:primary_key) == [:id, :inserted_at]
    end
  end

  describe "PartitionManager.advisory_lock_key/0" do
    test "is a stable, non-negative integer" do
      key = PartitionManager.advisory_lock_key()
      assert is_integer(key)
      assert key >= 0
      assert PartitionManager.advisory_lock_key() == key
    end

    test "differs from the legacy hardcoded key (916_273_851)" do
      # Anything namespaced by phash2 is overwhelmingly unlikely to collide
      # with the prior literal — guard against accidental reverts.
      refute PartitionManager.advisory_lock_key() == 916_273_851
    end
  end
end
