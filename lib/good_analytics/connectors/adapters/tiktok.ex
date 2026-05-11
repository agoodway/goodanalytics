defmodule GoodAnalytics.Connectors.Adapters.TikTok do
  @moduledoc """
  TikTok Events API connector adapter.

  Supports lead and sale conversions via the TikTok Marketing API.
  Required signals: `ttclid`.
  """

  @behaviour GoodAnalytics.Connectors.Connector

  alias GoodAnalytics.Connectors.Adapters.HTTPSupport

  @impl true
  def connector_type, do: :tiktok

  @impl true
  def supported_event_types, do: [:lead, :sale]

  @impl true
  def required_signals, do: [["ttclid"]]

  @impl true
  def credential_keys, do: ["access_token", "pixel_code"]

  @impl true
  def build_payload(dispatch, credentials) do
    source_context = dispatch.source_context
    signals = Map.get(source_context, "signals", %{})

    event_name =
      case Map.get(source_context, "event_type") do
        "lead" -> "SubmitForm"
        "sale" -> "CompletePayment"
        other -> other
      end

    event = %{
      "event" => event_name,
      "event_id" => dispatch.connector_event_id,
      "event_time" => HTTPSupport.unix_timestamp(source_context),
      "user" => %{
        "ttclid" => signals["ttclid"]
      },
      "page" => %{
        "url" => sanitize_url(Map.get(source_context, "url", ""))
      }
    }

    event =
      case Map.get(source_context, "amount_cents") do
        nil ->
          event

        cents ->
          Map.put(event, "properties", %{
            "value" => cents / 100,
            "currency" => Map.get(source_context, "currency", "USD"),
            "contents" => []
          })
      end

    payload = %{
      "pixel_code" => credentials["pixel_code"],
      "event_source" => "web",
      "event_source_id" => credentials["pixel_code"],
      "data" => [event]
    }

    {:ok, payload}
  end

  @impl true
  def deliver(payload, credentials) do
    access_token = credentials["access_token"]

    url = "https://business-api.tiktok.com/open_api/v1.3/event/track/"

    headers = [
      {"content-type", "application/json"},
      {"access-token", access_token}
    ]

    HTTPSupport.post(url, headers, payload)
  end

  @impl true
  defdelegate classify_error(response), to: HTTPSupport

  @impl true
  defdelegate validate_payload_size(payload), to: HTTPSupport

  defp sanitize_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> url
      _ -> ""
    end
  end

  defp sanitize_url(_), do: ""
end
