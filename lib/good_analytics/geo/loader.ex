defmodule GoodAnalytics.Geo.Loader do
  @moduledoc """
  Starts and supervises the configured locus loader.

  This module is wired into `GoodAnalytics.Application` and is a no-op when
  either `:locus` is not loaded OR no `:provider` is configured under
  `:good_analytics, :geo`. Startup is non-blocking — a failed fetch logs an
  error but does not crash the supervisor.

  Loader status transitions are emitted at info level. To wait for the loader
  to become ready in scripts or release tasks, use `await/1`.
  """

  alias GoodAnalytics.Geo.Locus

  require Logger

  @compile {:no_warn_undefined, :locus}

  @doc """
  Starts the configured loader, if any. Always returns `:ignore` so the
  supervisor treats it as a no-op child after startup; the loader itself runs
  inside the locus application supervisor.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      # `start_link/0` always returns `:ignore` after kicking off the locus
      # loader, so the supervisor never owns a PID and there is nothing to
      # restart. `:temporary` documents this honestly.
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Called by the supervisor at boot. Always returns `:ignore` — the locus
  loader runs inside the locus application's own supervision tree. Errors are
  logged but **not** propagated to our supervisor; they will not be observable
  via supervisor status. Use `await/1` from a release task to surface them.
  """
  def start_link do
    do_start()
    :ignore
  end

  defp do_start do
    cond do
      not Code.ensure_loaded?(:locus) ->
        :skip

      Application.get_env(:good_analytics, :geo, [])[:provider] == nil ->
        :skip

      true ->
        loader = Application.get_env(:good_analytics, :geo, [])[:loader]
        database_id = Locus.database_id()
        start_loader(database_id, loader)
    end
  end

  defp start_loader(_database_id, nil) do
    Logger.warning(
      "GoodAnalytics.Geo: provider configured but no :loader given. " <>
        "Set config :good_analytics, :geo, loader: {:maxmind, \"GeoLite2-City\"} or equivalent."
    )

    :skip
  end

  defp start_loader(database_id, source) do
    Logger.info("GoodAnalytics.Geo loader starting: #{inspect(database_id)} ← #{inspect(source)}")

    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    case apply(:locus, :start_loader, [database_id, source]) do
      :ok ->
        Logger.info("GoodAnalytics.Geo loader registered (download will run asynchronously)")
        :ok

      {:ok, _pid} ->
        Logger.info("GoodAnalytics.Geo loader registered (download will run asynchronously)")
        :ok

      {:error, {:already_started, _}} ->
        :ok

      {:error, reason} ->
        Logger.error("GoodAnalytics.Geo loader failed to start: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Blocks until the loader has fetched and parsed the MMDB. Useful in release
  tasks or scripts. Returns `:ok` or `{:error, reason}`.
  """
  @spec await(timeout()) :: :ok | {:error, term()}
  def await(timeout \\ 30_000) do
    cond do
      not Code.ensure_loaded?(:locus) ->
        {:error, :geo_disabled}

      Application.get_env(:good_analytics, :geo, [])[:provider] == nil ->
        {:error, :geo_disabled}

      true ->
        # credo:disable-for-next-line Credo.Check.Refactor.Apply
        case apply(:locus, :await_loader, [Locus.database_id(), timeout]) do
          {:ok, _version_or_metadata} ->
            Logger.info("GoodAnalytics.Geo loader ready")
            :ok

          {:error, reason} ->
            Logger.error("GoodAnalytics.Geo loader not ready: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end
end
