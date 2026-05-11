defmodule GoodAnalytics.Core.Links.QRControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links.QR
  alias GoodAnalytics.Core.Links.QRController
  alias GoodAnalytics.Core.Links.Router

  import Plug.Test

  defp call_router(conn) do
    Router.call(conn, Router.init([]))
  end

  defp build_qr_conn(path, opts \\ []) do
    conn(:get, path)
    |> Map.put(:host, Keyword.get(opts, :host, "test.link"))
    |> Plug.Conn.fetch_query_params()
  end

  describe "GET /:key/qr" do
    test "returns 200 with SVG by default" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr") |> call_router()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/svg+xml"
      assert conn.resp_body =~ "<svg"
    end

    test "returns PNG when format=png" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr?format=png") |> call_router()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      assert <<0x89, 0x50, 0x4E, 0x47, _rest::binary>> = conn.resp_body
    end

    test "accepts image-only Accept headers" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn =
        build_qr_conn("/#{link.key}/qr?format=png")
        |> Plug.Conn.put_req_header("accept", "image/png")
        |> call_router()

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
    end

    test "accepts custom params" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr?size=5&fg=ff0000&bg=00ff00&ec=high") |> call_router()

      assert conn.status == 200
      assert conn.resp_body =~ "<svg"
    end

    test "returns 404 for missing link" do
      conn = build_qr_conn("/nonexistent/qr") |> call_router()
      assert conn.status == 404
    end

    test "returns 410 for expired link" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      link = create_link!(%{domain: "test.link", url: "https://example.com", expires_at: past})

      conn = build_qr_conn("/#{link.key}/qr") |> call_router()
      assert conn.status == 410
    end

    test "returns 400 for invalid size" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr?size=999") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for invalid color" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr?fg=xyz") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for invalid ec level" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr?ec=invalid") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for invalid format" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr?format=gif") |> call_router()
      assert conn.status == 400
    end

    test "sets Cache-Control header" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr") |> call_router()

      assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
    end

    test "sets X-Content-Type-Options header" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr") |> call_router()

      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end

    test "sets Content-Security-Policy header" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr") |> call_router()

      assert get_resp_header(conn, "content-security-policy") == [
               "default-src 'none'; style-src 'unsafe-inline'"
             ]
    end

    test "sets X-Frame-Options header" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      conn = build_qr_conn("/#{link.key}/qr") |> call_router()

      assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    end

    test "returns 400 for size=0" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?size=0") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for size=51" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?size=51") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for size=abc" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?size=abc") |> call_router()
      assert conn.status == 400
    end

    test "returns 200 for size=1" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?size=1") |> call_router()
      assert conn.status == 200
    end

    test "returns 200 for size=50" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?size=50") |> call_router()
      assert conn.status == 200
    end

    test "returns 400 for invalid bg color" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?bg=xyz") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for fg with # prefix" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?fg=%23ff0000") |> call_router()
      assert conn.status == 400
    end

    test "returns 400 for 7-char fg" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?fg=ff00001") |> call_router()
      assert conn.status == 400
    end

    test "returns 200 for uppercase hex fg" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      conn = build_qr_conn("/#{link.key}/qr?fg=FF0000") |> call_router()
      assert conn.status == 200
    end

    test "derives the mounted short-link path from the QR request path" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, expected_svg} = QR.generate("test.link", link.key, path_prefix: "/r")

      conn =
        build_qr_conn("/r/#{link.key}/qr")
        |> QRController.show(%{"key" => link.key})

      assert conn.status == 200
      assert conn.resp_body == expected_svg
    end
  end

  defp get_resp_header(conn, key) do
    Plug.Conn.get_resp_header(conn, key)
  end
end
