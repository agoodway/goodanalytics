defmodule GoodAnalytics.Connectors.Planner do
  @moduledoc """
  Evaluates enabled connectors for an event and creates dispatch records.

  For each connector-eligible event, the planner:
  1. Checks the global kill switch
  2. Iterates all registered connectors
  3. Checks per-workspace enablement
  4. Checks connector support for the event type
  5. Checks required signals
  6. Invokes the global dispatch policy callback
  7. Creates dispatch records for all eligible connectors
  8. Emits telemetry for skipped connectors with skip reasons
  """

  alias GoodAnalytics.Connectors.{Config, Dispatches, EventId, Settings, Signals}

  @telemetry_skip_event [:good_analytics, :connector, :dispatch, :skipped]
  @telemetry_created_event [:good_analytics, :connector, :dispatch, :created]

  @doc """
  Plans and creates dispatch records for a committed event.

  Returns `{:ok, dispatches}` with the list of created dispatch records,
  or `{:skip, :connectors_disabled}` if the global kill switch is off.

  ## Parameters

  - `event` — the committed event struct
  - `signals` — normalized connector signals map
  - `source_context` — the event-time source context for payload rebuilds
  - `opts` — optional keyword list:
    - `:consent_status` — consent status atom (default: `:consented`)
  """
  def plan(event, signals, source_context, opts \\ []) do
    if Config.connectors_enabled?() do
      consent_status = Keyword.get(opts, :consent_status, :consented)

      results =
        Config.registered_connectors()
        |> Enum.map(fn connector_mod ->
          evaluate_connector(connector_mod, event, signals, source_context, consent_status)
        end)

      eligible =
        results
        |> Enum.filter(&match?({:eligible, _}, &1))
        |> Enum.map(fn {:eligible, attrs} -> attrs end)

      case eligible do
        [] -> {:ok, []}
        attrs_list -> create_and_emit(attrs_list)
      end
    else
      {:skip, :connectors_disabled}
    end
  end

  defp evaluate_connector(connector_mod, event, signals, source_context, consent_status) do
    connector_type = connector_mod.connector_type()
    workspace_id = event.workspace_id
    event_type = to_string(event.event_type)

    cond do
      not Settings.connector_enabled?(workspace_id, connector_type) ->
        emit_skip(connector_type, workspace_id, :not_enabled)
        {:skipped, :not_enabled}

      event_type not in Enum.map(connector_mod.supported_event_types(), &to_string/1) ->
        emit_skip(connector_type, workspace_id, :unsupported_event_type)
        {:skipped, :unsupported_event_type}

      not Signals.has_required_signals?(signals, connector_mod.required_signals()) ->
        emit_skip(connector_type, workspace_id, :missing_signals)
        {:skipped, :missing_signals}

      consent_status != :consented and Config.dispatch_policy() == nil ->
        emit_skip(connector_type, workspace_id, :no_consent)
        {:skipped, :no_consent}

      true ->
        planning_context = %{
          connector_type: connector_type,
          event: event,
          signals: signals,
          consent_status: consent_status,
          workspace_id: workspace_id
        }

        case Config.evaluate_policy(planning_context) do
          :allow ->
            connector_event_id =
              EventId.derive(event.id, event.inserted_at, connector_type)

            attrs = %{
              workspace_id: workspace_id,
              connector_type: to_string(connector_type),
              connector_event_id: connector_event_id,
              event_id: event.id,
              event_inserted_at: event.inserted_at,
              visitor_id: event.visitor_id,
              source_context: source_context,
              status: "pending"
            }

            {:eligible, attrs}

          {:reject, reason} ->
            emit_skip(connector_type, workspace_id, {:policy_rejected, reason})
            {:skipped, {:policy_rejected, reason}}
        end
    end
  end

  defp create_and_emit(attrs_list) do
    case Dispatches.create_dispatches(attrs_list) do
      {:ok, result} ->
        dispatches =
          result
          |> Enum.sort_by(fn {{:dispatch, idx}, _} -> idx end)
          |> Enum.map(fn {_key, dispatch} -> dispatch end)

        emit_created_telemetry(dispatches)
        {:ok, dispatches}

      {:error, _failed_op, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp emit_skip(connector_type, workspace_id, reason) do
    :telemetry.execute(@telemetry_skip_event, %{count: 1}, %{
      connector_type: connector_type,
      workspace_id: workspace_id,
      reason: reason
    })
  end

  defp emit_created_telemetry(dispatches) do
    Enum.each(dispatches, fn dispatch ->
      :telemetry.execute(@telemetry_created_event, %{count: 1}, %{
        connector_type: dispatch.connector_type,
        workspace_id: dispatch.workspace_id,
        event_id: dispatch.event_id
      })
    end)
  end
end
