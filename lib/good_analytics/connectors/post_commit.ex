defmodule GoodAnalytics.Connectors.PostCommit do
  @moduledoc """
  Post-commit connector dispatch creation.

  After a connector-eligible event commits, this module triggers the
  planner to create dispatch records for all eligible connectors.
  Dispatch creation failures do not roll back the source event.
  """

  alias GoodAnalytics.Connectors.Planner
  alias GoodAnalytics.Flows.{ConnectorDelivery, ConnectorPlanning}
  alias GoodAnalytics.Repo
  alias GoodAnalytics.TaskSupervisor

  require Logger

  @connector_eligible_types ~w(lead sale)

  @doc """
  Triggers connector dispatch planning for a committed event.

  Called by the event recorder after successful insert. Returns `:ok`
  regardless of whether dispatches were created — connector failures
  must never affect the source event.

  ## Parameters

  - `event` — the committed event struct
  - `attrs` — the original event attributes (may contain `:connector_signals`)
  """
  def maybe_dispatch(event, attrs \\ %{}) do
    if connector_eligible?(event) do
      connector_signals = Map.get(attrs, :connector_signals, %{})
      source_context = event.connector_source_context || %{}
      schedule_dispatch(event, connector_signals, source_context)
    end

    :ok
  end

  @doc "Returns `true` if the event type is eligible for connector dispatch."
  def connector_eligible?(%{event_type: event_type}) do
    to_string(event_type) in @connector_eligible_types
  end

  def connector_eligible?(_), do: false

  defp schedule_dispatch(event, signals, source_context) do
    repo = Repo.repo()
    in_transaction? = repo_in_transaction?(repo)
    runner = flow_runner()

    cond do
      runner.available?() ->
        case runner.start_flow(ConnectorPlanning, planning_input(event, signals, source_context)) do
          {:ok, _run_id} ->
            :ok

          {:error, reason} when in_transaction? ->
            Logger.warning(
              "GoodAnalytics: durable connector planning failed inside an open transaction; skipping dispatch scheduling: #{inspect(reason)}"
            )

          {:error, reason} ->
            Logger.warning(
              "GoodAnalytics: durable connector planning unavailable, falling back to local task: #{inspect(reason)}"
            )

            start_local_task(event, signals, source_context)
        end

      in_transaction? ->
        Logger.warning(
          "GoodAnalytics: skipping connector dispatch scheduling inside an open transaction because no durable post-commit runner is available"
        )

      true ->
        start_local_task(event, signals, source_context)
    end
  end

  defp start_local_task(event, signals, source_context) do
    case Task.Supervisor.start_child(
           TaskSupervisor,
           fn -> dispatch_safely(event, signals, source_context) end
         ) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "GoodAnalytics: TaskSupervisor unavailable for connector dispatch: #{inspect(reason)}"
        )
    end
  end

  defp dispatch_safely(event, signals, source_context) do
    case Planner.plan(event, signals, source_context) do
      {:ok, dispatches} ->
        Enum.each(dispatches, fn dispatch ->
          PgFlow.start_flow(ConnectorDelivery, %{"dispatch_id" => dispatch.id})
        end)

        if match?([_ | _], dispatches) do
          Logger.debug(
            "GoodAnalytics: created #{length(dispatches)} connector dispatches for event #{event.id}"
          )
        end

      {:skip, reason} ->
        Logger.debug("GoodAnalytics: skipped connector dispatch planning: #{inspect(reason)}")

      {:error, reason} ->
        Logger.warning(
          "GoodAnalytics: connector dispatch creation failed for event #{event.id}: #{inspect(reason)}"
        )
    end
  rescue
    error ->
      Logger.error(
        "GoodAnalytics: connector post-commit error for event #{event.id}: #{Exception.message(error)}"
      )
  end

  defp planning_input(event, signals, source_context) do
    %{
      "event_id" => event.id,
      "workspace_id" => event.workspace_id,
      "visitor_id" => event.visitor_id,
      "event_type" => to_string(event.event_type),
      "inserted_at" => DateTime.to_iso8601(event.inserted_at),
      "connector_signals" => signals,
      "source_context" => source_context
    }
  end

  defp repo_in_transaction?(repo) do
    function_exported?(repo, :in_transaction?, 0) and repo.in_transaction?()
  end

  defp flow_runner do
    Application.get_env(
      :good_analytics,
      :connector_post_commit_flow_runner,
      GoodAnalytics.Connectors.PostCommit.FlowRunner
    )
  end
end

defmodule GoodAnalytics.Connectors.PostCommit.FlowRunner do
  @moduledoc """
  Default flow runner for post-commit connector dispatch.

  Delegates to `PgFlow` when its supervisor is running, providing durable
  out-of-transaction dispatch scheduling. Used as the configurable default
  for `GoodAnalytics.Connectors.PostCommit`.
  """

  @doc "Returns `true` when the `PgFlow.Supervisor` process is running."
  @spec available?() :: boolean()
  def available? do
    Process.whereis(PgFlow.Supervisor) != nil
  end

  @doc "Starts a PgFlow flow for the given module and input map."
  @spec start_flow(module(), map()) :: {:ok, term()} | {:error, term()}
  def start_flow(flow_module, input) do
    PgFlow.start_flow(flow_module, input)
  end
end
