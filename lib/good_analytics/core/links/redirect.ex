defmodule GoodAnalytics.Core.Links.Redirect do
  @moduledoc """
  Handles short link redirects.

  On each redirect:
  1. Look up link by domain + key
  2. Generate unique click_id
  3. Capture server-side data
  4. Check dedup cache
  5. Record click event if not duplicate
  6. Build redirect URL with link UTMs, passthrough params, and ga_id
  7. Fire :link_click hook (sync, crash-isolated)
  8. 302 redirect
  """

  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Tracking.{Deduplication, SourceClassifier}
  alias GoodAnalytics.Hooks

  import Plug.Conn

  require Logger

  @doc """
  Handles a redirect for the given domain and key.
  """
  def handle_redirect(conn, domain, key) do
    conn = Plug.Conn.fetch_cookies(conn)

    with {:ok, link} <- Links.resolve_live_link(domain, key),
         {:ok, destination} <- validate_destination_url(link, conn) do
      click_id = Uniq.UUID.uuid7()
      ga_id = conn.cookies["_ga_good"] || click_id
      source = SourceClassifier.classify(conn)
      qr = conn.query_params["qr"] == "1"

      # Identity resolution - if it fails, still redirect
      visitor =
        case IdentityResolver.resolve(
               %{click_id: click_id, ga_id: ga_id, source: source},
               workspace_id: link.workspace_id
             ) do
          {:ok, v} -> v
          {:error, _} -> nil
        end

      record_click_if_unique(conn, link, visitor, click_id, source, qr)

      final_destination = build_redirect_url(destination, link, conn, click_id)

      # Fire :link_click hook (sync, crash-isolated)
      hook_results =
        try do
          Hooks.notify_sync(
            :link_click,
            %{
              link: link,
              click_id: click_id,
              source: source,
              qr: qr
            },
            visitor
          )
        rescue
          e ->
            Logger.warning("GoodAnalytics: link_click hook error: #{inspect(e)}")
            []
        end

      conn
      |> apply_hook_cookies(hook_results)
      |> Phoenix.Controller.redirect(external: final_destination)
    else
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> Phoenix.Controller.text("Link not found")

      {:error, :expired} ->
        conn
        |> put_status(410)
        |> Phoenix.Controller.text("Link expired")

      {:error, :invalid_destination} ->
        conn
        |> put_status(400)
        |> Phoenix.Controller.text("Invalid destination URL")
    end
  end

  defp record_click_if_unique(conn, link, visitor, click_id, source, qr) do
    case Deduplication.check(conn, link) do
      {:ok, true} ->
        Links.increment_clicks(link.id, true)

        if visitor do
          Recorder.record_click(visitor, link, %{
            click_id: click_id,
            source: source,
            ip_address: get_client_ip(conn),
            user_agent: get_user_agent(conn),
            referrer: get_referrer(conn),
            qr: qr
          })
        end

      _ ->
        Links.increment_clicks(link.id, false)
    end
  end

  defp validate_destination_url(link, conn) do
    base_url = select_destination(link, conn)
    uri = URI.parse(base_url)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
      {:ok, base_url}
    else
      {:error, :invalid_destination}
    end
  end

  defp select_destination(link, conn) do
    user_agent = get_user_agent(conn) || ""

    cond do
      link.ios_url && ios_device?(user_agent) -> link.ios_url
      link.android_url && android_device?(user_agent) -> link.android_url
      true -> link.url
    end
  end

  defp ios_device?(ua), do: String.contains?(ua, "iPhone") or String.contains?(ua, "iPad")
  defp android_device?(ua), do: String.contains?(ua, "Android")

  @doc """
  Builds the final redirect URL by merging params in priority order:

  1. Destination URL's existing query params (base)
  2. Link-level UTM params (stored on the link record)
  3. Short link request query params (passthrough from the clicked URL)
  4. `ga_id` (always appended, highest priority)

  Higher priority params overwrite lower. This means:
  - Link UTMs override destination UTMs (marketer intent > default)
  - Request passthrough overrides link UTMs (per-click override > per-link default)
  - `ga_id` is always present
  """
  def build_redirect_url(base_url, link, conn, click_id) do
    uri = URI.parse(base_url)
    existing_params = URI.decode_query(uri.query || "")

    link_utms =
      %{}
      |> maybe_put("utm_source", link.utm_source)
      |> maybe_put("utm_medium", link.utm_medium)
      |> maybe_put("utm_campaign", link.utm_campaign)
      |> maybe_put("utm_content", link.utm_content)
      |> maybe_put("utm_term", link.utm_term)

    passthrough = passthrough_params(conn.query_params)

    params =
      existing_params
      |> Map.merge(link_utms)
      |> Map.merge(passthrough)
      |> Map.put("ga_id", click_id)

    %{uri | query: URI.encode_query(params)} |> URI.to_string()
  end

  @excluded_passthrough_params MapSet.new(~w(
    ga_id via ref qr
    gclid gbraid wbraid msclkid fbclid ttclid twclid
    li_fat_id sccid dclid epik irclickid
  ))

  defp passthrough_params(query_params) do
    query_params
    |> Map.reject(fn {k, _v} -> MapSet.member?(@excluded_passthrough_params, k) end)
    |> Enum.filter(fn {k, v} ->
      is_binary(k) and is_binary(v) and
        String.length(k) <= 64 and String.length(v) <= 512
    end)
    |> Enum.take(10)
    |> Map.new()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp apply_hook_cookies(conn, hook_results) do
    Enum.reduce(hook_results, conn, fn
      {:ok, %{set_cookies: cookies}}, conn ->
        Enum.reduce(cookies, conn, fn {name, value, days}, conn ->
          put_resp_cookie(conn, name, value,
            max_age: days * 86_400,
            http_only: true,
            same_site: "Lax",
            secure: true
          )
        end)

      _, conn ->
        conn
    end)
  end

  defp get_client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp get_user_agent(conn) do
    get_req_header(conn, "user-agent") |> List.first()
  end

  defp get_referrer(conn) do
    get_req_header(conn, "referer") |> List.first()
  end
end
