defmodule GoodAnalytics.Api.PartnerControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Api.Router
  alias GoodAnalytics.Core.Partners

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

  defp create_partner!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          key: "partner-#{System.unique_integer([:positive])}",
          name: "Test Partner #{System.unique_integer([:positive])}",
          status: "active"
        },
        attrs
      )

    {:ok, partner} = Partners.create_partner(attrs)
    partner
  end

  describe "POST /partners" do
    test "creates a partner and returns 201" do
      conn =
        api_conn(:post, "/partners", %{
          key: "acme-corp",
          name: "Acme Corporation"
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["id"]
      assert body["key"] == "acme-corp"
      assert body["name"] == "Acme Corporation"
      assert body["status"] == "active"
      assert body["workspace_id"] == @workspace_id
    end

    test "returns 409 for duplicate key" do
      create_partner!(%{key: "dup-key"})

      conn =
        api_conn(:post, "/partners", %{
          key: "dup-key",
          name: "Another Partner"
        })

      assert conn.status == 409
      body = json_body(conn)
      assert body["error"] =~ "key"
    end

    test "returns 409 for duplicate external_id with distinct message" do
      create_partner!(%{key: "first-partner", external_id: "ext-123"})

      conn =
        api_conn(:post, "/partners", %{
          key: "second-partner",
          name: "Second Partner",
          external_id: "ext-123"
        })

      assert conn.status == 409
      body = json_body(conn)
      assert body["error"] =~ "external_id"
    end

    test "returns 422 for missing required fields" do
      conn = api_conn(:post, "/partners", %{name: "No Key Partner"})

      assert conn.status == 422
    end

    test "creates a partner with optional external_id and metadata" do
      conn =
        api_conn(:post, "/partners", %{
          key: "partner-with-extras",
          name: "Extras Partner",
          external_id: "ext-abc",
          metadata: %{"tier" => "gold"}
        })

      assert conn.status == 201
      body = json_body(conn)
      assert body["external_id"] == "ext-abc"
      assert body["metadata"] == %{"tier" => "gold"}
    end
  end

  describe "GET /partners" do
    test "returns 200 with list scoped to workspace" do
      create_partner!(%{key: "list-a"})
      create_partner!(%{key: "list-b"})

      conn = api_conn(:get, "/partners")

      assert conn.status == 200
      body = json_body(conn)
      assert is_list(body)
      assert length(body) >= 2
      assert Enum.all?(body, &(&1["workspace_id"] == @workspace_id))
    end

    test "does not return partners from a different workspace" do
      other_workspace_id = Ecto.UUID.generate()

      {:ok, _} =
        Partners.create_partner(%{
          workspace_id: other_workspace_id,
          key: "other-ws-partner",
          name: "Other WS Partner"
        })

      create_partner!(%{key: "my-ws-partner"})

      conn = api_conn(:get, "/partners")

      assert conn.status == 200
      body = json_body(conn)
      keys = Enum.map(body, & &1["key"])
      assert "my-ws-partner" in keys
      refute "other-ws-partner" in keys
    end
  end

  describe "GET /partners/:id" do
    test "returns 200 with the partner" do
      partner = create_partner!()

      conn = api_conn(:get, "/partners/#{partner.id}")

      assert conn.status == 200
      assert json_body(conn)["id"] == partner.id
    end

    test "returns 404 for non-existent partner" do
      conn = api_conn(:get, "/partners/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end

    test "returns 404 for partner belonging to another workspace" do
      other_workspace_id = Ecto.UUID.generate()

      {:ok, other_partner} =
        Partners.create_partner(%{
          workspace_id: other_workspace_id,
          key: "other-partner",
          name: "Other Partner"
        })

      conn = api_conn(:get, "/partners/#{other_partner.id}")
      assert conn.status == 404
    end
  end

  describe "PATCH /partners/:id" do
    test "updates partner attributes and returns 200" do
      partner = create_partner!(%{name: "Original Name"})

      conn = api_conn(:patch, "/partners/#{partner.id}", %{name: "Updated Name"})

      assert conn.status == 200
      assert json_body(conn)["name"] == "Updated Name"
    end

    test "updates partner status" do
      partner = create_partner!(%{status: "active"})

      conn = api_conn(:patch, "/partners/#{partner.id}", %{status: "disabled"})

      assert conn.status == 200
      assert json_body(conn)["status"] == "disabled"
    end

    test "returns 404 for non-existent partner" do
      conn = api_conn(:patch, "/partners/#{Ecto.UUID.generate()}", %{name: "Ghost"})
      assert conn.status == 404
    end

    test "returns 422 for validation errors" do
      partner = create_partner!()

      conn = api_conn(:patch, "/partners/#{partner.id}", %{status: "invalid-status"})

      assert conn.status == 422
    end
  end

  describe "DELETE /partners/:id" do
    test "archives the partner and returns 204" do
      partner = create_partner!()

      conn = api_conn(:delete, "/partners/#{partner.id}")
      assert conn.status == 204

      # Archived partners are excluded from the list
      list_conn = api_conn(:get, "/partners")
      listed_ids = list_conn |> json_body() |> Enum.map(& &1["id"])
      refute partner.id in listed_ids
    end

    test "returns 404 for non-existent partner" do
      conn = api_conn(:delete, "/partners/#{Ecto.UUID.generate()}")
      assert conn.status == 404
    end
  end
end
