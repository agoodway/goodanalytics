defmodule GoodAnalytics.Connectors.AdaptersTest do
  use ExUnit.Case, async: true

  import GoodAnalytics.TestHelpers

  alias GoodAnalytics.Connectors.Adapters.{Google, LinkedIn, Meta, TikTok}

  defp dispatch do
    ts = utc_now()

    %{
      id: "dispatch-1",
      workspace_id: "00000000-0000-0000-0000-000000000000",
      connector_event_id: "meta_abc123",
      event_id: "event-1",
      event_inserted_at: ts,
      visitor_id: "visitor-1",
      source_context: %{
        "signals" => %{
          "_fbp" => "fb.1.1234567890.1234567890",
          "_fbc" => "fb.1.1234567890.abc123",
          "fbclid" => "click_abc",
          "gclid" => "google_click_1",
          "li_fat_id" => "li_uuid_1",
          "ttclid" => "tiktok_click_1"
        },
        "event_type" => "lead",
        "amount_cents" => 4900,
        "currency" => "USD",
        "captured_at" => DateTime.to_iso8601(ts)
      }
    }
  end

  # ── Meta ──

  describe "Meta adapter" do
    test "connector_type is :meta" do
      assert Meta.connector_type() == :meta
    end

    test "supports lead and sale" do
      assert :lead in Meta.supported_event_types()
      assert :sale in Meta.supported_event_types()
    end

    test "requires _fbp, _fbc, or fbclid" do
      assert Meta.required_signals() == [["_fbp", "_fbc", "fbclid"]]
    end

    test "builds payload with user data and event" do
      creds = %{"access_token" => "token", "pixel_id" => "123"}
      {:ok, payload} = Meta.build_payload(dispatch(), creds)

      assert payload["pixel_id"] == "123"
      [event] = payload["data"]
      assert event["event_name"] == "Lead"
      assert event["action_source"] == "website"
      assert event["event_id"] == "meta_abc123"
      assert event["user_data"]["fbp"] == "fb.1.1234567890.1234567890"
      assert event["custom_data"]["value"] == 49.0
    end

    test "builds sale payload" do
      dispatch = put_in(dispatch().source_context["event_type"], "sale")
      {:ok, payload} = Meta.build_payload(dispatch, %{"pixel_id" => "px"})
      [event] = payload["data"]
      assert event["event_name"] == "Purchase"
    end

    test "builds custom payload with mapped connector event name" do
      dispatch =
        custom_dispatch(:meta, %{"connector_event_name" => "StartTrial", "config" => %{}})

      {:ok, payload} = Meta.build_payload(dispatch, %{"pixel_id" => "px"})
      [event] = payload["data"]
      assert event["event_name"] == "StartTrial"
    end

    test "returns an error when a custom Meta mapping has no connector event name" do
      dispatch = custom_dispatch(:meta, %{"connector_event_name" => nil, "config" => %{}})

      assert {:error, :missing_event_mapping} =
               Meta.build_payload(dispatch, %{"pixel_id" => "px"})
    end

    test "classifies errors correctly" do
      assert Meta.classify_error(%{status: 429}) == :rate_limited
      assert Meta.classify_error(%{status: 401}) == :credential
      assert Meta.classify_error(%{status: 403}) == :credential
      assert Meta.classify_error(%{status: 400}) == :permanent
      assert Meta.classify_error(%{status: 500}) == :transient
    end

    test "validates payload size" do
      assert Meta.validate_payload_size(%{"small" => "data"}) == :ok
    end
  end

  # ── Google ──

  describe "Google adapter" do
    test "connector_type is :google" do
      assert Google.connector_type() == :google
    end

    test "supports lead and sale" do
      assert :lead in Google.supported_event_types()
      assert :sale in Google.supported_event_types()
    end

    test "requires gclid, gbraid, or wbraid" do
      assert Google.required_signals() == [["gclid", "gbraid", "wbraid"]]
    end

    test "builds payload with conversion action" do
      creds = %{
        "customer_id" => "cust123",
        "conversion_action_id" => "action456",
        "access_token" => "token"
      }

      {:ok, payload} = Google.build_payload(dispatch(), creds)
      [conversion] = payload["conversions"]
      assert String.contains?(conversion["conversionAction"], "cust123")
      assert String.contains?(conversion["conversionAction"], "action456")
      assert conversion["gclid"] == "google_click_1"
      assert conversion["conversionValue"] == 49.0
    end

    test "builds custom payload with mapped conversion action" do
      dispatch =
        custom_dispatch(:google, %{
          "connector_event_name" => nil,
          "config" => %{"conversion_action_id" => "mapped123"}
        })

      {:ok, payload} = Google.build_payload(dispatch, %{"customer_id" => "cust123"})
      [conversion] = payload["conversions"]
      assert String.contains?(conversion["conversionAction"], "mapped123")
    end

    test "returns an error when custom Google mapping config is missing" do
      dispatch = custom_dispatch(:google, %{"connector_event_name" => nil, "config" => %{}})

      assert {:error, :missing_conversion_action_id} =
               Google.build_payload(dispatch, %{"customer_id" => "cust123"})
    end

    test "classifies errors correctly" do
      assert Google.classify_error(%{status: 429}) == :rate_limited
      assert Google.classify_error(%{status: 401}) == :credential
      assert Google.classify_error(%{status: 400}) == :permanent
      assert Google.classify_error(%{status: 500}) == :transient
    end
  end

  # ── LinkedIn ──

  describe "LinkedIn adapter" do
    test "connector_type is :linkedin" do
      assert LinkedIn.connector_type() == :linkedin
    end

    test "requires li_fat_id" do
      assert LinkedIn.required_signals() == [["li_fat_id"]]
    end

    test "builds payload with conversion rule" do
      creds = %{
        "access_token" => "token",
        "conversion_rule_id" => "rule789",
        "ad_account_id" => "acct123"
      }

      {:ok, payload} = LinkedIn.build_payload(dispatch(), creds)
      [element] = payload["elements"]
      assert String.contains?(element["conversion"], "rule789")
      [user_id] = element["user"]["userIds"]
      assert user_id["idValue"] == "li_uuid_1"
    end

    test "builds custom payload with mapped conversion rule" do
      dispatch =
        custom_dispatch(:linkedin, %{
          "connector_event_name" => nil,
          "config" => %{"conversion_rule_id" => "mapped-rule"}
        })

      {:ok, payload} = LinkedIn.build_payload(dispatch, %{})
      [element] = payload["elements"]
      assert String.contains?(element["conversion"], "mapped-rule")
    end

    test "returns an error when custom LinkedIn mapping config is missing" do
      dispatch = custom_dispatch(:linkedin, %{"connector_event_name" => nil, "config" => %{}})

      assert {:error, :missing_conversion_rule_id} = LinkedIn.build_payload(dispatch, %{})
    end

    test "classifies errors correctly" do
      assert LinkedIn.classify_error(%{status: 429}) == :rate_limited
      assert LinkedIn.classify_error(%{status: 401}) == :credential
      assert LinkedIn.classify_error(%{status: 400}) == :permanent
      assert LinkedIn.classify_error(%{status: 500}) == :transient
    end
  end

  # ── TikTok ──

  describe "TikTok adapter" do
    test "connector_type is :tiktok" do
      assert TikTok.connector_type() == :tiktok
    end

    test "requires ttclid" do
      assert TikTok.required_signals() == [["ttclid"]]
    end

    test "builds payload with pixel code" do
      creds = %{"access_token" => "token", "pixel_code" => "px123"}
      {:ok, payload} = TikTok.build_payload(dispatch(), creds)

      assert payload["pixel_code"] == "px123"
      [event] = payload["data"]
      assert event["event"] == "SubmitForm"
      assert event["user"]["ttclid"] == "tiktok_click_1"
    end

    test "builds sale payload" do
      dispatch = put_in(dispatch().source_context["event_type"], "sale")
      {:ok, payload} = TikTok.build_payload(dispatch, %{"pixel_code" => "px"})
      [event] = payload["data"]
      assert event["event"] == "CompletePayment"
      assert event["properties"]["value"] == 49.0
    end

    test "builds custom payload with mapped connector event name" do
      dispatch =
        custom_dispatch(:tiktok, %{
          "connector_event_name" => "CompleteRegistration",
          "config" => %{}
        })

      {:ok, payload} = TikTok.build_payload(dispatch, %{"pixel_code" => "px"})
      [event] = payload["data"]
      assert event["event"] == "CompleteRegistration"
    end

    test "returns an error when a custom TikTok mapping has no connector event name" do
      dispatch = custom_dispatch(:tiktok, %{"connector_event_name" => nil, "config" => %{}})

      assert {:error, :missing_event_mapping} =
               TikTok.build_payload(dispatch, %{"pixel_code" => "px"})
    end

    test "classifies errors correctly" do
      assert TikTok.classify_error(%{status: 429}) == :rate_limited
      assert TikTok.classify_error(%{status: 401}) == :credential
      assert TikTok.classify_error(%{status: 400}) == :permanent
      assert TikTok.classify_error(%{status: 500}) == :transient
    end
  end

  defp custom_dispatch(connector_type, mapping) do
    dispatch = dispatch()

    %{
      dispatch
      | connector_event_id: "#{connector_type}_custom_abc123",
        source_context:
          Map.merge(dispatch.source_context, %{
            "event_type" => "custom",
            "event_name" => "trial_started",
            "mapping" =>
              Map.merge(
                %{
                  "id" => "mapping-1",
                  "event_type" => "custom",
                  "event_name" => "trial_started"
                },
                mapping
              )
          })
    }
  end
end
