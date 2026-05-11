defmodule GoodAnalytics.Connectors.Adapters.Google do
  @moduledoc """
  Google Ads offline conversions connector adapter.

  Supports lead and sale conversions via the Google Ads API.
  Required signals: at least one of `gclid`, `gbraid`, or `wbraid`.
  """

  @behaviour GoodAnalytics.Connectors.Connector

  alias GoodAnalytics.Connectors.Adapters.HTTPSupport

  @impl true
  def connector_type, do: :google

  @impl true
  def supported_event_types, do: [:lead, :sale]

  @impl true
  def required_signals, do: [["gclid", "gbraid", "wbraid"]]

  @impl true
  def credential_keys,
    do: ["customer_id", "conversion_action_id", "access_token", "developer_token"]

  @impl true
  def build_payload(dispatch, credentials) do
    source_context = dispatch.source_context
    signals = Map.get(source_context, "signals", %{})

    conversion = %{
      "conversionAction" =>
        "customers/#{credentials["customer_id"]}/conversionActions/#{credentials["conversion_action_id"]}",
      "conversionDateTime" => format_google_timestamp(source_context),
      "orderId" => dispatch.connector_event_id
    }

    conversion =
      conversion
      |> maybe_put("gclid", signals["gclid"])
      |> maybe_put("gbraid", signals["gbraid"])
      |> maybe_put("wbraid", signals["wbraid"])

    conversion =
      case Map.get(source_context, "amount_cents") do
        nil ->
          conversion

        cents ->
          Map.merge(conversion, %{
            "conversionValue" => cents / 100,
            "currencyCode" => Map.get(source_context, "currency", "USD")
          })
      end

    payload = %{
      "conversions" => [conversion],
      "partialFailure" => true
    }

    {:ok, payload}
  end

  @impl true
  def deliver(payload, credentials) do
    customer_id = credentials["customer_id"]
    access_token = credentials["access_token"]

    url =
      "https://googleads.googleapis.com/v18/customers/#{customer_id}:uploadClickConversions"

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{access_token}"},
      {"developer-token", credentials["developer_token"]}
    ]

    HTTPSupport.post(url, headers, payload)
  end

  @impl true
  defdelegate classify_error(response), to: HTTPSupport

  @impl true
  defdelegate validate_payload_size(payload), to: HTTPSupport

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp format_google_timestamp(source_context) do
    dt =
      case Map.get(source_context, "captured_at") do
        nil ->
          DateTime.utc_now()

        iso ->
          case DateTime.from_iso8601(iso) do
            {:ok, dt, _offset} -> dt
            _ -> DateTime.utc_now()
          end
      end

    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S+00:00")
  end
end
