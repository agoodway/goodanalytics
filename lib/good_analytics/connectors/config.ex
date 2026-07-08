defmodule GoodAnalytics.Connectors.Config do
  @moduledoc """
  Compile-time and runtime configuration for the connector subsystem.

  ## Compile-Time Configuration

  Register connectors and the global dispatch policy callback via
  `Application.compile_env`:

      # config/config.exs
      config :good_analytics, :connectors, [
        GoodAnalytics.Connectors.Adapters.Meta,
        GoodAnalytics.Connectors.Adapters.Google,
        GoodAnalytics.Connectors.Adapters.LinkedIn,
        GoodAnalytics.Connectors.Adapters.TikTok
      ]

      config :good_analytics, :dispatch_policy, {MyApp.ConnectorPolicy, :evaluate}

  ## Runtime Configuration

  The global kill switch can be set in `runtime.exs`:

      config :good_analytics, :connectors_enabled, true

  Setting this to `false` short-circuits all dispatch planning globally.
  """

  @registered_connectors Application.compile_env(:good_analytics, :connectors, [])
  @dispatch_policy Application.compile_env(:good_analytics, :dispatch_policy, nil)

  @doc "Returns the list of registered connector modules."
  def registered_connectors do
    Application.get_env(:good_analytics, :connectors, @registered_connectors)
  end

  @doc """
  Returns the list of registered connector types (atoms).

  Each module must implement `connector_type/0` from the connector behavior.
  """
  def registered_types do
    Enum.map(registered_connectors(), & &1.connector_type())
  end

  @doc """
  Returns the configured dispatch policy callback, or `nil` if none is set.

  The callback should be a `{module, function}` tuple that accepts a
  planning context map and returns `:allow` or `{:reject, reason}`.
  """
  def dispatch_policy do
    Application.get_env(:good_analytics, :dispatch_policy, @dispatch_policy)
  end

  @doc """
  Invokes the global dispatch policy callback for a planning context.

  Returns `:allow` if no policy is configured or the policy approves.
  Returns `{:reject, reason}` if the policy rejects the dispatch.
  """
  def evaluate_policy(planning_context) do
    case dispatch_policy() do
      nil ->
        :allow

      {mod, fun} ->
        apply(mod, fun, [planning_context])
    end
  end

  @doc """
  Returns `true` if the connector subsystem is globally enabled.

  Reads from runtime config, defaults to `true`. Can be set to `false`
  in `runtime.exs` to short-circuit all dispatch planning without redeployment.
  """
  def connectors_enabled? do
    Application.get_env(:good_analytics, :connectors_enabled, true)
  end

  @doc """
  Looks up a registered connector module by its connector type (atom or string).

  Returns `nil` if not found. The lookup map is memoized in `:persistent_term`
  and rebuilt only when the registered-connectors list changes, so the
  per-delivery hot path stays O(1) without rebuilding the map on every call.
  """
  def get_connector(connector_type) do
    Map.get(connector_lookup(), connector_type)
  end

  defp connector_lookup do
    connectors = registered_connectors()

    case :persistent_term.get({__MODULE__, :connector_lookup}, nil) do
      {^connectors, map} ->
        map

      _ ->
        map = build_connector_lookup(connectors)
        :persistent_term.put({__MODULE__, :connector_lookup}, {connectors, map})
        map
    end
  end

  defp build_connector_lookup(connectors) do
    Enum.reduce(connectors, %{}, fn mod, acc ->
      type = mod.connector_type()

      acc
      |> Map.put(type, mod)
      |> Map.put(to_string(type), mod)
    end)
  end
end
