defmodule GoodAnalytics.Api.EventControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Api.Router
  alias GoodAnalytics.Core.Visitors

  @workspace_id GoodAnalytics.default_workspace_id()

  defmodule LocalhostGeoProvider do
    @behaviour GoodAnalytics.Geo.Provider

    @impl true
    def lookup({127, 0, 0, 1}),
      do:
        {:ok,
         %{
           "country" => %{"iso_code" => "US", "names" => %{"en" => "United States"}}
         }}

    def lookup(_), do: {:error, :not_found}
  end

  setup do
    Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
      {:ok, %{workspace_id: @workspace_id}}
    end)

    on_exit(fn -> Application.delete_env(:good_analytics, :api_authenticate) end)
    :ok
  end

  defp api_conn(method, path, body) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer test-token")
    Router.call(conn, Router.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Polls `fun` up to `timeout_ms` for the async geo enrichment task to land.
  defp eventually_assert(fun, timeout_ms \\ 1_000, step_ms \\ 20) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_until(fun, deadline, step_ms, timeout_ms)
  end

  defp poll_until(fun, deadline, step_ms, timeout_ms) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met within #{timeout_ms}ms")

      true ->
        Process.sleep(step_ms)
        poll_until(fun, deadline, step_ms, timeout_ms)
    end
  end

  describe "POST /events" do
    test "records event by visitor_id" do
      visitor = create_visitor!()

      conn =
        api_conn(:post, "/events", %{
          visitor_id: visitor.id,
          event_type: "sale",
          amount_cents: 4999,
          currency: "USD"
        })

      assert conn.status == 201
      assert %{"event_id" => _id} = json_body(conn)
    end

    test "records event by person_external_id" do
      _visitor = create_visitor!(%{person_external_id: "cust_123"})

      conn =
        api_conn(:post, "/events", %{
          person_external_id: "cust_123",
          event_type: "custom",
          event_name: "upgrade"
        })

      assert conn.status == 201
    end

    test "returns 404 when visitor not found" do
      conn =
        api_conn(:post, "/events", %{
          visitor_id: Ecto.UUID.generate(),
          event_type: "sale"
        })

      assert conn.status == 404
    end

    test "returns 422 when no visitor identifier provided" do
      conn = api_conn(:post, "/events", %{event_type: "sale"})

      assert conn.status == 422
    end

    test "returns 200 for idempotent duplicate" do
      visitor = create_visitor!()

      conn1 =
        api_conn(:post, "/events", %{
          visitor_id: visitor.id,
          event_type: "sale",
          idempotency_key: "idem-1"
        })

      assert conn1.status == 201
      event_id = json_body(conn1)["event_id"]

      conn2 =
        api_conn(:post, "/events", %{
          visitor_id: visitor.id,
          event_type: "sale",
          idempotency_key: "idem-1"
        })

      assert conn2.status == 200
      assert json_body(conn2)["event_id"] == event_id
    end

    test "returns 422 when properties exceed 50 keys" do
      visitor = create_visitor!()
      large_props = Map.new(1..51, fn i -> {"key_#{i}", "val"} end)

      conn =
        api_conn(:post, "/events", %{
          visitor_id: visitor.id,
          event_type: "custom",
          properties: large_props
        })

      assert conn.status == 422
    end

    test "populates visitor.geo via async enrichment when geo is enabled" do
      previous = Application.get_env(:good_analytics, :geo)

      Application.put_env(:good_analytics, :geo,
        provider: LocalhostGeoProvider,
        normalizer: GoodAnalytics.Geo.Normalizer.MaxMind
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:good_analytics, :geo, previous),
          else: Application.delete_env(:good_analytics, :geo)
      end)

      visitor = create_visitor!()

      conn =
        api_conn(:post, "/events", %{
          visitor_id: visitor.id,
          event_type: "sale",
          amount_cents: 100
        })

      assert conn.status == 201

      eventually_assert(fn ->
        case Visitors.get_visitor(visitor.id) do
          %{geo: %{"country_code" => "US"}} -> true
          _ -> false
        end
      end)
    end
  end

  describe "POST /events/batch" do
    test "records all events successfully" do
      visitor = create_visitor!()

      conn =
        api_conn(:post, "/events/batch", %{
          events: [
            %{visitor_id: visitor.id, event_type: "sale", amount_cents: 100},
            %{visitor_id: visitor.id, event_type: "lead"}
          ]
        })

      assert conn.status == 201
      body = json_body(conn)
      assert length(body["results"]) == 2
      assert Enum.all?(body["results"], &(&1["status"] == "ok"))
    end

    test "returns 207 on partial failure" do
      visitor = create_visitor!()

      conn =
        api_conn(:post, "/events/batch", %{
          events: [
            %{visitor_id: visitor.id, event_type: "sale"},
            %{visitor_id: Ecto.UUID.generate(), event_type: "sale"},
            %{visitor_id: visitor.id, event_type: "lead"}
          ]
        })

      assert conn.status == 207
      body = json_body(conn)
      results = body["results"]
      assert Enum.at(results, 0)["status"] == "ok"
      assert Enum.at(results, 1)["status"] == "error"
      assert Enum.at(results, 2)["status"] == "ok"
    end

    test "returns 207 when all events fail" do
      conn =
        api_conn(:post, "/events/batch", %{
          events: [
            %{visitor_id: Ecto.UUID.generate(), event_type: "sale"},
            %{visitor_id: Ecto.UUID.generate(), event_type: "lead"}
          ]
        })

      assert conn.status == 207
      body = json_body(conn)
      assert Enum.all?(body["results"], &(&1["status"] == "error"))
    end
  end
end
