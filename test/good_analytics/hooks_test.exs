defmodule GoodAnalytics.HooksTest do
  use ExUnit.Case

  alias GoodAnalytics.Hooks

  describe "register/2 and notify_sync/3" do
    test "registers and dispatches a function callback" do
      test_pid = self()
      event_type = :"test_click_#{:erlang.unique_integer([:positive])}"

      callback = fn event, _visitor ->
        send(test_pid, {:hook_called, event})
        :ok
      end

      Hooks.register(event_type, callback)

      results = Hooks.notify_sync(event_type, %{id: "ev1"}, %{id: "v1"})
      assert_received {:hook_called, %{id: "ev1"}}
      assert results == [:ok]
    end

    test "registers MFA tuple" do
      event_type = :"test_sale_#{:erlang.unique_integer([:positive])}"

      defmodule TestHookHandler do
        def handle(_event, _visitor), do: :ok
      end

      Hooks.register(event_type, {TestHookHandler, :handle})

      results = Hooks.notify_sync(event_type, %{id: "ev2"}, %{id: "v2"})
      assert results == [:ok]
    end

    test "returns empty list for unregistered event types" do
      results = Hooks.notify_sync(:nonexistent, %{}, %{})
      assert results == []
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(Hooks)
      assert function_exported?(Hooks, :register, 2)
      assert function_exported?(Hooks, :notify_sync, 3)
      assert function_exported?(Hooks, :notify_async, 3)
    end
  end
end
