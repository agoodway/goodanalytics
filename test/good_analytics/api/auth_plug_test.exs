defmodule GoodAnalytics.Api.AuthPlugTest do
  use GoodAnalytics.DataCase

  alias GoodAnalytics.Api.AuthPlug

  @workspace_id GoodAnalytics.default_workspace_id()

  defp build_conn do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end

  defp run_plug(conn) do
    AuthPlug.call(conn, AuthPlug.init([]))
  end

  defp with_auth_config(callback) do
    Application.put_env(:good_analytics, :api_authenticate, callback)
    on_exit(fn -> Application.delete_env(:good_analytics, :api_authenticate) end)
  end

  describe "Bearer token authentication" do
    test "authenticates with valid bearer token" do
      with_auth_config(fn token, type ->
        assert token == "valid-token"
        assert type == :bearer
        {:ok, %{workspace_id: @workspace_id}}
      end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer valid-token")
        |> run_plug()

      refute conn.halted
      assert conn.assigns.workspace_id == @workspace_id
      assert conn.assigns.auth_context == %{workspace_id: @workspace_id}
    end

    test "returns 401 for invalid bearer token" do
      with_auth_config(fn _token, _type -> {:error, :unauthorized} end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer bad-token")
        |> run_plug()

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "Unauthorized"
    end
  end

  describe "API key authentication" do
    test "authenticates with valid API key" do
      with_auth_config(fn key, type ->
        assert key == "my-api-key"
        assert type == :api_key
        {:ok, %{workspace_id: @workspace_id, user_id: "user-1"}}
      end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("x-api-key", "my-api-key")
        |> run_plug()

      refute conn.halted
      assert conn.assigns.workspace_id == @workspace_id
    end
  end

  describe "missing credentials" do
    test "returns 401 when no auth headers present" do
      with_auth_config(fn _t, _ty -> {:ok, %{workspace_id: @workspace_id}} end)

      conn = build_conn() |> run_plug()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "no auth hook configured" do
    test "returns 503 when :api_authenticate is not set" do
      Application.delete_env(:good_analytics, :api_authenticate)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer token")
        |> run_plug()

      assert conn.halted
      assert conn.status == 503
      assert Jason.decode!(conn.resp_body)["error"] =~ "not configured"
    end
  end

  describe "error handling" do
    test "returns 403 for forbidden" do
      with_auth_config(fn _t, _ty -> {:error, :forbidden} end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer token")
        |> run_plug()

      assert conn.halted
      assert conn.status == 403
    end

    test "returns 401 with custom error message" do
      with_auth_config(fn _t, _ty -> {:error, "Token expired"} end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer token")
        |> run_plug()

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body)["error"] == "Token expired"
    end

    test "returns 401 for unrecognized error atoms" do
      with_auth_config(fn _t, _ty -> {:error, :expired} end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer token")
        |> run_plug()

      assert conn.halted
      assert conn.status == 401
    end

    test "returns 401 for malformed Authorization header" do
      with_auth_config(fn _t, _ty -> {:ok, %{workspace_id: @workspace_id}} end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Token abc")
        |> run_plug()

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "bearer takes precedence" do
    test "uses bearer when both headers present" do
      with_auth_config(fn token, type ->
        assert type == :bearer
        assert token == "bearer-token"
        {:ok, %{workspace_id: @workspace_id}}
      end)

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer bearer-token")
        |> Plug.Conn.put_req_header("x-api-key", "api-key")
        |> run_plug()

      refute conn.halted
    end
  end

  describe "MFA configuration" do
    defmodule TestAuth do
      def authenticate(token, type) do
        send(self(), {:auth_called, token, type})
        {:ok, %{workspace_id: GoodAnalytics.default_workspace_id()}}
      end
    end

    test "calls {module, function} tuple" do
      with_auth_config({TestAuth, :authenticate})

      conn =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer mfa-token")
        |> run_plug()

      refute conn.halted
      assert_received {:auth_called, "mfa-token", :bearer}
    end
  end
end
