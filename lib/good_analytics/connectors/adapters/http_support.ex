defmodule GoodAnalytics.Connectors.Adapters.HTTPSupport do
  @moduledoc false

  # Shared HTTP and error-classification helpers for connector adapters.

  alias GoodAnalytics.Connectors.HTTP

  @doc """
  Issues a POST request to `url` with `headers` and `payload`, returning the
  standardized `{:ok, response} | {:error, reason}` tuple used by every adapter.
  """
  def post(url, headers, payload) do
    case HTTP.request(:post, url, headers, payload) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, response} ->
        {:error, response}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Classifies a delivery error response into one of `:rate_limited`, `:credential`,
  `:permanent`, or `:transient`.
  """
  def classify_error(%{status: 429}), do: :rate_limited
  def classify_error(%{status: status}) when status in [401, 403], do: :credential
  def classify_error(%{status: status}) when status >= 400 and status < 500, do: :permanent
  def classify_error(_), do: :transient

  @max_payload_bytes 1_000_000

  @doc "Returns `:ok` if the JSON-encoded payload fits within the size limit, else `{:error, :payload_too_large}`."
  def validate_payload_size(payload) do
    size = payload |> Jason.encode!() |> byte_size()
    if size <= @max_payload_bytes, do: :ok, else: {:error, :payload_too_large}
  end

  @doc """
  Returns a Unix timestamp (in seconds) derived from the `captured_at` field of
  the given source context map, falling back to the current system time.
  """
  def unix_timestamp(source_context) do
    case Map.get(source_context, "captured_at") do
      nil ->
        System.os_time(:second)

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> DateTime.to_unix(dt)
          _ -> System.os_time(:second)
        end
    end
  end
end
