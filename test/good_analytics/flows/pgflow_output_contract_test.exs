defmodule GoodAnalytics.Flows.PgflowOutputContractTest do
  @moduledoc """
  Pins the PgFlow handler-output contract for every GoodAnalytics flow.

  PgFlow stores a handler's return value only when `Jason.encode/1`
  succeeds and never wraps it, so run output and dependent steps see the
  JSON-decoded value. Each reachable branch must therefore survive a JSON
  round trip unchanged (atoms, tuples, structs and pids would not).
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Connectors.Adapters.Meta
  alias GoodAnalytics.Connectors.Dispatches

  alias GoodAnalytics.Flows.{
    ConnectorDelivery,
    ConnectorPlanning,
    ConnectorReconciliation,
    CreatePartitions
  }

  alias PgFlow.Worker.Executor

  setup do
    previous_connectors = Application.get_env(:good_analytics, :connectors)
    previous_enabled = Application.get_env(:good_analytics, :connectors_enabled)

    on_exit(fn ->
      restore_env(:connectors, previous_connectors)
      restore_env(:connectors_enabled, previous_enabled)
    end)

    :ok
  end

  describe "ConnectorDelivery :deliver" do
    test "not-found output round-trips through JSON" do
      dispatch_id = Ecto.UUID.generate()
      output = run_step(ConnectorDelivery, :deliver, %{"dispatch_id" => dispatch_id})

      assert output == %{"status" => "not_found", "dispatch_id" => dispatch_id}
      assert_json_round_trip(output)
    end

    test "delivery-result output round-trips through JSON" do
      Application.put_env(:good_analytics, :connectors, [Meta])

      {:ok, dispatch} =
        Dispatches.create_dispatch(%{
          workspace_id: Ecto.UUID.generate(),
          connector_type: "meta",
          connector_event_id: "contract-#{System.unique_integer([:positive])}",
          event_id: Ecto.UUID.generate(),
          event_inserted_at: DateTime.utc_now(),
          visitor_id: Ecto.UUID.generate(),
          payload_snapshot: %{},
          source_context: %{},
          status: "pending"
        })

      output = run_step(ConnectorDelivery, :deliver, %{"dispatch_id" => dispatch.id})

      assert output == %{
               "status" => "skipped_disabled",
               "dispatch_id" => dispatch.id,
               "connector_type" => "meta"
             }

      assert_json_round_trip(output)
    end
  end

  describe "ConnectorPlanning :plan" do
    test "skipped output round-trips through JSON" do
      Application.put_env(:good_analytics, :connectors_enabled, false)
      input = planning_input()

      output = run_step(ConnectorPlanning, :plan, input)

      assert output == %{
               "status" => "skipped",
               "event_id" => input["event_id"],
               "reason" => ":connectors_disabled"
             }

      assert_json_round_trip(output)
    end

    test "planned output round-trips through JSON" do
      Application.put_env(:good_analytics, :connectors_enabled, true)
      Application.put_env(:good_analytics, :connectors, [])
      input = planning_input()

      output = run_step(ConnectorPlanning, :plan, input)

      assert output == %{
               "status" => "planned",
               "event_id" => input["event_id"],
               "dispatches_created" => 0
             }

      assert_json_round_trip(output)
    end
  end

  describe "ConnectorReconciliation :reconcile" do
    test "connectors-disabled output round-trips through JSON" do
      Application.put_env(:good_analytics, :connectors_enabled, false)
      workspace_id = Ecto.UUID.generate()

      output = run_step(ConnectorReconciliation, :reconcile, %{"workspace_id" => workspace_id})

      assert output == %{
               "workspace_id" => workspace_id,
               "dispatches_created" => 0,
               "window_hours" => 24,
               "skipped" => "connectors_disabled"
             }

      assert_json_round_trip(output)
    end

    test "connectors-enabled output round-trips through JSON" do
      Application.put_env(:good_analytics, :connectors_enabled, true)
      Application.put_env(:good_analytics, :connectors, [Meta])
      workspace_id = Ecto.UUID.generate()

      output = run_step(ConnectorReconciliation, :reconcile, %{"workspace_id" => workspace_id})

      assert output == %{
               "workspace_id" => workspace_id,
               "dispatches_created" => 0,
               "window_hours" => 24
             }

      assert_json_round_trip(output)
    end
  end

  describe "CreatePartitions :create_partitions" do
    test "output round-trips through JSON" do
      output = run_step(CreatePartitions, :create_partitions, %{})

      assert %{"partitions" => [_ | _], "months_ahead" => 2} = output
      assert_json_round_trip(output)
    end
  end

  defp run_step(flow, step, input), do: flow.__pgflow_handler__(step).(input, %{})

  defp planning_input do
    %{
      "event_id" => Ecto.UUID.generate(),
      "workspace_id" => Ecto.UUID.generate(),
      "visitor_id" => Ecto.UUID.generate(),
      "event_type" => "lead",
      "inserted_at" => DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  defp assert_json_round_trip(output) do
    assert {:ok, ^output} = Executor.serialize_output(output)
    assert output |> Jason.encode!() |> Jason.decode!() == output
  end

  defp restore_env(key, nil), do: Application.delete_env(:good_analytics, key)
  defp restore_env(key, value), do: Application.put_env(:good_analytics, key, value)
end
