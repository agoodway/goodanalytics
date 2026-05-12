defmodule GoodAnalytics.Api.LinkControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Api.Router

  @workspace_id GoodAnalytics.default_workspace_id()

  setup do
    Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
      {:ok, %{workspace_id: @workspace_id}}
    end)

    on_exit(fn -> Application.delete_env(:good_analytics, :api_authenticate) end)
    :ok
  end

  defp api_conn(method, path, body \\ nil) do
    conn = Plug.Test.conn(method, path, body && Jason.encode!(body))
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")
    conn = Plug.Conn.put_req_header(conn, "authorization", "Bearer test-token")
    Router.call(conn, Router.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  describe "POST /links" do
    test "creates a link" do
      conn =
        api_conn(:post, "/links", %{
          domain: "test.link",
          key: "promo",
          url: "https://example.com/sale"
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["domain"] == "test.link"
      assert body["key"] == "promo"
      assert body["id"]
    end

    test "returns 409 for duplicate domain/key" do
      create_link!(%{domain: "test.link", key: "dup"})

      conn =
        api_conn(:post, "/links", %{
          domain: "test.link",
          key: "dup",
          url: "https://example.com"
        })

      assert conn.status == 409
    end

    test "returns 422 for missing required fields" do
      conn = api_conn(:post, "/links", %{domain: "test.link"})

      assert conn.status == 422
    end
  end

  describe "GET /links" do
    test "lists links for workspace" do
      create_link!(%{key: "a1"})
      create_link!(%{key: "a2"})

      conn = api_conn(:get, "/links")

      assert conn.status == 200
      body = json_body(conn)
      assert length(body) >= 2
    end

    test "supports pagination" do
      for i <- 1..5, do: create_link!(%{key: "pg#{i}"})

      conn = api_conn(:get, "/links?limit=2&offset=0")

      assert conn.status == 200
      assert length(json_body(conn)) == 2
    end
  end

  describe "GET /links/:id" do
    test "returns link by id" do
      link = create_link!()

      conn = api_conn(:get, "/links/#{link.id}")

      assert conn.status == 200
      assert json_body(conn)["id"] == link.id
    end

    test "returns 404 for non-existent link" do
      conn = api_conn(:get, "/links/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end

    test "returns 404 for link in different workspace" do
      link = create_link!(%{workspace_id: Ecto.UUID.generate()})

      conn = api_conn(:get, "/links/#{link.id}")
      assert conn.status == 404
    end
  end

  describe "PATCH /links/:id" do
    test "updates link attributes" do
      link = create_link!()

      conn = api_conn(:patch, "/links/#{link.id}", %{url: "https://new-destination.com"})

      assert conn.status == 200
      assert json_body(conn)["url"] == "https://new-destination.com"
    end

    test "returns 404 for non-existent link" do
      conn = api_conn(:patch, "/links/#{Ecto.UUID.generate()}", %{url: "https://new.com"})
      assert conn.status == 404
    end
  end

  describe "DELETE /links/:id" do
    test "archives a link" do
      link = create_link!()

      conn = api_conn(:delete, "/links/#{link.id}")
      assert conn.status == 204

      # Archived links still exist but get_link/2 doesn't filter archived,
      # so we check via list (which excludes archived).
      conn2 = api_conn(:get, "/links")
      links = json_body(conn2)
      refute Enum.any?(links, &(&1["id"] == link.id))
    end

    test "returns 404 for non-existent link" do
      conn = api_conn(:delete, "/links/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end
  end

  describe "GET /links/:link_id/stats" do
    test "returns link stats" do
      link = create_link!()

      conn = api_conn(:get, "/links/#{link.id}/stats")

      assert conn.status == 200
      body = json_body(conn)
      assert body["total_clicks"] == 0
      assert body["unique_clicks"] == 0
    end

    test "returns 404 for non-existent link" do
      conn = api_conn(:get, "/links/#{Ecto.UUID.generate()}/stats")
      assert conn.status == 404
    end
  end

  describe "GET /links/:link_id/clicks" do
    test "returns click events" do
      link = create_link!()

      conn = api_conn(:get, "/links/#{link.id}/clicks")

      assert conn.status == 200
      assert json_body(conn) == []
    end

    test "returns 404 for non-existent link" do
      conn = api_conn(:get, "/links/#{Ecto.UUID.generate()}/clicks")
      assert conn.status == 404
    end
  end
end
