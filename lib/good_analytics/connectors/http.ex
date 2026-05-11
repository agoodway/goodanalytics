defmodule GoodAnalytics.Connectors.HTTP do
  @moduledoc """
  Behaviour-based HTTP adapter for connector delivery.

  Connectors use this adapter to make HTTP calls. In production, Req is used.
  In tests, Mimic stubs the adapter for deterministic responses.

  ## Configuration

      config :good_analytics, :http_adapter, GoodAnalytics.Connectors.HTTP.ReqAdapter

  """

  @type method :: :get | :post | :put | :patch | :delete
  @type url :: String.t()
  @type headers :: [{String.t(), String.t()}]
  @type body :: String.t() | map()
  @type response :: %{status: integer(), body: term(), headers: [{String.t(), String.t()}]}

  # The @callback shares name/arity with the delegating function below.
  # @doc false prevents doctor from counting this :none-doc entry against the
  # function's documentation coverage.
  @doc false
  @callback request(method(), url(), headers(), body(), keyword()) ::
              {:ok, response()} | {:error, term()}

  @doc "Makes an HTTP request using the configured adapter."
  @spec request(method(), url(), headers(), body(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(method, url, headers \\ [], body \\ nil, opts \\ []) do
    adapter().request(method, url, headers, body, opts)
  end

  defp adapter do
    Application.get_env(
      :good_analytics,
      :http_adapter,
      GoodAnalytics.Connectors.HTTP.ReqAdapter
    )
  end
end
