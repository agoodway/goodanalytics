defmodule GoodAnalytics.Api.AuthPlug do
  @moduledoc """
  Authenticates API requests via a host-app-provided callback.

  Extracts a Bearer token or API key from request headers, invokes the
  configured `:api_authenticate` callback, and assigns `workspace_id`
  and `auth_context` to the connection on success.

  ## Configuration

      config :good_analytics, :api_authenticate, {MyApp.Auth, :authenticate_ga_api}

  The callback must be arity-2: `(token, type)` where `type` is `:bearer`
  or `:api_key`. It must return `{:ok, %{workspace_id: uuid, ...}}` on
  success or `{:error, reason}` on failure.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_auth_callback() do
      nil ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "API authentication is not configured"}))
        |> halt()

      callback ->
        conn
        |> extract_credentials()
        |> authenticate(callback)
    end
  end

  defp get_auth_callback do
    Application.get_env(:good_analytics, :api_authenticate)
  end

  defp extract_credentials(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 ->
        {conn, String.trim(token), :bearer}

      [<<"Bearer">> | _] ->
        {conn, nil, :malformed}

      _ ->
        case get_req_header(conn, "x-api-key") do
          [key] when byte_size(key) > 0 ->
            {conn, key, :api_key}

          _ ->
            {conn, nil, :missing}
        end
    end
  end

  defp authenticate({conn, nil, :missing}, _callback) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Missing authentication credentials"}))
    |> halt()
  end

  defp authenticate({conn, nil, :malformed}, _callback) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Malformed Authorization header"}))
    |> halt()
  end

  defp authenticate({conn, token, type}, callback) do
    case invoke_callback(callback, token, type) do
      {:ok, %{workspace_id: workspace_id} = context} ->
        conn
        |> assign(:workspace_id, workspace_id)
        |> assign(:auth_context, context)

      {:error, :forbidden} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))
        |> halt()

      {:error, message} when is_binary(message) ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: message}))
        |> halt()

      {:error, _reason} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
        |> halt()
    end
  end

  defp invoke_callback({module, function}, token, type) do
    apply(module, function, [token, type])
  end

  defp invoke_callback(fun, token, type) when is_function(fun, 2) do
    fun.(token, type)
  end
end
