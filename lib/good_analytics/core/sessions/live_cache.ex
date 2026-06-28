defmodule GoodAnalytics.Core.Sessions.LiveCache do
  @moduledoc """
  Optional in-memory fast path for live-session lookup.

  Stores the latest known live session per `{workspace_id, visitor_id}` in a
  public ETS table. The DB remains authoritative; this cache is only a read
  optimization for callers that can safely confirm cached sessions.
  """

  use GenServer

  @table :ga_sessions_live_cache

  @doc false
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @doc false
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    create_table()
    {:ok, %{}}
  end

  @doc "Creates the ETS table if it does not exist. Idempotent."
  @spec ensure_table() :: :ok
  def ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        case Process.whereis(__MODULE__) do
          nil -> create_table()
          _pid -> GenServer.call(__MODULE__, :ensure_table)
        end

      _tid ->
        :ok
    end
  end

  @doc "Returns `{:ok, entry}` or `:miss`."
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, map()} | :miss
  def get(workspace_id, visitor_id) do
    ensure_table()

    case :ets.lookup(@table, {workspace_id, visitor_id}) do
      [{_key, entry}] -> {:ok, entry}
      [] -> :miss
    end
  end

  @doc "Write-through put."
  @spec put(Ecto.UUID.t(), Ecto.UUID.t(), map()) :: :ok
  def put(workspace_id, visitor_id, entry) when is_map(entry) do
    ensure_table()
    :ets.insert(@table, {{workspace_id, visitor_id}, entry})
    :ok
  end

  @doc "Invalidate one key."
  @spec delete(Ecto.UUID.t(), Ecto.UUID.t()) :: :ok
  def delete(workspace_id, visitor_id) do
    ensure_table()
    :ets.delete(@table, {workspace_id, visitor_id})
    :ok
  end

  @doc "Clears every entry."
  @spec clear() :: :ok
  def clear do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    {:reply, create_table(), state}
  end

  defp create_table do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

        :ok

      _tid ->
        :ok
    end
  end
end
