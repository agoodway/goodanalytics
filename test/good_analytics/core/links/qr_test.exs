defmodule GoodAnalytics.Core.Links.QRTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Cache
  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Links.QR

  describe "generate/3" do
    test "generates SVG by default for valid link" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, svg} = QR.generate("test.link", link.key)
      assert is_binary(svg)
      assert svg =~ "<svg"
    end

    test "generates PNG when format is :png" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, png} = QR.generate("test.link", link.key, format: :png)
      assert is_binary(png)
      # PNG magic bytes
      assert <<0x89, 0x50, 0x4E, 0x47, _rest::binary>> = png
    end

    test "applies custom foreground and background colors" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, svg} = QR.generate("test.link", link.key, fg: "ff0000", bg: "00ff00")
      assert svg =~ "#ff0000"
      assert svg =~ "#00ff00"
    end

    test "applies custom size" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, svg_small} = QR.generate("test.link", link.key, size: 2)
      assert {:ok, svg_large} = QR.generate("test.link", link.key, size: 20)
      assert byte_size(svg_large) > byte_size(svg_small)
    end

    test "supports all error correction levels" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      for ec <- ~w(low medium quartile high) do
        assert {:ok, _svg} = QR.generate("test.link", link.key, ec: ec)
      end
    end

    test "returns {:error, :not_found} for nonexistent link" do
      assert {:error, :not_found} = QR.generate("test.link", "nonexistent")
    end

    test "returns {:error, :expired} for expired link" do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      link = create_link!(%{domain: "test.link", url: "https://example.com", expires_at: past})
      assert {:error, :expired} = QR.generate("test.link", link.key)
    end

    test "cache hit skips DB lookup" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      # First call populates cache
      assert {:ok, svg1} = QR.generate("test.link", link.key)

      # Archive the link — cache should still return the QR
      {:ok, _} = Links.archive_link(link.id)

      assert {:ok, svg2} = QR.generate("test.link", link.key)
      assert svg1 == svg2
    end

    test "cache miss with valid link hits DB and caches" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      cache_key = {:qr, "test.link", "", link.key, :svg, 10, "000000", "ffffff", "low"}
      assert Cache.get(cache_key) == nil

      assert {:ok, _svg} = QR.generate("test.link", link.key)

      assert Cache.get(cache_key) != nil
    end

    test "returns {:error, :invalid_ec} for invalid ec level" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:error, :invalid_ec} = QR.generate("test.link", link.key, ec: "ultra")
    end

    test "generates successfully at size=1 boundary" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, svg} = QR.generate("test.link", link.key, size: 1)
      assert svg =~ "<svg"
    end

    test "generates successfully at size=50 boundary" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, svg} = QR.generate("test.link", link.key, size: 50)
      assert svg =~ "<svg"
    end

    test "generates QR encoding the link URL with qr=1 param" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})
      assert {:ok, svg} = QR.generate("test.link", link.key)
      # The SVG encodes https://test.link/<key>?qr=1 as a QR matrix;
      # we verify the generation succeeds and produces a valid SVG
      assert svg =~ "<svg"
      assert svg =~ "<rect"
    end

    test "uses path_prefix when building the QR target URL" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      assert {:ok, default_svg} = QR.generate("test.link", link.key)
      assert {:ok, prefixed_svg} = QR.generate("test.link", link.key, path_prefix: "/r")

      assert default_svg != prefixed_svg
    end

    test "cache entry expires with TTL so expired links are not served stale" do
      future = DateTime.add(DateTime.utc_now(), 2, :second)
      link = create_link!(%{domain: "test.link", url: "https://example.com", expires_at: future})

      assert {:ok, _svg} = QR.generate("test.link", link.key)

      # Wait for link to expire and TTL to lapse
      Process.sleep(2_100)

      assert {:error, :expired} = QR.generate("test.link", link.key)
    end

    test "concurrent requests for same key all return valid identical SVGs" do
      link = create_link!(%{domain: "test.link", url: "https://example.com"})

      results =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> QR.generate("test.link", link.key) end)
        end)
        |> Enum.map(&Task.await/1)

      svgs = Enum.map(results, fn {:ok, svg} -> svg end)
      assert length(svgs) == 20
      assert Enum.all?(svgs, &(&1 =~ "<svg"))
      assert length(Enum.uniq(svgs)) == 1
    end
  end
end
