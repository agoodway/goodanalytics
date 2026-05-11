defmodule GoodAnalytics.Integration.HookDispatchTest do
  @moduledoc """
  OpenSpec 12.3: Hook dispatch integration test.

  Tests: register hook -> trigger event -> verify hook called with correct data.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.Links.Redirect

  import Plug.Test

  describe "hook dispatch" do
    test "sale event triggers :sale hook with correct data" do
      test_pid = self()

      GoodAnalytics.register_hook(:sale, fn event, visitor ->
        send(test_pid, {:hook_sale, event, visitor})
        :ok
      end)

      visitor = resolve_visitor!(%{ga_id: "hook_sale_ga_#{System.unique_integer([:positive])}"})
      {:ok, _event} = Recorder.record_sale(visitor, %{amount_cents: 4900, currency: "USD"})

      assert_receive {:hook_sale, hook_event, hook_visitor}, 2000
      assert hook_event.event_type == "sale"
      assert hook_event.amount_cents == 4900
      assert hook_visitor.id == visitor.id
    end

    test "link_click hook fires on redirect" do
      test_pid = self()

      GoodAnalytics.register_hook(:link_click, fn event, visitor ->
        send(test_pid, {:hook_click, event, visitor})
        :ok
      end)

      link = create_link!(%{domain: "hook.link", url: "https://example.com/hook"})

      conn =
        conn(:get, "/#{link.key}")
        |> Map.put(:host, "hook.link")
        |> Map.put(:query_params, %{})
        |> Plug.Conn.fetch_query_params()
        |> Plug.Conn.put_req_header("user-agent", "HookTest/1.0")
        |> Plug.Conn.put_private(:phoenix_format, "html")

      Redirect.handle_redirect(conn, "hook.link", link.key)

      # Sync hook from redirect passes %{link: _, click_id: _, source: _}
      assert_receive {:hook_click, hook_event, _hook_visitor}, 2000
      assert Map.has_key?(hook_event, :click_id) or Map.has_key?(hook_event, :link_id)
    end

    test "hook crash does not break event recording" do
      GoodAnalytics.register_hook(:lead, fn _event, _visitor ->
        raise "intentional crash"
      end)

      visitor = resolve_visitor!(%{ga_id: "hook_crash_ga_#{System.unique_integer([:positive])}"})
      assert {:ok, event} = Recorder.record_lead(visitor, %{})
      assert event.event_type == "lead"
    end
  end
end
