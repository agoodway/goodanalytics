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

  describe "async hooks (opt-in via register/3 + notify_detached/3)" do
    test "notify_sync does not invoke an async-registered callback" do
      test_pid = self()
      event_type = :"test_async_#{:erlang.unique_integer([:positive])}"

      Hooks.register(event_type, fn _e, _v -> send(test_pid, :async_ran) end, async: true)

      results = Hooks.notify_sync(event_type, %{}, %{})

      assert results == []
      refute_received :async_ran
    end

    test "notify_detached/3 dispatches async-registered callbacks fire-and-forget" do
      test_pid = self()
      event_type = :"test_async_#{:erlang.unique_integer([:positive])}"

      Hooks.register(event_type, fn e, _v -> send(test_pid, {:async_ran, e}) end, async: true)

      assert :ok = Hooks.notify_detached(event_type, %{id: "ev"}, %{})

      assert_receive {:async_ran, %{id: "ev"}}, 1_000
    end

    test "notify_detached/3 ignores sync-registered (default) callbacks" do
      test_pid = self()
      event_type = :"test_async_#{:erlang.unique_integer([:positive])}"

      Hooks.register(event_type, fn _e, _v -> send(test_pid, :sync_ran) end)

      assert :ok = Hooks.notify_detached(event_type, %{}, %{})

      refute_receive :sync_ran, 200
    end

    test "an async hook slower than the 50ms sync budget still runs to completion" do
      test_pid = self()
      event_type = :"test_async_#{:erlang.unique_integer([:positive])}"

      Hooks.register(
        event_type,
        fn _e, _v ->
          Process.sleep(120)
          send(test_pid, :slow_done)
        end,
        async: true
      )

      # Sync path returns immediately (async hook is not in the sync tier);
      # detached path runs it with no time budget.
      assert Hooks.notify_sync(event_type, %{}, %{}) == []
      assert :ok = Hooks.notify_detached(event_type, %{}, %{})

      assert_receive :slow_done, 1_000
    end

    test "register/3 defaults to the sync tier, preserving notify_sync dispatch" do
      test_pid = self()
      event_type = :"test_async_#{:erlang.unique_integer([:positive])}"

      Hooks.register(
        event_type,
        fn _e, _v ->
          send(test_pid, :ran)
          :ok
        end,
        []
      )

      assert Hooks.notify_sync(event_type, %{}, %{}) == [:ok]
      assert_received :ran
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(Hooks)
      assert function_exported?(Hooks, :register, 2)
      assert function_exported?(Hooks, :register, 3)
      assert function_exported?(Hooks, :notify_sync, 3)
      assert function_exported?(Hooks, :notify_async, 3)
      assert function_exported?(Hooks, :notify_detached, 3)
    end
  end
end
