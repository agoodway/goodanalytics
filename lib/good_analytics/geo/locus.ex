defmodule GoodAnalytics.Geo.Locus do
  @moduledoc """
  Locus-backed provider for `GoodAnalytics.Geo`.

  Wraps `:locus.lookup/2` against the configured database id (defaults to
  `:good_analytics_geo`). The loader itself is started by
  `GoodAnalytics.Application.start/2` when `:locus` is loaded and
  `config :good_analytics, :geo, provider: ...` is set.

  This module is only meaningful when `:locus` has been compiled into the
  release. Callers should never reach this code with `:locus` absent —
  `GoodAnalytics.Geo.lookup/1` guards on `Code.ensure_loaded?(:locus)` before
  dispatching here.
  """

  @behaviour GoodAnalytics.Geo.Provider

  # Silences "module :locus is not available" when the host app doesn't pull
  # the optional dep. `GoodAnalytics.Geo.lookup/1` guards on `Code.ensure_loaded?`
  # before dispatching here, so this code only runs when locus IS loaded.
  @compile {:no_warn_undefined, :locus}

  @default_db_id :good_analytics_geo

  @doc "The database id the loader is registered under."
  def database_id,
    do: Application.get_env(:good_analytics, :geo, [])[:database_id] || @default_db_id

  @impl true
  def lookup(ip) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(:locus, :lookup, [database_id(), ip]) do
      {:ok, entry} -> {:ok, entry}
      :not_found -> {:error, :not_found}
      {:error, :database_unknown} -> {:error, :loader_not_ready}
      {:error, :database_not_loaded} -> {:error, :loader_not_ready}
      {:error, reason} -> {:error, reason}
    end
  end
end
