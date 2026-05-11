defmodule GoodAnalytics.Connectors.PostCommitTest do
  use ExUnit.Case, async: false

  alias GoodAnalytics.Connectors.PostCommit

  defmodule TxRepo do
    def in_transaction?, do: true
  end

  defmodule NoTxRepo do
    def in_transaction?, do: false
  end

  defmodule TestFlowRunner do
    def available?, do: true

    def start_flow(flow_module, input) do
      send(Process.get(:post_commit_test_pid), {:start_flow, flow_module, input})
      {:ok, "test-run"}
    end
  end

  setup do
    previous_repo = Application.get_env(:good_analytics, :repo)

    previous_runner =
      Application.get_env(:good_analytics, :connector_post_commit_flow_runner)

    Process.put(:post_commit_test_pid, self())

    on_exit(fn ->
      restore_env(:repo, previous_repo)
      restore_env(:connector_post_commit_flow_runner, previous_runner)
      Process.delete(:post_commit_test_pid)
    end)

    :ok
  end

  test "hands eligible events to the durable planning flow inside transactions" do
    Application.put_env(:good_analytics, :repo, TxRepo)
    Application.put_env(:good_analytics, :connector_post_commit_flow_runner, TestFlowRunner)

    event = %{
      id: "11111111-1111-1111-1111-111111111111",
      workspace_id: "00000000-0000-0000-0000-000000000000",
      visitor_id: "22222222-2222-2222-2222-222222222222",
      event_type: "lead",
      inserted_at: ~U[2026-04-21 12:00:00.000000Z],
      connector_source_context: %{"signals" => %{"_fbp" => "fb.1.123"}}
    }

    assert :ok == PostCommit.maybe_dispatch(event, %{connector_signals: %{"_fbp" => "fb.1.123"}})

    assert_receive {:start_flow, GoodAnalytics.Flows.ConnectorPlanning, input}
    assert input["event_id"] == event.id
    assert input["workspace_id"] == event.workspace_id
    assert input["visitor_id"] == event.visitor_id
    assert input["event_type"] == "lead"
    assert input["inserted_at"] == DateTime.to_iso8601(event.inserted_at)
  end

  test "skips the durable runner for ineligible events" do
    Application.put_env(:good_analytics, :repo, NoTxRepo)
    Application.put_env(:good_analytics, :connector_post_commit_flow_runner, TestFlowRunner)

    assert :ok == PostCommit.maybe_dispatch(%{event_type: "pageview"})
    refute_receive {:start_flow, _, _}
  end

  defp restore_env(key, nil), do: Application.delete_env(:good_analytics, key)
  defp restore_env(key, value), do: Application.put_env(:good_analytics, key, value)
end
