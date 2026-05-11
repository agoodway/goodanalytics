defmodule GoodAnalytics.Flows.ConnectorReconciliation do
  @moduledoc """
  pgflow Flow that reconciles missing connector dispatches.

  Scans connector-eligible events within a configurable time window
  (default: 24 hours) and creates dispatch records for any events
  that are missing dispatches for enabled connectors.

  ## Usage

      PgFlow.start_flow(GoodAnalytics.Flows.ConnectorReconciliation, %{
        "workspace_id" => workspace_id
      })

  """

  use PgFlow.Flow

  alias GoodAnalytics.Connectors.{Config, Dispatches, EventId, Settings, Signals}
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

            missing_events =
              Dispatches.find_missing_dispatches(
                to_string(connector_type),
                workspace_id,
                since,
                event_types
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
                source_context = event.connector_source_context || %{}

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
                case Dispatches.create_dispatches(attrs) do
                  {:ok, _} -> {count + length(attrs), new_scanned}
                  {:error, _, _, _} -> {count, new_scanned}
                end
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
end
