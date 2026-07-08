defmodule GoodAnalytics.Connectors.EventMappingsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Connectors.EventMappings

  @workspace_id GoodAnalytics.default_workspace_id()

  describe "mapping CRUD" do
    test "creates, gets, updates, lists, and deletes mappings" do
      assert {:ok, mapping} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: " trial_started ",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      assert {:ok, _} = Ecto.UUID.cast(mapping.id)
      assert mapping.event_name == "trial_started"
      assert mapping.connector_type == "meta"
      assert mapping.enabled == true

      assert EventMappings.get_mapping(@workspace_id, mapping.id).id == mapping.id
      assert EventMappings.get_mapping(@workspace_id, "trial_started", :meta).id == mapping.id
      assert [listed] = EventMappings.list_mappings(@workspace_id, :meta)
      assert listed.id == mapping.id

      assert {:ok, updated} = EventMappings.update_mapping(mapping, %{enabled: false})
      refute updated.enabled
      assert EventMappings.enabled_mapping_for_event(@workspace_id, "trial_started", :meta) == nil

      assert {:ok, deleted} = EventMappings.delete_mapping(updated)
      assert deleted.id == mapping.id
      assert EventMappings.get_mapping(@workspace_id, mapping.id) == nil
    end

    test "get_mapping/2 does not leak mappings across workspaces" do
      other_workspace = Ecto.UUID.generate()

      assert {:ok, mapping} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      assert EventMappings.get_mapping(@workspace_id, mapping.id).id == mapping.id
      assert EventMappings.get_mapping(other_workspace, mapping.id) == nil
    end

    test "update_mapping keeps workspace and identity fields frozen" do
      other_workspace = Ecto.UUID.generate()

      assert {:ok, mapping} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      assert {:ok, updated} =
               EventMappings.update_mapping(mapping, %{
                 workspace_id: other_workspace,
                 event_name: "hijacked",
                 connector_type: :google,
                 connector_event_name: "RenamedTrial"
               })

      assert updated.workspace_id == @workspace_id
      assert updated.event_name == "trial_started"
      assert updated.connector_type == "meta"
      assert updated.connector_event_name == "RenamedTrial"
    end

    test "rejects duplicates within a workspace and connector" do
      attrs = %{
        workspace_id: @workspace_id,
        event_name: "trial_started",
        connector_type: :meta,
        connector_event_name: "StartTrial"
      }

      assert {:ok, _mapping} = EventMappings.create_mapping(attrs)
      assert {:error, changeset} = EventMappings.create_mapping(attrs)
      assert %{event_name: _} = errors_on(changeset)
    end

    test "isolates mappings by workspace" do
      other_workspace = Ecto.UUID.generate()

      assert {:ok, first} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      assert {:ok, second} =
               EventMappings.create_mapping(%{
                 workspace_id: other_workspace,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "LeadTrial"
               })

      assert EventMappings.get_mapping(@workspace_id, "trial_started", :meta).id == first.id
      assert EventMappings.get_mapping(other_workspace, "trial_started", :meta).id == second.id
    end

    test "lists enabled mapped event names by workspace and connector" do
      assert {:ok, _} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      assert {:ok, _} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "demo_booked",
                 connector_type: :meta,
                 connector_event_name: "Schedule"
               })

      assert {:ok, _} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "ignored",
                 connector_type: :tiktok,
                 connector_event_name: "CompleteRegistration",
                 enabled: false
               })

      assert EventMappings.enabled_event_names(@workspace_id, :meta) == [
               "demo_booked",
               "trial_started"
             ]

      assert EventMappings.enabled_event_names(@workspace_id, :tiktok) == []
    end

    test "enabled_event_names isolates by workspace" do
      other_workspace = Ecto.UUID.generate()

      assert {:ok, _} =
               EventMappings.create_mapping(%{
                 workspace_id: @workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      assert {:ok, _} =
               EventMappings.create_mapping(%{
                 workspace_id: other_workspace,
                 event_name: "demo_booked",
                 connector_type: :meta,
                 connector_event_name: "Schedule"
               })

      assert EventMappings.enabled_event_names(@workspace_id, :meta) == ["trial_started"]
      assert EventMappings.enabled_event_names(other_workspace, :meta) == ["demo_booked"]
    end
  end
end
