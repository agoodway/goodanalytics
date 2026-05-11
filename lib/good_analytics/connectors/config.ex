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

  @doc "Returns the list of registered connector modules (set at compile time)."
  def registered_connectors, do: @registered_connectors

  @doc """
  Returns the list of registered connector types (atoms).

  Each module must implement `connector_type/0` from the connector behavior.
  """
  def registered_types do
    Enum.map(@registered_connectors, & &1.connector_type())
  end

  @doc """
  Returns the configured dispatch policy callback, or `nil` if none is set.

  The callback should be a `{module, function}` tuple that accepts a
  planning context map and returns `:allow` or `{:reject, reason}`.
  """
  def dispatch_policy, do: @dispatch_policy

  @doc """
  Invokes the global dispatch policy callback for a planning context.

  Returns `:allow` if no policy is configured or the policy approves.
  Returns `{:reject, reason}` if the policy rejects the dispatch.
  """
  def evaluate_policy(planning_context) do
    case @dispatch_policy do
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

  Returns `nil` if not found. Uses a cached lookup map for O(1) access.
  """
  def get_connector(connector_type) when is_atom(connector_type) do
    Map.get(connector_lookup_map(), connector_type)
  end

  def get_connector(connector_type) when is_binary(connector_type) do
    Map.get(connector_string_lookup_map(), connector_type)
  end

  defp connector_lookup_map do
    case :persistent_term.get({__MODULE__, :lookup_map}, nil) do
      nil ->
        map = Map.new(@registered_connectors, fn mod -> {mod.connector_type(), mod} end)
        :persistent_term.put({__MODULE__, :lookup_map}, map)
        map

      map ->
        map
    end
  end

  defp connector_string_lookup_map do
    case :persistent_term.get({__MODULE__, :string_lookup_map}, nil) do
      nil ->
        map =
          Map.new(@registered_connectors, fn mod -> {to_string(mod.connector_type()), mod} end)

        :persistent_term.put({__MODULE__, :string_lookup_map}, map)
        map

      map ->
        map
    end
  end
end
