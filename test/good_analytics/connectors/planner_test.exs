defmodule GoodAnalytics.Connectors.PlannerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Connectors.Adapters.{Google, Meta}
  alias GoodAnalytics.Connectors.{EventId, EventMappings, Planner, Settings}

  defmodule RejectPolicy do
    def evaluate(_context), do: {:reject, :blocked}
  end

  setup do
    previous_connectors = Application.get_env(:good_analytics, :connectors)
    previous_policy = Application.get_env(:good_analytics, :dispatch_policy)

    on_exit(fn ->
      restore_env(:connectors, previous_connectors)
      restore_env(:dispatch_policy, previous_policy)
    end)

    :ok
  end

  describe "EventId.derive/3" do
    test "produces deterministic IDs" do
      event_id = "11111111-1111-1111-1111-111111111111"
      ts = utc_now()

      id1 = EventId.derive(event_id, ts, :meta)
      id2 = EventId.derive(event_id, ts, :meta)
      assert id1 == id2
    end

    test "different connector types produce different IDs" do
      event_id = "11111111-1111-1111-1111-111111111111"
      ts = utc_now()

      meta_id = EventId.derive(event_id, ts, :meta)
      google_id = EventId.derive(event_id, ts, :google)
      assert meta_id != google_id
    end

    test "includes connector type prefix" do
      id = EventId.derive("abc", utc_now(), :tiktok)
      assert String.starts_with?(id, "tiktok_")
    end

    test "different events produce different IDs" do
      ts = utc_now()
      id1 = EventId.derive("event-1", ts, :meta)
      id2 = EventId.derive("event-2", ts, :meta)
      assert id1 != id2
    end
  end

  describe "Planner.plan/4 — kill switch" do
    test "returns skip when connectors disabled" do
      # Temporarily set connectors_enabled to false
      original = Application.get_env(:good_analytics, :connectors_enabled)
      Application.put_env(:good_analytics, :connectors_enabled, false)

      event = fake_event("lead")
      result = Planner.plan(event, %{}, %{})
      assert result == {:skip, :connectors_disabled}

      # Restore
      if original do
        Application.put_env(:good_analytics, :connectors_enabled, original)
      else
        Application.delete_env(:good_analytics, :connectors_enabled)
      end
    end
  end

  describe "Planner.plan/4 — no connectors configured" do
    test "returns empty list when no connectors registered" do
      Application.delete_env(:good_analytics, :connectors)
      event = fake_event("lead")
      assert {:ok, []} = Planner.plan(event, %{"_fbp" => "fb.1.123"}, %{})
    end
  end

  describe "Planner.plan/4 — mapped custom events" do
    test "creates a dispatch with a mapping snapshot" do
      Application.put_env(:good_analytics, :connectors, [Meta])
      workspace_id = default_workspace_id()
      Settings.enable_connector(workspace_id, :meta)

      assert {:ok, mapping} =
               EventMappings.create_mapping(%{
                 workspace_id: workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      event = fake_event("custom", workspace_id)
      source_context = %{"event_type" => "custom", "event_name" => "trial_started"}

      assert {:ok, [dispatch]} = Planner.plan(event, %{"_fbp" => "fb.1.123"}, source_context)

      assert dispatch.source_context["mapping"] == %{
               "id" => mapping.id,
               "event_type" => "custom",
               "event_name" => "trial_started",
               "connector_event_name" => "StartTrial",
               "config" => %{}
             }
    end

    test "skips unmapped custom events with missing_event_mapping telemetry" do
      Application.put_env(:good_analytics, :connectors, [Meta])
      workspace_id = default_workspace_id()
      Settings.enable_connector(workspace_id, :meta)
      attach_skip_handler()

      event = fake_event("custom", workspace_id)

      assert {:ok, []} =
               Planner.plan(event, %{"_fbp" => "fb.1.123"}, %{
                 "event_type" => "custom",
                 "event_name" => "trial_started"
               })

      assert_receive {:connector_skip, %{reason: :missing_event_mapping, connector_type: :meta}}
    end

    test "mapped custom events still require connector signals" do
      Application.put_env(:good_analytics, :connectors, [Google])
      workspace_id = default_workspace_id()
      Settings.enable_connector(workspace_id, :google)
      attach_skip_handler()

      assert {:ok, _mapping} =
               EventMappings.create_mapping(%{
                 workspace_id: workspace_id,
                 event_name: "trial_started",
                 connector_type: :google,
                 config: %{"conversion_action_id" => "123456"}
               })

      event = fake_event("custom", workspace_id) |> Map.put(:event_name, "trial_started")

      assert {:ok, []} =
               Planner.plan(event, %{}, %{
                 "event_type" => "custom"
               })

      assert_receive {:connector_skip, %{reason: :missing_signals, connector_type: :google}}
    end

    test "built-in lead dispatches do not require mappings" do
      Application.put_env(:good_analytics, :connectors, [Meta])
      workspace_id = default_workspace_id()
      Settings.enable_connector(workspace_id, :meta)

      event = fake_event("lead", workspace_id)

      assert {:ok, [dispatch]} =
               Planner.plan(event, %{"_fbp" => "fb.1.123"}, %{"event_type" => "lead"})

      refute Map.has_key?(dispatch.source_context, "mapping")
    end

    test "mapped custom events still honor dispatch policy rejection" do
      Application.put_env(:good_analytics, :connectors, [Meta])
      Application.put_env(:good_analytics, :dispatch_policy, {RejectPolicy, :evaluate})
      workspace_id = default_workspace_id()
      Settings.enable_connector(workspace_id, :meta)
      attach_skip_handler()

      assert {:ok, _mapping} =
               EventMappings.create_mapping(%{
                 workspace_id: workspace_id,
                 event_name: "trial_started",
                 connector_type: :meta,
                 connector_event_name: "StartTrial"
               })

      event = fake_event("custom", workspace_id)

      assert {:ok, []} =
               Planner.plan(event, %{"_fbp" => "fb.1.123"}, %{
                 "event_type" => "custom",
                 "event_name" => "trial_started"
               })

      assert_receive {:connector_skip,
                      %{reason: {:policy_rejected, :blocked}, connector_type: :meta}}
    end
  end

  describe "PostCommit.connector_eligible?/1" do
    alias GoodAnalytics.Connectors.PostCommit

    test "lead events are connector eligible" do
      assert PostCommit.connector_eligible?(%{event_type: "lead"})
    end

    test "sale events are connector eligible" do
      assert PostCommit.connector_eligible?(%{event_type: "sale"})
    end

    test "pageview events are not connector eligible" do
      refute PostCommit.connector_eligible?(%{event_type: "pageview"})
    end

    test "custom events are connector eligible" do
      assert PostCommit.connector_eligible?(%{event_type: "custom"})
    end
  end

  defp fake_event(event_type, workspace_id \\ "00000000-0000-0000-0000-000000000000") do
    %{
      id: "11111111-1111-1111-1111-111111111111",
      workspace_id: workspace_id,
      visitor_id: "22222222-2222-2222-2222-222222222222",
      event_type: event_type,
      inserted_at: utc_now(),
      connector_source_context: %{}
    }
  end

  defp attach_skip_handler do
    test_pid = self()
    handler_id = {:planner_test, make_ref()}

    :telemetry.attach(
      handler_id,
      [:good_analytics, :connector, :dispatch, :skipped],
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:connector_skip, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp restore_env(key, nil), do: Application.delete_env(:good_analytics, key)
  defp restore_env(key, value), do: Application.put_env(:good_analytics, key, value)
end
