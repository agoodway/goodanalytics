defmodule GoodAnalytics.Flows.ConnectorReconciliationTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Connectors.Adapters.{Google, LinkedIn, Meta, TikTok}
  alias GoodAnalytics.Connectors.{Dispatches, EventMappings, Settings}
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Flows.ConnectorReconciliation

  setup do
    previous_connectors = Application.get_env(:good_analytics, :connectors)
    Application.put_env(:good_analytics, :connectors, [Meta])

    on_exit(fn -> restore_env(:connectors, previous_connectors) end)
    :ok
  end

  test "recovers mapped custom events and ignores unmapped custom events" do
    workspace_id = default_workspace_id()
    visitor = create_visitor!(%{workspace_id: workspace_id})
    Settings.enable_connector(workspace_id, :meta)

    assert {:ok, _mapping} =
             EventMappings.create_mapping(%{
               workspace_id: workspace_id,
               event_name: "trial_started",
               connector_type: :meta,
               connector_event_name: "StartTrial"
             })

    mapped = insert_event!(workspace_id, visitor.id, "trial_started")
    unmapped = insert_event!(workspace_id, visitor.id, "demo_booked")

    handler = ConnectorReconciliation.__pgflow_handler__(:reconcile)

    assert %{"dispatches_created" => 1} = handler.(%{"workspace_id" => workspace_id}, %{})

    assert [mapped_dispatch] = Dispatches.list_by_event(mapped.id)
    assert mapped_dispatch.source_context["mapping"]["connector_event_name"] == "StartTrial"
    assert Dispatches.list_by_event(unmapped.id) == []
  end

  test "is idempotent across repeated runs" do
    workspace_id = default_workspace_id()
    visitor = create_visitor!(%{workspace_id: workspace_id})
    Settings.enable_connector(workspace_id, :meta)

    assert {:ok, _mapping} =
             EventMappings.create_mapping(%{
               workspace_id: workspace_id,
               event_name: "trial_started",
               connector_type: :meta,
               connector_event_name: "StartTrial"
             })

    mapped = insert_event!(workspace_id, visitor.id, "trial_started")
    handler = ConnectorReconciliation.__pgflow_handler__(:reconcile)

    assert %{"dispatches_created" => 1} = handler.(%{"workspace_id" => workspace_id}, %{})
    # Second run finds the dispatch already exists and creates nothing new,
    # without raising or duplicating.
    assert %{"dispatches_created" => 0} = handler.(%{"workspace_id" => workspace_id}, %{})
    assert [_only_one] = Dispatches.list_by_event(mapped.id)
  end

  test "builds correct source context for Google, LinkedIn, and TikTok mappings" do
    workspace_id = default_workspace_id()
    visitor = create_visitor!(%{workspace_id: workspace_id})
    Application.put_env(:good_analytics, :connectors, [Google, LinkedIn, TikTok])

    for connector <- [:google, :linkedin, :tiktok] do
      Settings.enable_connector(workspace_id, connector)
    end

    assert {:ok, _} =
             EventMappings.create_mapping(%{
               workspace_id: workspace_id,
               event_name: "trial_started",
               connector_type: :google,
               config: %{"conversion_action_id" => "123456"}
             })

    assert {:ok, _} =
             EventMappings.create_mapping(%{
               workspace_id: workspace_id,
               event_name: "trial_started",
               connector_type: :linkedin,
               config: %{"conversion_rule_id" => "789012"}
             })

    assert {:ok, _} =
             EventMappings.create_mapping(%{
               workspace_id: workspace_id,
               event_name: "trial_started",
               connector_type: :tiktok,
               connector_event_name: "CompleteRegistration"
             })

    event =
      insert_event!(workspace_id, visitor.id, "trial_started", %{
        "gclid" => "g1",
        "li_fat_id" => "li1",
        "ttclid" => "tt1"
      })

    handler = ConnectorReconciliation.__pgflow_handler__(:reconcile)
    assert %{"dispatches_created" => 3} = handler.(%{"workspace_id" => workspace_id}, %{})

    by_type =
      event.id
      |> Dispatches.list_by_event()
      |> Map.new(fn dispatch -> {dispatch.connector_type, dispatch} end)

    assert by_type["google"].source_context["mapping"]["config"]["conversion_action_id"] ==
             "123456"

    assert by_type["linkedin"].source_context["mapping"]["config"]["conversion_rule_id"] ==
             "789012"

    assert by_type["tiktok"].source_context["mapping"]["connector_event_name"] ==
             "CompleteRegistration"
  end

  defp insert_event!(workspace_id, visitor_id, event_name, signals \\ %{"_fbp" => "fb.1.123"}) do
    %Event{id: Uniq.UUID.uuid7(), inserted_at: DateTime.utc_now()}
    |> Event.changeset(%{
      workspace_id: workspace_id,
      visitor_id: visitor_id,
      event_type: "custom",
      event_name: event_name,
      connector_source_context: %{
        "event_type" => "custom",
        "event_name" => event_name,
        "signals" => signals
      }
    })
    |> TestRepo.insert!(prefix: "good_analytics")
  end

  defp restore_env(key, nil), do: Application.delete_env(:good_analytics, key)
  defp restore_env(key, value), do: Application.put_env(:good_analytics, key, value)
end
