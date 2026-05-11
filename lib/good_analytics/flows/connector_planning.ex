defmodule GoodAnalytics.Flows.ConnectorPlanning do
  @moduledoc """
  pgflow Flow that plans connector dispatches after the source event commits.

  Queue this flow from the event recorder so the scheduling record participates
  in the caller transaction. Once the transaction commits, the flow creates
  connector dispatch rows and fans out delivery flows for each dispatch.
  """

  use PgFlow.Flow

  alias GoodAnalytics.Connectors.Planner
  alias GoodAnalytics.Flows.ConnectorDelivery
  require Logger

  @flow slug: :ga_connector_planning,
        max_attempts: 3,
        base_delay: 10,
        timeout: 60

  step :plan do
    fn input, _ctx ->
      event = build_event(input)
      signals = Map.get(input, "connector_signals", %{})
      source_context = Map.get(input, "source_context", %{})

      case Planner.plan(event, signals, source_context) do
        {:ok, dispatches} ->
          Enum.each(dispatches, fn dispatch ->
            case PgFlow.start_flow(ConnectorDelivery, %{"dispatch_id" => dispatch.id}) do
              {:ok, _run_id} ->
                :ok

              {:error, reason} ->
                Logger.warning(
                  "GoodAnalytics: failed to enqueue connector delivery flow for dispatch #{dispatch.id}: #{inspect(reason)}"
                )
            end
          end)

          if match?([_ | _], dispatches) do
            Logger.debug(
              "GoodAnalytics: created #{length(dispatches)} connector dispatches for event #{event.id}"
            )
          end

          %{
            "status" => "planned",
            "event_id" => event.id,
            "dispatches_created" => length(dispatches)
          }

        {:skip, reason} ->
          Logger.debug("GoodAnalytics: skipped connector dispatch planning: #{inspect(reason)}")

          %{
            "status" => "skipped",
            "event_id" => event.id,
            "reason" => inspect(reason)
          }

        {:error, reason} ->
          Logger.warning(
            "GoodAnalytics: connector dispatch creation failed for event #{event.id}: #{inspect(reason)}"
          )

          %{
            "status" => "error",
            "event_id" => event.id,
            "reason" => inspect(reason)
          }
      end
    end
  end

  defp build_event(input) do
    %{
      id: Map.fetch!(input, "event_id"),
      workspace_id: Map.fetch!(input, "workspace_id"),
      visitor_id: Map.fetch!(input, "visitor_id"),
      event_type: Map.fetch!(input, "event_type"),
      inserted_at: parse_datetime!(Map.fetch!(input, "inserted_at")),
      connector_source_context: Map.get(input, "source_context", %{})
    }
  end

  defp parse_datetime!(%DateTime{} = datetime), do: datetime

  defp parse_datetime!(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, reason} ->
        raise ArgumentError, "invalid connector planning timestamp: #{inspect(reason)}"
    end
  end
end
