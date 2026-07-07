defmodule GoodAnalytics.Flows.ConnectorReconciliation do
  @moduledoc """
  pgflow Flow that reconciles missing connector dispatches.

  Scans connector-eligible events within a configurable time window
  (default: 24 hours) and creates dispatch records for any events
  that are missing dispatches for enabled connectors.

  ## Mapping eligibility

  For `custom` events, reconciliation gates on the connector mappings that are
  enabled *at reconciliation time* (bounded by the lookback window). This is a
  recovery mechanism: it backfills dispatches for events that are currently
  mapped but never produced a dispatch. It therefore does not recover events
  whose mapping was disabled or deleted after the event was recorded, and it may
  create dispatches for in-window events that predate the mapping — both of which
  are intentional consequences of using current mappings as the eligibility gate.

  ## Usage

      PgFlow.start_flow(GoodAnalytics.Flows.ConnectorReconciliation, %{
        "workspace_id" => workspace_id
      })

  """

  use PgFlow.Flow

  require Logger

  alias GoodAnalytics.Connectors.{
    Config,
    Dispatches,
    EventId,
    EventMapping,
    EventMappings,
    Settings,
    Signals
  }

  alias GoodAnalytics.TimeWindow

  @flow slug: :ga_connector_reconciliation,
        max_attempts: 3,
        base_delay: 30,
        timeout: 300

  @telemetry_scan [:good_analytics, :connector, :reconciliation, :scan]

  step :reconcile do
    fn input, _ctx ->
      workspace_id = Map.fetch!(input, "workspace_id")
      window_hours = reconciliation_window()
      since = TimeWindow.trailing_start(DateTime.utc_now(), window_hours, :hour)

      if Config.connectors_enabled?() do
        {total_created, total_scanned} =
          Config.registered_connectors()
          |> Enum.filter(fn mod ->
            Settings.connector_enabled?(workspace_id, mod.connector_type())
          end)
          |> Enum.reduce({0, 0}, fn connector_mod, {count, scanned} ->
            connector_type = connector_mod.connector_type()
            event_types = connector_mod.supported_event_types() |> Enum.map(&to_string/1)

            # Load the enabled mappings once per connector and index by event
            # name, so eligibility gating and snapshot building never re-query.
            mappings_by_name =
              workspace_id
              |> EventMappings.list_enabled_mappings(connector_type)
              |> Map.new(fn mapping -> {mapping.event_name, mapping} end)

            missing_events =
              Dispatches.find_missing_dispatches(
                to_string(connector_type),
                workspace_id,
                since,
                event_types,
                Map.keys(mappings_by_name)
              )

            dispatches_attrs =
              missing_events
              |> Enum.filter(fn event ->
                signals = Map.get(event.connector_source_context || %{}, "signals", %{})

                Signals.has_required_signals?(signals, connector_mod.required_signals()) and
                  Config.evaluate_policy(%{
                    connector_type: connector_type,
                    event: event,
                    signals: signals,
                    consent_status: :consented,
                    workspace_id: workspace_id
                  }) == :allow
              end)
              |> Enum.map(fn event ->
                source_context = source_context_for_event(event, mappings_by_name)

                %{
                  workspace_id: workspace_id,
                  connector_type: to_string(connector_type),
                  connector_event_id: EventId.derive(event.id, event.inserted_at, connector_type),
                  event_id: event.id,
                  event_inserted_at: event.inserted_at,
                  visitor_id: event.visitor_id,
                  source_context: source_context,
                  status: "pending"
                }
              end)

            new_scanned = scanned + length(missing_events)

            case dispatches_attrs do
              [] ->
                {count, new_scanned}

              attrs ->
                {count + insert_dispatches(attrs, workspace_id, connector_type), new_scanned}
            end
          end)

        :telemetry.execute(
          @telemetry_scan,
          %{
            events_scanned: total_scanned,
            dispatches_created: total_created
          },
          %{workspace_id: workspace_id}
        )

        %{
          "workspace_id" => workspace_id,
          "dispatches_created" => total_created,
          "window_hours" => window_hours
        }
      else
        :telemetry.execute(
          @telemetry_scan,
          %{
            events_scanned: 0,
            dispatches_created: 0
          },
          %{workspace_id: workspace_id}
        )

        %{
          "workspace_id" => workspace_id,
          "dispatches_created" => 0,
          "window_hours" => window_hours,
          "skipped" => "connectors_disabled"
        }
      end
    end
  end

  defp reconciliation_window do
    Application.get_env(:good_analytics, :reconciliation_window_hours, 24)
  end

  # Inserts the reconciled dispatches one row at a time, returning how many were
  # created. Per-row (rather than a single batch transaction) so that a unique
  # conflict — a concurrent planner/reconciliation run already created that one
  # dispatch — is isolated and never rolls back its non-conflicting batch-mates.
  # A unique conflict is idempotent (not an error); any other failure is logged
  # so a real DB/config bug is not silently reported as "created zero".
  defp insert_dispatches(attrs, workspace_id, connector_type) do
    Enum.reduce(attrs, 0, fn dispatch_attrs, created ->
      created + insert_dispatch(dispatch_attrs, workspace_id, connector_type)
    end)
  end

  defp insert_dispatch(dispatch_attrs, workspace_id, connector_type) do
    case Dispatches.create_dispatch(dispatch_attrs) do
      {:ok, _} ->
        1

      {:error, %Ecto.Changeset{} = changeset} ->
        log_unless_conflict(changeset, workspace_id, connector_type)
        0
    end
  end

  defp log_unless_conflict(changeset, workspace_id, connector_type) do
    unless unique_constraint_error?(changeset) do
      Logger.error(
        "GoodAnalytics: connector reconciliation insert failed for workspace " <>
          "#{workspace_id} connector #{connector_type}: #{inspect(changeset.errors)}"
      )
    end

    :ok
  end

  defp unique_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp source_context_for_event(%{event_type: "custom"} = event, mappings_by_name) do
    source_context = event.connector_source_context || %{}

    case Map.get(mappings_by_name, event.event_name) do
      %EventMapping{} = mapping ->
        Map.put(source_context, "mapping", EventMapping.to_snapshot(mapping))

      _ ->
        source_context
    end
  end

  defp source_context_for_event(event, _mappings_by_name),
    do: event.connector_source_context || %{}
end
