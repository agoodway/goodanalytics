defmodule GoodAnalytics.Core.Tracking.ShareLinksTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Tracking.ShareLinks

  @link "https://mybrand.link/promo"

  describe "all_share_urls/2" do
    test "returns URLs for all platforms" do
      urls = ShareLinks.all_share_urls(@link)
      assert Map.has_key?(urls, :twitter)
      assert Map.has_key?(urls, :facebook)
      assert Map.has_key?(urls, :linkedin)
      assert Map.has_key?(urls, :whatsapp)
      assert Map.has_key?(urls, :telegram)
      assert Map.has_key?(urls, :reddit)
      assert Map.has_key?(urls, :email)
      assert Map.has_key?(urls, :copy)
    end

    test "copy is just the raw link" do
      urls = ShareLinks.all_share_urls(@link)
      assert urls.copy == @link
    end
  end

  describe "share_url/3" do
    test "twitter includes URL" do
      url = ShareLinks.share_url(@link, :twitter, [])
      assert String.contains?(url, "twitter.com/intent/tweet")
      assert String.contains?(url, URI.encode_www_form(@link))
    end

    test "twitter with text and via" do
      url = ShareLinks.share_url(@link, :twitter, text: "Check this!", via: "agoodway")
      assert String.contains?(url, "Check+this")
      assert String.contains?(url, "agoodway")
    end

    test "facebook includes URL" do
      url = ShareLinks.share_url(@link, :facebook, [])
      assert String.contains?(url, "facebook.com/sharer")
      assert String.contains?(url, URI.encode_www_form(@link))
    end

    test "linkedin includes URL" do
      url = ShareLinks.share_url(@link, :linkedin, [])
      assert String.contains?(url, "linkedin.com/sharing")
    end

    test "whatsapp includes link in text" do
      url = ShareLinks.share_url(@link, :whatsapp, [])
      assert String.contains?(url, "api.whatsapp.com")
      assert String.contains?(url, URI.encode_www_form(@link))
    end

    test "whatsapp with custom text" do
      url = ShareLinks.share_url(@link, :whatsapp, text: "Look at this")
      assert String.contains?(url, "Look+at+this")
    end

    test "telegram includes URL" do
      url = ShareLinks.share_url(@link, :telegram, [])
      assert String.contains?(url, "t.me/share")
    end

    test "reddit includes URL" do
      url = ShareLinks.share_url(@link, :reddit, [])
      assert String.contains?(url, "reddit.com/submit")
    end

    test "email generates mailto link" do
      url = ShareLinks.share_url(@link, :email, [])
      assert String.starts_with?(url, "mailto:?")
    end
  end
end
