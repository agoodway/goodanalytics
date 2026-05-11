defmodule GoodAnalytics.Connectors.HTTP.ReqAdapter do
  @moduledoc """
  Req-based HTTP adapter for connector delivery.

  This is the default production adapter. It uses `Req` for HTTP calls
  with JSON encoding/decoding and configurable timeouts.
  """

  @behaviour GoodAnalytics.Connectors.HTTP

  @default_timeout 30_000

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    req_opts =
      [
        method: method,
        url: url,
        headers: headers,
        receive_timeout: timeout,
        connect_options: [timeout: timeout]
      ]
      |> maybe_add_body(body, method)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: resp_body, headers: resp_headers}} ->
        {:ok,
         %{
           status: status,
           body: resp_body,
           headers: Map.to_list(resp_headers)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_add_body(opts, nil, _method), do: opts

  defp maybe_add_body(opts, body, method) when method in [:post, :put, :patch] do
    Keyword.put(opts, :json, body)
  end

  defp maybe_add_body(opts, _body, _method), do: opts
end
