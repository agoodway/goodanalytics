defmodule GoodAnalytics.Connectors.Adapters.LinkedIn do
  @moduledoc """
  LinkedIn Conversions API connector adapter.

  Supports lead and sale conversions via the LinkedIn Marketing API.
  Required signals: `li_fat_id`.
  """

  @behaviour GoodAnalytics.Connectors.Connector

  alias GoodAnalytics.Connectors.Adapters.HTTPSupport

  @impl true
  def connector_type, do: :linkedin

  @impl true
  def supported_event_types, do: [:lead, :sale]

  @impl true
  def required_signals, do: [["li_fat_id"]]

  @impl true
  def credential_keys, do: ["access_token", "conversion_rule_id", "ad_account_id"]

  @impl true
  def build_payload(dispatch, credentials) do
    source_context = dispatch.source_context
    signals = Map.get(source_context, "signals", %{})
    conversion_rule_id = conversion_rule_id(source_context, credentials)

    if is_nil(conversion_rule_id) do
      {:error, :missing_conversion_rule_id}
    else
      build_payload_with_conversion_rule(dispatch, source_context, signals, conversion_rule_id)
    end
  end

  defp build_payload_with_conversion_rule(dispatch, source_context, signals, conversion_rule_id) do
    conversion = %{
      "conversion" => "urn:lla:llaPartnerConversion:#{conversion_rule_id}",
      "conversionHappenedAt" => unix_ms_timestamp(source_context),
      "eventId" => dispatch.connector_event_id,
      "user" => %{
        "userIds" => [
          %{
            "idType" => "LINKEDIN_FIRST_PARTY_ADS_TRACKING_UUID",
            "idValue" => signals["li_fat_id"]
          }
        ]
      }
    }

    conversion =
      case Map.get(source_context, "amount_cents") do
        nil ->
          conversion

        cents ->
          Map.put(conversion, "conversionValue", %{
            "currencyCode" => Map.get(source_context, "currency", "USD"),
            "amount" => Integer.to_string(cents)
          })
      end

    payload = %{
      "elements" => [conversion]
    }

    {:ok, payload}
  end

  defp conversion_rule_id(%{"event_type" => "custom"} = source_context, _credentials) do
    source_context
    |> get_in(["mapping", "config", "conversion_rule_id"])
    |> HTTPSupport.blank_to_nil()
  end

  defp conversion_rule_id(_source_context, credentials) do
    credentials["conversion_rule_id"] |> HTTPSupport.blank_to_nil()
  end

  @impl true
  def deliver(payload, credentials) do
    access_token = credentials["access_token"]

    url = "https://api.linkedin.com/rest/conversionEvents"

    headers = [
      {"content-type", "application/json"},
      {"authorization", "Bearer #{access_token}"},
      {"linkedin-version", "202404"},
      {"x-restli-protocol-version", "2.0.0"}
    ]

    HTTPSupport.post(url, headers, payload)
  end

  @impl true
  defdelegate classify_error(response), to: HTTPSupport

  @impl true
  defdelegate validate_payload_size(payload), to: HTTPSupport

  defp unix_ms_timestamp(source_context) do
    case Map.get(source_context, "captured_at") do
      nil ->
        System.os_time(:millisecond)

      iso ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
          _ -> System.os_time(:millisecond)
        end
    end
  end
end
