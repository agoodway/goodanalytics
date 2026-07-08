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

  ## Custom-event mapping snapshots

  For `custom` events, the enabled mapping is resolved at **dispatch-planning
  time** (immediately after the event commits) and snapshotted into the
  dispatch's `source_context` under the reserved `"mapping"` key via
  `EventMapping.to_snapshot/1`. That snapshot — not the live mapping — is what
  delivery and replay read, so a dispatch's outbound conversion is deterministic
  once the dispatch row exists, even if the mapping is later edited or deleted.

  The snapshot is authoritative only from dispatch creation onward: the mapping
  in effect when the event was *recorded* is not captured on the event, so a
  mapping change in the (typically sub-second) window between event commit and
  planning is reflected in the dispatch. Reconciliation likewise gates on the
  mappings current at reconciliation time within its lookback window.
  """

  alias GoodAnalytics.Connectors.{
    Config,
    Dispatches,
    EventId,
    EventMapping,
    EventMappings,
    Settings,
    Signals
  }

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

    # Gate on per-workspace enablement before the mapping lookup so disabled
    # connectors never issue a custom-event mapping query.
    if Settings.connector_enabled?(workspace_id, connector_type) do
      mapping =
        custom_event_mapping(event, event_type, workspace_id, connector_type, source_context)

      case preflight_connector(connector_mod, event_type, mapping, signals, consent_status) do
        :ok ->
          evaluate_policy(
            connector_type,
            workspace_id,
            event,
            signals,
            source_context,
            event_type,
            mapping,
            consent_status
          )

        {:skip, reason} ->
          emit_skip(connector_type, workspace_id, reason)
          {:skipped, reason}
      end
    else
      emit_skip(connector_type, workspace_id, :not_enabled)
      {:skipped, :not_enabled}
    end
  end

  defp preflight_connector(connector_mod, event_type, mapping, signals, consent_status) do
    cond do
      event_type == "custom" and is_nil(mapping) ->
        {:skip, :missing_event_mapping}

      not supported_event_type?(connector_mod, event_type, mapping) ->
        {:skip, :unsupported_event_type}

      not Signals.has_required_signals?(signals, connector_mod.required_signals()) ->
        {:skip, :missing_signals}

      consent_status != :consented and Config.dispatch_policy() == nil ->
        {:skip, :no_consent}

      true ->
        :ok
    end
  end

  defp evaluate_policy(
         connector_type,
         workspace_id,
         event,
         signals,
         source_context,
         event_type,
         mapping,
         consent_status
       ) do
    planning_context = %{
      connector_type: connector_type,
      event: event,
      signals: signals,
      consent_status: consent_status,
      workspace_id: workspace_id
    }

    case Config.evaluate_policy(planning_context) do
      :allow ->
        {:eligible,
         %{
           workspace_id: workspace_id,
           connector_type: to_string(connector_type),
           connector_event_id: EventId.derive(event.id, event.inserted_at, connector_type),
           event_id: event.id,
           event_inserted_at: event.inserted_at,
           visitor_id: event.visitor_id,
           source_context: source_context_with_mapping(source_context, event_type, mapping),
           status: "pending"
         }}

      {:reject, reason} ->
        emit_skip(connector_type, workspace_id, {:policy_rejected, reason})
        {:skipped, {:policy_rejected, reason}}
    end
  end

  defp supported_event_type?(connector_mod, event_type, mapping) do
    event_type in Enum.map(connector_mod.supported_event_types(), &to_string/1) or
      (event_type == "custom" and not is_nil(mapping))
  end

  defp custom_event_mapping(event, "custom", workspace_id, connector_type, source_context) do
    case Map.get(source_context, "event_name") || Map.get(event, :event_name) do
      event_name when is_binary(event_name) and event_name != "" ->
        EventMappings.enabled_mapping_for_event(workspace_id, event_name, connector_type)

      _ ->
        nil
    end
  end

  defp custom_event_mapping(_event, _event_type, _workspace_id, _connector_type, _source_context),
    do: nil

  defp source_context_with_mapping(source_context, "custom", %EventMapping{} = mapping) do
    Map.put(source_context, "mapping", EventMapping.to_snapshot(mapping))
  end

  defp source_context_with_mapping(source_context, _event_type, _mapping), do: source_context

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
