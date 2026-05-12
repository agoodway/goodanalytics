defmodule GoodAnalytics.Integration.RedirectFlowTest do
  @moduledoc """
  OpenSpec 12.1: Full redirect flow integration test.

  Tests the complete lifecycle: create link -> redirect request ->
  verify click event + visitor created + ga_id in redirect URL.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Links.Redirect
  alias GoodAnalytics.Core.Visitors

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
      past = DateTime.add(DateTime.utc_now(), -3600, :second)

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
end
