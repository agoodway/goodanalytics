defmodule GoodAnalytics.Hooks do
  @moduledoc """
  Event hooks for downstream consumers.

  Dispatch tiers based on latency requirements:

  - **Sync tier** (`notify_sync/3`, the redirect path's `:link_click`): each
    callback runs via `Task.Supervisor.async_nolink` with a 50ms timeout.
    Crash or timeout never blocks the caller. Use it for fast hooks whose
    *result* the caller needs in-band (e.g. cookie directives).
  - **Async opt-in tier** (`notify_detached/3`): callbacks registered with
    `async: true` are skipped by the sync tier and dispatched here
    fire-and-forget, with no time budget. Use it for slow, side-effecting
    hooks (e.g. a DB-bound subscriber identify) that must not run under the
    50ms redirect budget.
  - **Broadcast tier** (`notify_async/3`, every non-click event): broadcast via
    `Phoenix.PubSub` after the enclosing transaction commits.

  The link redirect pairs the first two: `notify_sync/3` for the bounded,
  cookie-setting hooks and `notify_detached/3` for the async-tier side effects.

  ## Registration

      GoodAnalytics.Hooks.register(:sale, fn event, visitor ->
        # handle sale event
        :ok
      end)

      GoodAnalytics.Hooks.register(:link_click, {MyApp.ClickHandler, :handle})

      # Slow side-effect hook — runs off the 50ms redirect budget.
      GoodAnalytics.Hooks.register(:link_click, {MyApp.Identify, :call}, async: true)

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

  Options:
    * `:async` (boolean, default `false`) — when `true`, the callback joins the
      *async tier*: it is skipped by `notify_sync/3` and instead dispatched
      fire-and-forget by `notify_detached/3`, with no time budget. Use it for
      slow, side-effecting hooks (e.g. a DB-bound subscriber identify) that must
      not run under the 50ms sync redirect budget. `false` keeps the legacy
      *sync tier* behaviour (bounded, reply-carrying, cookie-capable).
  """
  def register(event_type, callback, opts \\ [])

  def register(event_type, callback, opts) when is_function(callback, 2) do
    GenServer.call(__MODULE__, {:register, event_type, callback, async?(opts)})
  end

  def register(event_type, {module, function} = callback, opts)
      when is_atom(module) and is_atom(function) do
    GenServer.call(__MODULE__, {:register, event_type, callback, async?(opts)})
  end

  defp async?(opts), do: Keyword.get(opts, :async, false) == true

  @doc """
  Sync dispatch — used only for `:link_click` hooks on the redirect path.

  Each callback runs in a supervised task with a #{@sync_timeout}ms timeout.
  Crashed or timed-out hooks return `:error` and are excluded from results.
  """
  def notify_sync(event_type, event, visitor) do
    event_type
    |> get_callbacks()
    |> Enum.filter(fn {_callback, async?} -> not async? end)
    |> Enum.map(fn {callback, _async?} ->
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
  Detached dispatch — runs only the *async-tier* callbacks (registered with
  `async: true`) for `event_type`, each in a supervised task with no time
  budget and no reply. Sync-tier callbacks are ignored, and nothing is
  broadcast over PubSub.

  Pair this with `notify_sync/3` on latency-sensitive paths (the link redirect):
  `notify_sync/3` awaits the bounded, cookie-setting hooks, while this lets slow
  side-effect hooks run to completion off the request's critical path.
  """
  def notify_detached(event_type, event, visitor) do
    event_type
    |> get_callbacks()
    |> Enum.filter(fn {_callback, async?} -> async? end)
    |> Enum.each(fn {callback, _async?} -> dispatch_supervised(callback, event, visitor) end)
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
    event_type
    |> get_callbacks()
    |> Enum.each(fn {callback, _async?} -> dispatch_supervised(callback, event, visitor) end)

    :ok
  end

  # Read callbacks directly from ETS — no GenServer serialization on the hot path.
  # Each entry is `{event_type, callback, async?}`; we return `{callback, async?}`.
  defp get_callbacks(event_type) do
    :ets.lookup(@ets_table, event_type) |> Enum.map(fn {_type, cb, async?} -> {cb, async?} end)
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
  def handle_call({:register, event_type, callback, async?}, _from, state) do
    :ets.insert(@ets_table, {event_type, callback, async?})
    {:reply, :ok, state}
  end

  # Fire-and-forget: invoke the callback in a supervised task off the caller.
  defp dispatch_supervised(callback, event, visitor) do
    Task.Supervisor.start_child(TaskSupervisor, fn ->
      invoke_callback(callback, event, visitor)
    end)
  end

  defp invoke_callback(callback, event, visitor) when is_function(callback, 2) do
    callback.(event, visitor)
  end

  defp invoke_callback({module, function}, event, visitor) do
    apply(module, function, [event, visitor])
  end
end
