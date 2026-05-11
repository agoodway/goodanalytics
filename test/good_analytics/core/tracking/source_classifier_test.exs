defmodule GoodAnalytics.Core.Tracking.SourceClassifierTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Tracking.SourceClassifier

  describe "classify/2 with click IDs" do
    test "detects gclid as google_ads paid" do
      result = classify_params(%{"gclid" => "Cj0KCQ..."})
      assert result.platform == :google_ads
      assert result.medium == :paid
      assert result.click_id_type == "gclid"
      assert result.click_id_value == "Cj0KCQ..."
      assert result.confidence == :high
    end

    test "detects fbclid as meta social" do
      result = classify_params(%{"fbclid" => "IwAR2X..."})
      assert result.platform == :meta
      assert result.medium == :social
    end

    test "detects msclkid as microsoft_ads paid" do
      result = classify_params(%{"msclkid" => "abc123"})
      assert result.platform == :microsoft_ads
      assert result.medium == :paid
    end

    test "captures all click IDs present" do
      params = %{"gclid" => "g_val", "fbclid" => "fb_val"}
      result = classify_params(params)
      assert result.captured_click_ids == %{"gclid" => "g_val", "fbclid" => "fb_val"}
    end

    test "click ID takes priority over UTM" do
      params = %{
        "gclid" => "g_val",
        "utm_source" => "newsletter",
        "utm_medium" => "email"
      }

      result = classify_params(params)
      # Click ID overrides UTM platform
      assert result.platform == :google_ads
      assert result.confidence == :high
    end
  end

  describe "classify/2 with UTM params" do
    test "parses UTM source and medium" do
      params = %{"utm_source" => "twitter", "utm_medium" => "social", "utm_campaign" => "launch"}
      result = classify_params(params)
      assert result.platform == "twitter"
      assert result.medium == :social
      assert result.campaign == "launch"
    end

    test "parses all UTM fields" do
      params = %{
        "utm_source" => "google",
        "utm_medium" => "cpc",
        "utm_campaign" => "winter",
        "utm_content" => "banner",
        "utm_term" => "analytics"
      }

      result = classify_params(params)
      assert result.content == "banner"
      assert result.term == "analytics"
    end
  end

  describe "classify/2 with referer" do
    test "classifies google.com as organic" do
      result = classify_with_referer("https://www.google.com/search?q=test")
      assert result.platform == :google
      assert result.medium == :organic
    end

    test "classifies t.co as twitter social" do
      result = classify_with_referer("https://t.co/abc123")
      assert result.platform == :twitter
      assert result.medium == :social
    end

    test "classifies unknown referer as referral" do
      result = classify_with_referer("https://some-blog.com/post/123")
      assert result.platform == :referral
      assert result.medium == :referral
      assert result.referer_domain == "some-blog.com"
    end

    test "classifies nil referer as direct" do
      result = classify_with_referer(nil)
      assert result.platform == :direct
      assert result.medium == :direct
    end

    test "classifies empty referer as direct" do
      result = classify_with_referer("")
      assert result.platform == :direct
      assert result.medium == :direct
    end

    test "strips www. from referer domain" do
      result = classify_with_referer("https://www.facebook.com/feed")
      assert result.platform == :facebook
      assert result.medium == :social
    end
  end

  describe "classify/2 with GA params" do
    test "detects via= param" do
      result = classify_params(%{"via" => "john"})
      assert result.partner_code == "john"
      assert result.medium == :referral
    end

    test "detects ref= param" do
      result = classify_params(%{"ref" => "partner123"})
      assert result.partner_code == "partner123"
    end

    test "via takes precedence over ref" do
      result = classify_params(%{"via" => "john", "ref" => "other"})
      assert result.partner_code == "john"
    end
  end

  describe "classify/2 priority ordering" do
    test "click ID > GA params > UTM > referer" do
      params = %{
        "gclid" => "g_val",
        "via" => "john",
        "utm_source" => "newsletter"
      }

      result =
        SourceClassifier.classify(%{
          query_params: params,
          referer: "https://facebook.com"
        })

      # Click ID wins for platform
      assert result.platform == :google_ads
      assert result.confidence == :high
      # But GA param info is still merged
      assert result.partner_code == "john"
    end
  end

  describe "normalize_medium/1" do
    test "normalizes cpc to paid" do
      assert SourceClassifier.normalize_medium("cpc") == :paid
    end

    test "normalizes ppc to paid" do
      assert SourceClassifier.normalize_medium("ppc") == :paid
    end

    test "normalizes paid to paid" do
      assert SourceClassifier.normalize_medium("paid") == :paid
    end

    test "normalizes email" do
      assert SourceClassifier.normalize_medium("email") == :email
    end

    test "passes through unknown medium" do
      assert SourceClassifier.normalize_medium("custom") == "custom"
    end
  end

  describe "capture_all_click_ids/2" do
    test "captures multiple click IDs" do
      params = %{"gclid" => "g", "fbclid" => "f", "other" => "ignored"}
      result = SourceClassifier.capture_all_click_ids(params)
      assert result == %{"gclid" => "g", "fbclid" => "f"}
    end

    test "returns empty map when no click IDs present" do
      assert SourceClassifier.capture_all_click_ids(%{}) == %{}
    end
  end

  describe "classify/2 with runtime overrides" do
    test "uses custom click_id_params" do
      custom_params = %{"my_click" => {:my_platform, :paid}}
      params = %{"my_click" => "abc"}

      result =
        SourceClassifier.classify(
          %{query_params: params, referer: nil},
          overrides: %{click_id_params: custom_params}
        )

      assert result.platform == :my_platform
      assert result.click_id_type == "my_click"
    end

    test "uses custom referer_map" do
      custom_map = %{"myblog.com" => {:my_blog, :content}}

      result =
        SourceClassifier.classify(
          %{query_params: %{}, referer: "https://myblog.com/post"},
          overrides: %{referer_map: custom_map}
        )

      assert result.platform == :my_blog
      assert result.medium == :content
    end
  end

  # Helpers

  defp classify_params(params) do
    SourceClassifier.classify(%{query_params: params, referer: nil})
  end

  defp classify_with_referer(referer) do
    SourceClassifier.classify(%{query_params: %{}, referer: referer})
  end
end
