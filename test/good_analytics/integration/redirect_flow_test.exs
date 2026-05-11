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
end
