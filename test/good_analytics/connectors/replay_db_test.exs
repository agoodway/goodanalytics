defmodule GoodAnalytics.Connectors.ReplayDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Connectors.{Dispatches, EventMappings, Replay}

  test "replay copies the stored custom mapping snapshot instead of reading the live mapping" do
    workspace_id = default_workspace_id()
    event_id = Ecto.UUID.generate()
    event_inserted_at = DateTime.utc_now()
    visitor_id = Ecto.UUID.generate()

    assert {:ok, mapping} =
             EventMappings.create_mapping(%{
               workspace_id: workspace_id,
               event_name: "trial_started",
               connector_type: :meta,
               connector_event_name: "StartTrial"
             })

    snapshot = %{
      "id" => mapping.id,
      "event_type" => "custom",
      "event_name" => "trial_started",
      "connector_event_name" => "StartTrial",
      "config" => %{}
    }

    assert {:ok, dispatch} =
             Dispatches.create_dispatch(%{
               workspace_id: workspace_id,
               connector_type: "meta",
               connector_event_id: "meta_original",
               event_id: event_id,
               event_inserted_at: event_inserted_at,
               visitor_id: visitor_id,
               source_context: %{
                 "event_type" => "custom",
                 "event_name" => "trial_started",
                 "mapping" => snapshot
               }
             })

    assert {:ok, _updated} =
             EventMappings.update_mapping(mapping, %{
               connector_event_name: "ChangedEventName",
               enabled: false
             })

    assert {:ok, replayed} = Replay.replay(dispatch.id)
    assert replayed.source_context["mapping"] == snapshot
    assert replayed.replayed_from_id == dispatch.id
  end
end
