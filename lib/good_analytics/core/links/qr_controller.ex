defmodule GoodAnalytics.Core.Links.QRController do
  @moduledoc """
  Phoenix controller that serves QR code images for short links.

  ## Trust boundary

  All user-supplied query parameters (`format`, `size`, `fg`, `bg`, `ec`) are
  validated by `validate_params/1` before use.  The `binary` written to the
  response is produced entirely by the QR-code library and never contains
  user-supplied data.  The `content_type` passed to `put_resp_content_type/3`
  is returned by the private `content_type/1` function, which maps the
  validated `:svg` / `:png` atom to one of exactly two hard-coded MIME
  strings — it is not derived from request input.
  """

  use Phoenix.Controller, formats: [:html]

  alias GoodAnalytics.Core.Links.QR

  @valid_ec_levels ~w(low medium quartile high)

  @doc """
  Renders a QR code image for the short link identified by `key`.

  Accepts optional query parameters: `format` (svg|png), `size` (1..50),
  `fg` / `bg` (6-char hex), `ec` (low|medium|quartile|high).

  Responds with the appropriate image content type and a 24-hour
  cache-control header on success, or a 4xx/5xx text response on error.
  """
  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  # sobelow_skip ["XSS.ContentType", "XSS.SendResp"]
  # content_type is hardcoded to one of two enum values from content_type/1,
  # never user-supplied. binary is produced by the QR-code library from an
  # internally constructed URL; it contains no user-supplied data.
  def show(conn, %{"key" => key} = params) do
    domain = request_host(conn)

    case validate_params(params) do
      {:ok, opts} ->
        case QR.generate(
               domain,
               key,
               Keyword.put_new(opts, :path_prefix, qr_path_prefix(conn, key))
             ) do
          {:ok, binary} ->
            format = Keyword.get(opts, :format, :svg)

            conn
            |> put_resp_content_type(content_type(format), nil)
            |> put_resp_header("cache-control", "public, max-age=86400")
            |> put_resp_header("x-content-type-options", "nosniff")
            |> put_resp_header(
              "content-security-policy",
              "default-src 'none'; style-src 'unsafe-inline'"
            )
            |> put_resp_header("x-frame-options", "DENY")
            |> send_resp(200, binary)

          {:error, :not_found} ->
            conn |> put_status(404) |> text("Link not found")

          {:error, :expired} ->
            conn |> put_status(410) |> text("Link expired")

          {:error, _reason} ->
            conn |> put_status(500) |> text("QR generation failed")
        end

      {:error, message} ->
        conn |> put_status(400) |> text(message)
    end
  end

  defp validate_params(params) do
    with {:ok, format} <- validate_format(params),
         {:ok, size} <- validate_size(params),
         {:ok, fg} <- validate_color(params, "fg", "000000"),
         {:ok, bg} <- validate_color(params, "bg", "ffffff"),
         {:ok, ec} <- validate_ec(params) do
      {:ok, [format: format, size: size, fg: fg, bg: bg, ec: ec]}
    end
  end

  defp validate_format(%{"format" => "svg"}), do: {:ok, :svg}
  defp validate_format(%{"format" => "png"}), do: {:ok, :png}
  defp validate_format(%{"format" => _}), do: {:error, "Invalid format. Must be svg or png."}
  defp validate_format(_), do: {:ok, :svg}

  defp validate_size(%{"size" => s}) do
    case Integer.parse(s) do
      {n, ""} when n >= 1 and n <= 50 -> {:ok, n}
      _ -> {:error, "Invalid size. Must be integer 1..50."}
    end
  end

  defp validate_size(_), do: {:ok, 10}

  defp validate_color(params, param, default) do
    case Map.get(params, param) do
      nil ->
        {:ok, default}

      color ->
        if Regex.match?(~r/\A[0-9a-fA-F]{6}\z/, color) do
          {:ok, String.downcase(color)}
        else
          {:error, "Invalid #{param}. Must be 6-character hex color."}
        end
    end
  end

  defp validate_ec(%{"ec" => ec}) when ec in @valid_ec_levels, do: {:ok, ec}

  defp validate_ec(%{"ec" => _}),
    do: {:error, "Invalid ec. Must be low, medium, quartile, or high."}

  defp validate_ec(_), do: {:ok, "low"}

  defp qr_path_prefix(conn, key) do
    request_path = conn.request_path

    case String.replace_suffix(request_path, "/#{key}/qr", "") do
      ^request_path -> ""
      path_prefix -> path_prefix
    end
  end

  defp request_host(%{host: host, port: port}) when port in [80, 443], do: host
  defp request_host(%{host: host, port: port}), do: "#{host}:#{port}"

  defp content_type(:svg), do: "image/svg+xml"
  defp content_type(:png), do: "image/png"
end
