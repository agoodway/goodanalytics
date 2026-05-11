defmodule GoodAnalytics.Connectors.Adapters.Meta do
  @moduledoc """
  Meta Conversions API (CAPI) connector adapter.

  Supports lead and sale conversions via the Meta Marketing API.
  Required signals: at least one of `_fbp`, `_fbc`, or `fbclid`.
  """

  @behaviour GoodAnalytics.Connectors.Connector

  alias GoodAnalytics.Connectors.Adapters.HTTPSupport

  @impl true
  def connector_type, do: :meta

  @impl true
  def supported_event_types, do: [:lead, :sale]

  @impl true
  def required_signals, do: [["_fbp", "_fbc", "fbclid"]]

  @impl true
  def credential_keys, do: ["access_token", "pixel_id"]

  @impl true
  def build_payload(dispatch, credentials) do
    source_context = dispatch.source_context
    signals = Map.get(source_context, "signals", %{})

    event_name =
      case Map.get(source_context, "event_type") do
        "lead" -> "Lead"
        "sale" -> "Purchase"
        other -> other
      end

    user_data =
      %{}
      |> maybe_put("fbp", signals["_fbp"])
      |> maybe_put("fbc", signals["_fbc"])
      |> maybe_put("fbclid", signals["fbclid"])

    event_data = %{
      "event_name" => event_name,
      "event_time" => HTTPSupport.unix_timestamp(source_context),
      "event_id" => dispatch.connector_event_id,
      "action_source" => "website",
      "user_data" => user_data
    }

    event_data =
      case Map.get(source_context, "amount_cents") do
        nil ->
          event_data

        cents ->
          Map.merge(event_data, %{
            "custom_data" => %{
              "value" => cents / 100,
              "currency" => Map.get(source_context, "currency", "USD")
            }
          })
      end

    payload = %{
      "data" => [event_data],
      "pixel_id" => credentials["pixel_id"]
    }

    {:ok, payload}
  end

  @impl true
  def deliver(payload, credentials) do
    pixel_id = payload["pixel_id"]
    access_token = credentials["access_token"]
    url = "https://graph.facebook.com/v21.0/#{pixel_id}/events"

    body = Map.delete(payload, "pixel_id")

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{access_token}"}
    ]

    HTTPSupport.post(url, headers, body)
  end

  @impl true
  defdelegate classify_error(response), to: HTTPSupport

  @impl true
  defdelegate validate_payload_size(payload), to: HTTPSupport

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
