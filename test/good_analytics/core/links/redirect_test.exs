defmodule GoodAnalytics.Core.Links.RedirectTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Links.Redirect

  defp build_link(attrs \\ %{}) do
    defaults = %{
      utm_source: nil,
      utm_medium: nil,
      utm_campaign: nil,
      utm_content: nil,
      utm_term: nil
    }

    struct(GoodAnalytics.Core.Links.Link, Map.merge(defaults, attrs))
  end

  defp build_conn(query_params \\ %{}) do
    %Plug.Conn{query_params: query_params}
  end

  defp parse_params(url) do
    url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
  end

  describe "build_redirect_url/4" do
    test "appends only ga_id when link has no UTMs" do
      link = build_link()
      conn = build_conn()

      result = Redirect.build_redirect_url("https://example.com/page", link, conn, "click-123")

      assert result == "https://example.com/page?ga_id=click-123"
    end

    test "preserves destination's existing query params" do
      link = build_link()
      conn = build_conn()

      result =
        Redirect.build_redirect_url("https://example.com/page?foo=bar", link, conn, "click-123")

      params = parse_params(result)

      assert params["foo"] == "bar"
      assert params["ga_id"] == "click-123"
    end

    test "appends link-level UTM params to destination" do
      link =
        build_link(%{utm_source: "twitter", utm_medium: "social", utm_campaign: "launch-2025"})

      conn = build_conn()

      result = Redirect.build_redirect_url("https://example.com/signup", link, conn, "click-123")
      params = parse_params(result)

      assert params["utm_source"] == "twitter"
      assert params["utm_medium"] == "social"
      assert params["utm_campaign"] == "launch-2025"
      assert params["ga_id"] == "click-123"
    end

    test "link UTMs override destination's existing UTMs" do
      link = build_link(%{utm_source: "twitter"})
      conn = build_conn()

      result =
        Redirect.build_redirect_url(
          "https://example.com?utm_source=default",
          link,
          conn,
          "click-123"
        )

      params = parse_params(result)

      assert params["utm_source"] == "twitter"
    end

    test "skips nil UTM fields" do
      link = build_link(%{utm_source: "twitter", utm_medium: nil})
      conn = build_conn()

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      assert params["utm_source"] == "twitter"
      refute Map.has_key?(params, "utm_medium")
    end

    test "forwards passthrough query params from short link URL" do
      link = build_link()
      conn = build_conn(%{"custom" => "value", "page" => "2"})

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      assert params["custom"] == "value"
      assert params["page"] == "2"
      assert params["ga_id"] == "click-123"
    end

    test "passthrough params override link-level UTMs" do
      link = build_link(%{utm_source: "twitter"})
      conn = build_conn(%{"utm_source" => "newsletter"})

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      assert params["utm_source"] == "newsletter"
    end

    test "excludes click ID params from passthrough" do
      link = build_link()
      conn = build_conn(%{"gclid" => "abc", "fbclid" => "def", "custom" => "keep"})

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      refute Map.has_key?(params, "gclid")
      refute Map.has_key?(params, "fbclid")
      assert params["custom"] == "keep"
    end

    test "excludes internal GA params from passthrough" do
      link = build_link()
      conn = build_conn(%{"ga_id" => "old", "via" => "partner", "ref" => "code"})

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      assert params["ga_id"] == "click-123"
      refute Map.has_key?(params, "via")
      refute Map.has_key?(params, "ref")
    end

    test "ga_id is always present even with complex param merging" do
      link = build_link(%{utm_source: "twitter", utm_medium: "social"})
      conn = build_conn(%{"utm_content" => "hero", "custom" => "val"})

      result =
        Redirect.build_redirect_url("https://example.com?existing=yes", link, conn, "click-123")

      params = parse_params(result)

      assert params["existing"] == "yes"
      assert params["utm_source"] == "twitter"
      assert params["utm_medium"] == "social"
      assert params["utm_content"] == "hero"
      assert params["custom"] == "val"
      assert params["ga_id"] == "click-123"
    end

    test "all five UTM fields are supported" do
      link =
        build_link(%{
          utm_source: "google",
          utm_medium: "cpc",
          utm_campaign: "summer-sale",
          utm_content: "logo-link",
          utm_term: "running shoes"
        })

      conn = build_conn()

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      assert params["utm_source"] == "google"
      assert params["utm_medium"] == "cpc"
      assert params["utm_campaign"] == "summer-sale"
      assert params["utm_content"] == "logo-link"
      assert params["utm_term"] == "running shoes"
    end

    test "qr param is excluded from passthrough" do
      link = build_link()
      conn = build_conn(%{"qr" => "1", "custom" => "keep"})

      result = Redirect.build_redirect_url("https://example.com", link, conn, "click-123")
      params = parse_params(result)

      refute Map.has_key?(params, "qr")
      assert params["custom"] == "keep"
    end
  end
end
