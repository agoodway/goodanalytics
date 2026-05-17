defmodule GoodAnalytics.Core.Events.UrlNormalizerTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Events.UrlNormalizer

  describe "host/1" do
    test "extracts lowercase host from full URL" do
      assert UrlNormalizer.host("https://App.Acme.COM/pricing?utm=x#hero") == "app.acme.com"
    end

    test "strips default port 80 for http" do
      assert UrlNormalizer.host("http://acme.com:80/x") == "acme.com"
    end

    test "strips default port 443 for https" do
      assert UrlNormalizer.host("https://acme.com:443/x") == "acme.com"
    end

    test "preserves custom port" do
      assert UrlNormalizer.host("https://acme.com:8443/x") == "acme.com:8443"
    end

    test "returns nil for nil" do
      assert UrlNormalizer.host(nil) == nil
    end

    test "returns nil for empty string" do
      assert UrlNormalizer.host("") == nil
    end

    test "returns nil for hostless URL" do
      assert UrlNormalizer.host("/just/a/path") == nil
    end

    test "returns nil for non-URL string" do
      assert UrlNormalizer.host("not-a-url") == nil
    end
  end

  describe "path/1" do
    test "extracts path stripped of query and fragment" do
      assert UrlNormalizer.path("https://app.acme.com/pricing?utm_source=x#section") == "/pricing"
    end

    test "trims trailing slash except root" do
      assert UrlNormalizer.path("https://acme.com/pricing/") == "/pricing"
      assert UrlNormalizer.path("https://acme.com/") == "/"
    end

    test "collapses duplicate slashes" do
      assert UrlNormalizer.path("https://acme.com//docs///guide") == "/docs/guide"
    end

    test "defaults to / for nil" do
      assert UrlNormalizer.path(nil) == "/"
    end

    test "defaults to / for empty string" do
      assert UrlNormalizer.path("") == "/"
    end

    test "defaults to / for hostless missing path" do
      assert UrlNormalizer.path("#/dashboard") == "/"
    end

    test "handles path-only input" do
      assert UrlNormalizer.path("/just/a/path") == "/just/a/path"
    end

    test "handles non-URL string as path" do
      assert UrlNormalizer.path("not-a-url") == "/not-a-url"
    end
  end

  describe "path_for_grouping/1" do
    test "returns scheme://host/path for full URLs with lowercased host" do
      assert UrlNormalizer.path_for_grouping("https://Example.com/pricing?fbclid=abc#hero") ==
               "https://example.com/pricing"
    end

    test "collapses duplicate slashes and strips trailing slash" do
      assert UrlNormalizer.path_for_grouping("https://example.com//pricing///") ==
               "https://example.com/pricing"

      assert UrlNormalizer.path_for_grouping("https://example.com///") == "https://example.com/"
    end

    test "preserves percent-encoding and path case" do
      assert UrlNormalizer.path_for_grouping("https://example.com/Pricing/%7Ealice?utm=x") ==
               "https://example.com/Pricing/%7Ealice"
    end

    test "handles nil and empty as root" do
      assert UrlNormalizer.path_for_grouping(nil) == "/"
      assert UrlNormalizer.path_for_grouping("") == "/"
      assert UrlNormalizer.path_for_grouping("#/dashboard") == "/"
    end

    test "includes custom port" do
      assert UrlNormalizer.path_for_grouping("https://acme.com:8443/api") ==
               "https://acme.com:8443/api"
    end

    test "strips default ports" do
      assert UrlNormalizer.path_for_grouping("http://acme.com:80/x") == "http://acme.com/x"
      assert UrlNormalizer.path_for_grouping("https://acme.com:443/x") == "https://acme.com/x"
    end
  end

  describe "host+path agreement with path_for_grouping" do
    @agreement_urls [
      "https://acme.com/pricing",
      "https://acme.com/pricing?utm=x#hero",
      "http://acme.com:80/x",
      "https://acme.com:443/docs/guide",
      "https://acme.com:8443/api/v1",
      "https://app.acme.com/",
      "https://example.com//docs///guide?q=1",
      "http://test.local/a/b/c/d",
      "https://App.Acme.COM/pricing"
    ]

    test "host(url) <> path(url) is a stable substring of path_for_grouping(url)" do
      for url <- @agreement_urls do
        grouped = UrlNormalizer.path_for_grouping(url)
        host_val = UrlNormalizer.host(url)
        path_val = UrlNormalizer.path(url)

        combined = host_val <> path_val

        assert String.contains?(grouped, combined),
               "Expected #{inspect(grouped)} to contain #{inspect(combined)} for url #{inspect(url)}"
      end
    end
  end
end
