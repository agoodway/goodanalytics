defmodule GoodAnalytics.Integration.RedirectFlowTest do
  @moduledoc """
  OpenSpec 12.1: Full redirect flow integration test.

  Tests the complete lifecycle: create link -> redirect request ->
  verify click event + visitor created + ga_id in redirect URL.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.{Links, Visitors}
  alias GoodAnalytics.Core.Links.Redirect
  alias GoodAnalytics.Core.Tracking.BeaconController

  import Plug.Test

  @workspace_id GoodAnalytics.default_workspace_id()

  defp build_redirect_conn(path, opts \\ []) do
    conn(:get, path)
    |> Map.put(:host, Keyword.get(opts, :host, "test.link"))
    |> Map.put(:query_params, URI.decode_query(URI.parse(path).query || ""))
    |> Plug.Conn.fetch_query_params()
    |> Plug.Conn.put_req_header("user-agent", Keyword.get(opts, :user_agent, "TestBot/1.0"))
    |> put_private_phoenix()
  end

  # Phoenix.Controller.redirect needs :phoenix_format in private
  defp put_private_phoenix(conn) do
    conn
    |> Plug.Conn.put_private(:phoenix_format, "html")
  end

  defp ga_id_from_redirect(conn) do
    [location] = Plug.Conn.get_resp_header(conn, "location")
    params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
    Map.fetch!(params, "ga_id")
  end

  defp returning_conn(link, ga_id) do
    build_redirect_conn("/#{link.key}")
    |> Plug.Conn.put_req_header("cookie", "_ga_good=#{ga_id}")
  end

  defp put_internal_hosts(hosts) do
    previous = Application.get_env(:good_analytics, :internal_hosts)
    Application.put_env(:good_analytics, :internal_hosts, hosts)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:good_analytics, :internal_hosts, previous),
        else: Application.delete_env(:good_analytics, :internal_hosts)
    end)
  end

  describe "full redirect flow" do
    test "redirect creates click event, visitor, and appends ga_id to URL" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/page"})

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      # Should be a 302 redirect
      assert result.status == 302

      # ga_id should be in the redirect URL
      ga_id = ga_id_from_redirect(result)
      assert {:ok, _} = Ecto.UUID.cast(ga_id)

      # Click event should be recorded
      clicks = Links.link_clicks(link.id)
      assert [_ | _] = clicks
      click = hd(clicks)
      assert click.event_type == "link_click"
      assert click.link_id == link.id

      # Visitor should exist
      assert visitor = Visitors.get_visitor(click.visitor_id)
      assert visitor.workspace_id == @workspace_id
    end

    test "a click referred from the short-link host itself records no source" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/page"})

      conn =
        build_redirect_conn("/#{link.key}")
        |> Plug.Conn.put_req_header("referer", "https://www.test.link/")

      Redirect.handle_redirect(conn, "test.link", link.key)

      click = Links.link_clicks(link.id) |> hd()
      assert click.source_medium == nil
      assert click.source_platform == nil
    end

    test "returning visitor keeps one identity across redirect and landing beacon" do
      link = create_link!(%{domain: "test.link", url: "https://www.test.link/page"})

      {:ok, existing} =
        GoodAnalytics.resolve_visitor(%{ga_id: "existing"}, workspace_id: @workspace_id)

      conn =
        build_redirect_conn("/#{link.key}")
        |> Plug.Conn.put_req_header("cookie", "_ga_good=existing")

      result = Redirect.handle_redirect(conn, "test.link", link.key)

      handed_off = ga_id_from_redirect(result)
      assert handed_off == "existing"

      assert {:ok, resolved} =
               GoodAnalytics.resolve_visitor(%{ga_id: handed_off}, workspace_id: @workspace_id)

      assert resolved.id == existing.id
      assert [only] = Visitors.list_visitors(@workspace_id)
      assert only.id == existing.id
    end

    test "returning visitor's ga_id is not handed to an off-site destination" do
      link = create_link!(%{domain: "test.link", url: "https://partner.example.org/x"})

      {:ok, _existing} =
        GoodAnalytics.resolve_visitor(%{ga_id: "existing"}, workspace_id: @workspace_id)

      result = Redirect.handle_redirect(returning_conn(link, "existing"), "test.link", link.key)

      click = Links.link_clicks(link.id) |> hd()
      handed_off = ga_id_from_redirect(result)
      refute handed_off == "existing"
      assert {:ok, _} = Ecto.UUID.cast(handed_off)
      assert click.click_id == handed_off
    end

    test "returning visitor's ga_id is handed to a destination listed in internal_hosts" do
      put_internal_hosts(["Site.example"])
      link = create_link!(%{domain: "test.link", url: "https://www.site.example/x"})

      {:ok, _existing} =
        GoodAnalytics.resolve_visitor(%{ga_id: "existing"}, workspace_id: @workspace_id)

      result = Redirect.handle_redirect(returning_conn(link, "existing"), "test.link", link.key)

      assert ga_id_from_redirect(result) == "existing"
    end

    test "returning visitor's ga_id is handed to a destination on the link's own domain" do
      link = create_link!(%{domain: "go.example", url: "https://go.example/x"})

      {:ok, _existing} =
        GoodAnalytics.resolve_visitor(%{ga_id: "existing"}, workspace_id: @workspace_id)

      result = Redirect.handle_redirect(returning_conn(link, "existing"), "go.example", link.key)

      assert ga_id_from_redirect(result) == "existing"
    end

    test "owned destination falls back to the cookie when the visitor has no ga_id, then the click id" do
      put_internal_hosts(["site.example"])
      link = create_link!(%{domain: "test.link", url: "https://site.example/x"})

      # Cookie value is resolved as the visitor's ga_id, so the hand-off is the cookie.
      with_cookie =
        Redirect.handle_redirect(returning_conn(link, "cookie-id"), "test.link", link.key)

      assert ga_id_from_redirect(with_cookie) == "cookie-id"

      # No cookie: the click id seeds the new visitor and is handed off.
      other = create_link!(%{domain: "test.link", url: "https://site.example/y"})

      no_cookie =
        Redirect.handle_redirect(build_redirect_conn("/#{other.key}"), "test.link", other.key)

      assert [%{click_id: click_id}] = Links.link_clicks(other.id)
      assert ga_id_from_redirect(no_cookie) == click_id
    end

    test "first-time visitor's ga_id hand-off resolves to the visitor the click created" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/page"})

      result =
        Redirect.handle_redirect(build_redirect_conn("/#{link.key}"), "test.link", link.key)

      handed_off = ga_id_from_redirect(result)
      click = Links.link_clicks(link.id) |> hd()

      assert {:ok, resolved} =
               GoodAnalytics.resolve_visitor(%{ga_id: handed_off}, workspace_id: @workspace_id)

      assert resolved.id == click.visitor_id
      assert [_only] = Visitors.list_visitors(@workspace_id)
    end

    test "link utm fields classify a referrer-less click" do
      link =
        create_link!(%{
          domain: "test.link",
          url: "https://destination.com/page",
          utm_source: "newsletter",
          utm_medium: "email"
        })

      Redirect.handle_redirect(build_redirect_conn("/#{link.key}"), "test.link", link.key)

      click = Links.link_clicks(link.id) |> hd()
      assert click.source_medium == "email"

      visitor = Visitors.get_visitor(click.visitor_id)
      assert (visitor.last_source["medium"] || visitor.last_source[:medium]) == "email"
    end

    test "request utms override link utms" do
      link =
        create_link!(%{
          domain: "test.link",
          url: "https://destination.com/page",
          utm_source: "linkedin",
          utm_medium: "social"
        })

      conn = build_redirect_conn("/#{link.key}?utm_source=x&utm_medium=cpc")
      Redirect.handle_redirect(conn, "test.link", link.key)

      click = Links.link_clicks(link.id) |> hd()
      assert click.source_medium == "paid"
    end

    test "a link without utms still classifies from the referer" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/page"})

      conn =
        build_redirect_conn("/#{link.key}")
        |> Plug.Conn.put_req_header("referer", "https://www.linkedin.com/feed")

      Redirect.handle_redirect(conn, "test.link", link.key)

      click = Links.link_clicks(link.id) |> hd()
      assert click.source_medium == "social"
      assert click.source_platform == "linkedin"
    end

    test "redirect increments link click counters" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/count"})

      conn = build_redirect_conn("/#{link.key}")
      Redirect.handle_redirect(conn, "test.link", link.key)

      updated = Links.get_link(link.id)
      assert updated.total_clicks == 1
      assert updated.unique_clicks == 1
    end

    test "duplicate click from same IP increments total but not unique" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/dup"})

      conn = build_redirect_conn("/#{link.key}")
      Redirect.handle_redirect(conn, "test.link", link.key)
      Redirect.handle_redirect(conn, "test.link", link.key)

      updated = Links.get_link(link.id)
      assert updated.total_clicks == 2
      assert updated.unique_clicks == 1
    end

    test "returns 404 for nonexistent key" do
      conn = build_redirect_conn("/nonexistent")
      result = Redirect.handle_redirect(conn, "test.link", "nonexistent")
      assert result.status == 404
    end

    test "returns 404 for archived link" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/archived"})
      {:ok, _} = Links.archive_link(link.id)

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)
      assert result.status == 404
    end

    test "passthrough query params preserved in redirect URL" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/params"})

      conn = build_redirect_conn("/#{link.key}?custom=val&other=123")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      [location] = Plug.Conn.get_resp_header(result, "location")
      params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      assert params["custom"] == "val"
      assert params["other"] == "123"
      assert params["ga_id"]
    end

    test "qr=1 param sets qr: true on click event" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/qr"})

      conn = build_redirect_conn("/#{link.key}?qr=1")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      assert result.status == 302

      # qr param should be stripped from redirect URL
      [location] = Plug.Conn.get_resp_header(result, "location")
      params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      refute Map.has_key?(params, "qr")

      # Click event should have qr: true in properties
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert click.properties["qr"] == true
    end

    test "absence of qr param omits qr from click event properties" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/noqr"})

      conn = build_redirect_conn("/#{link.key}")
      Redirect.handle_redirect(conn, "test.link", link.key)

      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      refute Map.has_key?(click.properties, "qr")
    end

    test "qr=true does not set qr property on click event" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/qrtrue"})

      conn = build_redirect_conn("/#{link.key}?qr=true")
      Redirect.handle_redirect(conn, "test.link", link.key)

      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      refute Map.has_key?(click.properties, "qr")
    end

    test "qr=0 does not set qr property on click event" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/qr0"})

      conn = build_redirect_conn("/#{link.key}?qr=0")
      Redirect.handle_redirect(conn, "test.link", link.key)

      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      refute Map.has_key?(click.properties, "qr")
    end

    test "qr=yes does not set qr property on click event" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/qryes"})

      conn = build_redirect_conn("/#{link.key}?qr=yes")
      Redirect.handle_redirect(conn, "test.link", link.key)

      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      refute Map.has_key?(click.properties, "qr")
    end

    test "passthrough drops keys longer than 64 characters" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/longkey"})
      long_key = String.duplicate("a", 65)

      conn = build_redirect_conn("/#{link.key}?#{long_key}=val&short=ok")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      [location] = Plug.Conn.get_resp_header(result, "location")
      params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      refute Map.has_key?(params, long_key)
      assert params["short"] == "ok"
    end

    test "passthrough drops values longer than 512 characters" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/longval"})
      long_val = String.duplicate("b", 513)

      conn = build_redirect_conn("/#{link.key}?toolong=#{long_val}&short=ok")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      [location] = Plug.Conn.get_resp_header(result, "location")
      params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      refute Map.has_key?(params, "toolong")
      assert params["short"] == "ok"
    end

    test "passthrough truncates after 10 params" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/manyparams"})

      query =
        Enum.map_join(1..15, "&", fn i -> "p#{i}=v#{i}" end)

      conn = build_redirect_conn("/#{link.key}?#{query}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      [location] = Plug.Conn.get_resp_header(result, "location")
      params = location |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      # 10 passthrough + ga_id = 11 max
      passthrough_count = Map.keys(params) |> Enum.count(&String.starts_with?(&1, "p"))
      assert passthrough_count <= 10
    end

    test "returns 410 for expired link" do
      past = DateTime.add(utc_now(), -3600, :second)

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://destination.com/expired",
          expires_at: past
        })

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)
      assert result.status == 410
    end
  end

  describe "geo-routed redirects" do
    # Stub provider — returns canonical normalized geo for the test IP and
    # leaves anything else as :not_found. Configured per-test via
    # Application.put_env.
    defmodule StubGeoProvider do
      @behaviour GoodAnalytics.Geo.Provider

      @impl true
      def lookup({1, 2, 3, 4}),
        do:
          {:ok,
           %{
             "country" => %{"iso_code" => "DE", "names" => %{"en" => "Germany"}}
           }}

      def lookup(_), do: {:error, :not_found}
    end

    defmodule AlwaysTrue do
      def enabled?(_workspace_id), do: true
    end

    defmodule AlwaysFalse do
      def enabled?(_workspace_id), do: false
    end

    setup do
      prev_geo = Application.get_env(:good_analytics, :geo)
      prev_callback = Application.get_env(:good_analytics, :geo_routing_enabled_fn)

      Application.put_env(:good_analytics, :geo,
        provider: StubGeoProvider,
        normalizer: GoodAnalytics.Geo.Normalizer.MaxMind
      )

      on_exit(fn ->
        if prev_geo,
          do: Application.put_env(:good_analytics, :geo, prev_geo),
          else: Application.delete_env(:good_analytics, :geo)

        if prev_callback,
          do: Application.put_env(:good_analytics, :geo_routing_enabled_fn, prev_callback),
          else: Application.delete_env(:good_analytics, :geo_routing_enabled_fn)
      end)

      :ok
    end

    defp geo_conn(path, remote_ip) do
      conn(:get, path)
      |> Map.put(:host, "test.link")
      |> Map.put(:remote_ip, remote_ip)
      |> Map.put(:query_params, URI.decode_query(URI.parse(path).query || ""))
      |> Plug.Conn.fetch_query_params()
      |> Plug.Conn.put_req_header("user-agent", "TestBot/1.0")
      |> Plug.Conn.put_private(:phoenix_format, "html")
    end

    defp location_uri(result) do
      [location] = Plug.Conn.get_resp_header(result, "location")
      URI.parse(location)
    end

    test "geo routing ON returns the country-specific URL" do
      Application.put_env(:good_analytics, :geo_routing_enabled_fn, {AlwaysTrue, :enabled?})

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://default.example.com/landing",
          geo_targeting: %{"DE" => "https://de.example.com/landing"}
        })

      result =
        Redirect.handle_redirect(geo_conn("/#{link.key}", {1, 2, 3, 4}), "test.link", link.key)

      uri = location_uri(result)
      assert uri.host == "de.example.com"
    end

    test "geo routing OFF (callback false) falls back to default URL" do
      Application.put_env(:good_analytics, :geo_routing_enabled_fn, {AlwaysFalse, :enabled?})

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://default.example.com/landing",
          geo_targeting: %{"DE" => "https://de.example.com/landing"}
        })

      result =
        Redirect.handle_redirect(geo_conn("/#{link.key}", {1, 2, 3, 4}), "test.link", link.key)

      uri = location_uri(result)
      assert uri.host == "default.example.com"
    end

    test "no callback configured falls back to default URL" do
      Application.delete_env(:good_analytics, :geo_routing_enabled_fn)

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://default.example.com/landing",
          geo_targeting: %{"DE" => "https://de.example.com/landing"}
        })

      result =
        Redirect.handle_redirect(geo_conn("/#{link.key}", {1, 2, 3, 4}), "test.link", link.key)

      uri = location_uri(result)
      assert uri.host == "default.example.com"
    end

    test "lowercase country code in geo lookup still matches uppercase stored key" do
      Application.put_env(:good_analytics, :geo_routing_enabled_fn, {AlwaysTrue, :enabled?})

      defmodule LowercaseProvider do
        @behaviour GoodAnalytics.Geo.Provider
        @impl true
        def lookup({1, 2, 3, 4}),
          do: {:ok, %{"country" => %{"iso_code" => "de", "names" => %{"en" => "Germany"}}}}

        def lookup(_), do: {:error, :not_found}
      end

      Application.put_env(:good_analytics, :geo,
        provider: LowercaseProvider,
        normalizer: GoodAnalytics.Geo.Normalizer.MaxMind
      )

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://default.example.com/landing",
          geo_targeting: %{"DE" => "https://de.example.com/landing"}
        })

      result =
        Redirect.handle_redirect(geo_conn("/#{link.key}", {1, 2, 3, 4}), "test.link", link.key)

      uri = location_uri(result)
      assert uri.host == "de.example.com"
    end

    test "stored URL that fails scheme/host check falls back and logs" do
      Application.put_env(:good_analytics, :geo_routing_enabled_fn, {AlwaysTrue, :enabled?})

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://default.example.com/landing",
          geo_targeting: %{"DE" => "https://de.example.com/landing"}
        })

      # Bypass the changeset to simulate stale or directly-edited data
      GoodAnalytics.Repo.repo().query!(
        "UPDATE good_analytics.ga_links SET geo_targeting = $1 WHERE id = $2",
        [%{"DE" => "javascript:alert(1)"}, Ecto.UUID.dump!(link.id)]
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            Redirect.handle_redirect(
              geo_conn("/#{link.key}", {1, 2, 3, 4}),
              "test.link",
              link.key
            )

          uri = location_uri(result)
          assert uri.host == "default.example.com"
        end)

      assert log =~ "geo_targeting URL failed scheme/host check"
    end
  end

  describe "tagged newsletter link into a landing pageview" do
    test "the landing beacon is email and belongs to the clicking visitor" do
      put_internal_hosts(["site.test"])

      link =
        create_link!(%{
          domain: "test.link",
          url: "https://site.test/jobs/1",
          utm_source: "newsletter",
          utm_medium: "email",
          utm_campaign: "spring"
        })

      redirect =
        Redirect.handle_redirect(build_redirect_conn("/#{link.key}"), "test.link", link.key)

      assert redirect.status == 302

      [location] = Plug.Conn.get_resp_header(redirect, "location")
      destination = URI.parse(location)
      ga_id = destination.query |> URI.decode_query() |> Map.fetch!("ga_id")
      click_visitor_id = hd(Links.link_clicks(link.id)).visitor_id

      conn =
        conn(:post, "/ga/t/event")
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("user-agent", "RedirectFlowTest/1.0")
        |> Plug.Conn.put_private(:phoenix_format, "json")
        |> BeaconController.event(%{
          "event_type" => "pageview",
          "anonymous_id" => "anon-#{System.unique_integer([:positive])}",
          "ga_id" => ga_id,
          "url" => location,
          "referrer" => ""
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event =
        GoodAnalytics.Repo.repo().one!(
          Ecto.Query.from(e in GoodAnalytics.Core.Events.Event,
            where: e.event_type == "pageview" and e.visitor_id == ^click_visitor_id
          ),
          prefix: "good_analytics"
        )

      assert event.source_medium == "email"
      assert event.source_platform == "newsletter"
      assert event.source_campaign == "spring"
    end
  end
end
