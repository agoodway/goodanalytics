defmodule GoodAnalytics.Connectors.Replay do
  @moduledoc """
  Replays failed connector dispatches from stored source context.

  Replay rebuilds the outbound payload from the stored `source_context`
  rather than relying on live visitor state, ensuring deterministic results.
  """

  alias GoodAnalytics.Connectors.{Delivery, Dispatches, EventId}

  # Maximum failed dispatches replayed in one bulk operation.
  @replay_batch_limit 1_000

  @doc """
  Replays a failed dispatch by creating a new dispatch from stored source context.

  The new dispatch is linked to the original via `replayed_from_id`.
  Returns `{:ok, new_dispatch}` or `{:error, reason}`.
  """
  def replay(dispatch_id) do
    case Dispatches.get_dispatch(dispatch_id) do
      nil ->
        {:error, :not_found}

      dispatch ->
        source_context = dispatch.source_context

        new_attrs = %{
          workspace_id: dispatch.workspace_id,
          connector_type: dispatch.connector_type,
          connector_event_id: EventId.replay(dispatch.connector_type),
          event_id: dispatch.event_id,
          event_inserted_at: dispatch.event_inserted_at,
          visitor_id: dispatch.visitor_id,
          source_context: source_context,
          status: "pending",
          replayed_from_id: dispatch.id,
          replayed_at: DateTime.utc_now()
        }

        case Dispatches.create_dispatch(new_attrs) do
          {:ok, new_dispatch} -> attempt_delivery(new_dispatch)
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp attempt_delivery(dispatch) do
    case Delivery.deliver(dispatch) do
      {:ok, delivered} -> {:ok, delivered}
      {:error, _} -> {:ok, dispatch}
    end
  end

  @doc """
  Replays all failed dispatches for a workspace and connector type.

  Returns `{:ok, count}` with the number of replayed dispatches.
  """
  def replay_all(workspace_id, connector_type) do
    connector_type_str = to_string(connector_type)

    dispatches =
      Dispatches.list_by_workspace(workspace_id, connector_type_str,
        limit: @replay_batch_limit,
        statuses: ["failed", "permanently_failed"]
      )

    results = Enum.map(dispatches, fn d -> replay(d.id) end)
    successes = Enum.count(results, &match?({:ok, _}, &1))

    {:ok, successes}
  end
end
