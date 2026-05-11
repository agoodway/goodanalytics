defmodule GoodAnalytics.Core.Links.QR do
  @moduledoc """
  Generates QR code images for short links.

  QR codes encode `{scheme}://{domain}{path_prefix}/{key}?qr=1` so that
  scans are detectable in the redirect flow. Rendered images are cached in
  Nebulex to avoid redundant generation.
  """

  alias GoodAnalytics.Cache
  alias GoodAnalytics.Core.Links

  @default_ttl :timer.hours(24)
  @ec_levels %{"low" => :low, "medium" => :medium, "quartile" => :quartile, "high" => :high}
  @link_scheme Application.compile_env(:good_analytics, :link_scheme, "https")
  @default_path_prefix Application.compile_env(:good_analytics, :link_path_prefix, "")

  @doc """
  Generates a QR code image for the given domain and key.

  Returns `{:ok, binary}` on success or `{:error, reason}` on failure.
  Checks the cache first; on miss, verifies the link exists in the DB.

  ## Options

    * `:format` - `:svg` (default) or `:png`
    * `:size` - scale factor, 1..50 (default 10)
    * `:fg` - foreground color as 6-char hex string (default "000000")
    * `:bg` - background color as 6-char hex string (default "ffffff")
    * `:ec` - error correction level: "low", "medium", "quartile", "high" (default "low")
    * `:path_prefix` - short-link mount path prefix (default `config :good_analytics, :link_path_prefix` or `""`)
  """
  def generate(domain, key, opts \\ []) do
    format = Keyword.get(opts, :format, :svg)
    size = Keyword.get(opts, :size, 10)
    fg = Keyword.get(opts, :fg, "000000")
    bg = Keyword.get(opts, :bg, "ffffff")
    ec = Keyword.get(opts, :ec, "low")

    path_prefix =
      opts |> Keyword.get(:path_prefix, @default_path_prefix) |> normalize_path_prefix()

    case Map.get(@ec_levels, ec) do
      nil ->
        {:error, :invalid_ec}

      ec_level ->
        cache_key = {:qr, domain, path_prefix, key, format, size, fg, bg, ec}
        render_opts = %{format: format, size: size, fg: fg, bg: bg, ec_level: ec_level}

        case Cache.get(cache_key) do
          nil ->
            generate_and_cache(domain, key, path_prefix, cache_key, render_opts)

          cached ->
            {:ok, cached}
        end
    end
  end

  defp generate_and_cache(domain, key, path_prefix, cache_key, render_opts) do
    %{format: format, size: size, fg: fg, bg: bg, ec_level: ec_level} = render_opts

    with {:ok, link} <- Links.resolve_live_link(domain, key),
         url <- build_qr_url(domain, path_prefix, key),
         {:ok, binary} <- QRCode.create(url, ec_level) |> render(format, size, fg, bg) do
      ttl = compute_ttl(link)
      Cache.put(cache_key, binary, ttl: ttl)
      {:ok, binary}
    end
  end

  defp compute_ttl(%{expires_at: nil}), do: @default_ttl

  defp compute_ttl(%{expires_at: expires_at}) do
    seconds_remaining = DateTime.diff(expires_at, DateTime.utc_now(), :second)
    min(seconds_remaining * 1_000, @default_ttl) |> max(0)
  end

  defp build_qr_url(domain, path_prefix, key) do
    {host, port} = split_host_port(domain)

    %URI{
      scheme: @link_scheme,
      host: host,
      port: port,
      path: path_prefix <> "/#{key}",
      query: "qr=1"
    }
    |> URI.to_string()
  end

  defp split_host_port(domain) do
    uri = URI.parse("//#{domain}")
    {uri.host || domain, uri.port}
  end

  defp normalize_path_prefix(nil), do: ""
  defp normalize_path_prefix(""), do: ""

  defp normalize_path_prefix(path_prefix) do
    "/" <> String.trim(path_prefix, "/")
  end

  defp render(qr_result, :svg, size, fg, bg) do
    settings = %QRCode.Render.SvgSettings{
      scale: size,
      qrcode_color: "##{fg}",
      background_color: "##{bg}"
    }

    QRCode.Render.render(qr_result, :svg, settings)
  end

  defp render(qr_result, :png, size, fg, bg) do
    settings = %QRCode.Render.PngSettings{
      scale: size,
      qrcode_color: "##{fg}",
      background_color: "##{bg}"
    }

    QRCode.Render.render(qr_result, :png, settings)
  end
end
