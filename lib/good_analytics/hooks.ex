defmodule GoodAnalytics.Hooks do
  @moduledoc """
  Event hooks for downstream consumers.

  Two tiers based on latency requirements:

  - **Sync hooks** (`:link_click` only): Run inline via `Task.Supervisor.async_nolink`
    with a 50ms timeout. Crash or timeout never blocks the caller.
  - **Async hooks** (everything else): Broadcast via `Phoenix.PubSub` after
    the enclosing transaction commits.

  ## Registration

      GoodAnalytics.Hooks.register(:sale, fn event, visitor ->
        # handle sale event
        :ok
      end)

      GoodAnalytics.Hooks.register(:link_click, {MyApp.ClickHandler, :handle})

  """

  use GenServer

  alias GoodAnalytics.PubSub
  alias GoodAnalytics.TaskSupervisor

  @type hook_event ::
          :link_click | :lead | :sale | :identify | :pageview | :visitor_merged | :custom
  @type hook_fn :: (map(), map() -> :ok | {:ok, map()})

  @sync_timeout 50
  @ets_table :ga_hooks

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a callback for the given event type.
  """
  def register(event_type, callback) when is_function(callback, 2) do
    GenServer.call(__MODULE__, {:register, event_type, callback})
  end

  def register(event_type, {module, function}) when is_atom(module) and is_atom(function) do
    GenServer.call(__MODULE__, {:register, event_type, {module, function}})
  end

  @doc """
  Sync dispatch — used only for `:link_click` hooks on the redirect path.

  Each callback runs in a supervised task with a #{@sync_timeout}ms timeout.
  Crashed or timed-out hooks return `:error` and are excluded from results.
  """
  def notify_sync(event_type, event, visitor) do
    callbacks = get_callbacks(event_type)

    Enum.map(callbacks, fn callback ->
      task =
        Task.Supervisor.async_nolink(TaskSupervisor, fn ->
          invoke_callback(callback, event, visitor)
        end)

      case Task.yield(task, @sync_timeout) || Task.shutdown(task) do
        {:ok, result} -> result
        _ -> :error
      end
    end)
    |> Enum.reject(&(&1 == :error))
  end

  @doc """
  Async dispatch — broadcasts via Phoenix.PubSub after transaction commit.

  Used for all non-click hooks.
  """
  def notify_async(event_type, event, visitor) do
    Phoenix.PubSub.broadcast(
      PubSub,
      "good_analytics:hooks:#{event_type}",
      {:good_analytics_hook, event_type, event, visitor}
    )

    # Also invoke registered callbacks via supervised tasks
    callbacks = get_callbacks(event_type)

    for callback <- callbacks do
      Task.Supervisor.start_child(TaskSupervisor, fn ->
        invoke_callback(callback, event, visitor)
      end)
    end

    :ok
  end

  # Read callbacks directly from ETS — no GenServer serialization on the hot path
  defp get_callbacks(event_type) do
    :ets.lookup(@ets_table, event_type) |> Enum.map(&elem(&1, 1))
  rescue
    ArgumentError -> []
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    if :ets.whereis(@ets_table) == :undefined do
      :ets.new(@ets_table, [:bag, :named_table, :public, read_concurrency: true])
    end

    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, event_type, callback}, _from, state) do
    :ets.insert(@ets_table, {event_type, callback})
    {:reply, :ok, state}
  end

  defp invoke_callback(callback, event, visitor) when is_function(callback, 2) do
    callback.(event, visitor)
  end

  defp invoke_callback({module, function}, event, visitor) do
    apply(module, function, [event, visitor])
  end
end
