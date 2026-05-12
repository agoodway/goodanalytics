defmodule GoodAnalytics.Api.VisitorControllerTest do
  use GoodAnalytics.DataCase, async: false

  @workspace_id GoodAnalytics.default_workspace_id()

  setup do
    Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
      {:ok, %{workspace_id: @workspace_id}}
    end)

    on_exit(fn -> Application.delete_env(:good_analytics, :api_authenticate) end)
    :ok
  end

  defp api_conn(method, path) do
    conn = Plug.Test.conn(method, path)
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer test-token")
    GoodAnalytics.Api.Router.call(conn, GoodAnalytics.Api.Router.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "GET /visitors" do
    test "lists visitors for workspace" do
      create_visitor!()
      create_visitor!()

      conn = api_conn(:get, "/visitors")

      assert conn.status == 200
      assert length(json_body(conn)) >= 2
    end

    test "excludes merged visitors" do
      create_visitor!(%{status: "merged"})
      active = create_visitor!(%{status: "identified"})

      conn = api_conn(:get, "/visitors")

      body = json_body(conn)
      ids = Enum.map(body, & &1["id"])
      assert active.id in ids
    end

    test "supports pagination" do
      for _ <- 1..5, do: create_visitor!()

      conn = api_conn(:get, "/visitors?limit=2&offset=0")

      assert conn.status == 200
      assert length(json_body(conn)) == 2
    end
  end

  describe "GET /visitors/:id" do
    test "returns visitor by id" do
      visitor = create_visitor!()

      conn = api_conn(:get, "/visitors/#{visitor.id}")

      assert conn.status == 200
      assert json_body(conn)["id"] == visitor.id
    end

    test "returns 404 for non-existent visitor" do
      conn = api_conn(:get, "/visitors/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end

    test "returns 404 for visitor in different workspace" do
      visitor = create_visitor!(%{workspace_id: Ecto.UUID.generate()})

      conn = api_conn(:get, "/visitors/#{visitor.id}")
      assert conn.status == 404
    end
  end

  describe "GET /visitors/by-external-id/:external_id" do
    test "finds visitor by external id" do
      visitor = create_visitor!(%{person_external_id: "cust_456"})

      conn = api_conn(:get, "/visitors/by-external-id/cust_456")

      assert conn.status == 200
      assert json_body(conn)["id"] == visitor.id
    end

    test "returns 404 for unknown external id" do
      conn = api_conn(:get, "/visitors/by-external-id/unknown")
      assert conn.status == 404
    end
  end

  describe "GET /visitors/:id/timeline" do
    test "returns event timeline for visitor" do
      visitor = create_visitor!()
      record_event!(visitor, "pageview", %{url: "https://example.com"})
      record_event!(visitor, "sale", %{amount_cents: 1000})

      conn = api_conn(:get, "/visitors/#{visitor.id}/timeline")

      assert conn.status == 200
      body = json_body(conn)
      assert length(body) == 2
    end

    test "returns 404 for non-existent visitor" do
      conn = api_conn(:get, "/visitors/#{Ecto.UUID.generate()}/timeline")
      assert conn.status == 404
    end
  end

  describe "GET /visitors/:id/attribution" do
    test "returns attribution data for visitor" do
      visitor = create_visitor!(%{
        attribution_path: [%{"source" => "google", "medium" => "cpc"}],
        first_source: %{"platform" => "google"},
        last_source: %{"platform" => "direct"}
      })

      conn = api_conn(:get, "/visitors/#{visitor.id}/attribution")

      assert conn.status == 200
      body = json_body(conn)
      assert length(body["attribution_path"]) == 1
      assert body["first_source"]["platform"] == "google"
    end

    test "returns empty attribution for visitor with no data" do
      visitor = create_visitor!()

      conn = api_conn(:get, "/visitors/#{visitor.id}/attribution")

      assert conn.status == 200
      assert json_body(conn)["attribution_path"] == []
    end

    test "returns 404 for non-existent visitor" do
      conn = api_conn(:get, "/visitors/#{Ecto.UUID.generate()}/attribution")
      assert conn.status == 404
    end
  end
end
