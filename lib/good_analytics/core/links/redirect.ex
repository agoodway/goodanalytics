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

  ## Geo routing callback

  When `link.geo_targeting` is non-empty, the redirect path consults the
  configured `:geo_routing_enabled_fn` callback to decide whether to apply
  country-based routing. The callback shape is `{Module, :function}` and
  must accept a `workspace_id :: Ecto.UUID.t()`.

  Contract:
    * **MUST** return a boolean.
    * **MUST NOT** raise. A raise propagates and the redirect 500s — this
      is host-app misconfiguration that should be fixed, not silently
      swallowed. Cache lookups (e.g. via Nebulex) keep this hot.
  """

  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Links.Link
  alias GoodAnalytics.Core.Tracking.{Deduplication, SourceClassifier}
  alias GoodAnalytics.Geo
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

      geo_map = lookup_geo(conn.remote_ip)
      signals = build_signals(click_id, ga_id, source, geo_map)
      visitor = resolve_visitor(signals, link.workspace_id)

      record_click_if_unique(conn, link, visitor, click_id, source, qr)

      final_destination = build_redirect_url(destination, link, conn, click_id, geo_map)

      hook_results =
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

  defp lookup_geo(remote_ip) do
    case Geo.lookup(remote_ip) do
      {:ok, geo} -> geo
      _ -> nil
    end
  end

  defp build_signals(click_id, ga_id, source, nil),
    do: %{click_id: click_id, ga_id: ga_id, source: source}

  defp build_signals(click_id, ga_id, source, geo_map),
    do: %{click_id: click_id, ga_id: ga_id, source: source, geo: geo_map}

  defp resolve_visitor(signals, workspace_id) do
    case IdentityResolver.resolve(signals, workspace_id: workspace_id) do
      {:ok, visitor} -> visitor
      {:error, _} -> nil
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

    if Link.valid_http_url?(base_url),
      do: {:ok, base_url},
      else: {:error, :invalid_destination}
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

  When `geo_map` is provided AND the workspace has geo routing enabled via the
  host-app `:geo_routing_enabled_fn` callback AND `link.geo_targeting` maps the
  resolved country code to a non-empty URL, that URL replaces the device-
  targeted/default destination before params are merged.
  """
  def build_redirect_url(base_url, link, conn, click_id, geo_map \\ nil) do
    base_url = maybe_geo_route(base_url, link, geo_map)

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

  defp maybe_geo_route(base_url, _link, nil), do: base_url

  defp maybe_geo_route(base_url, link, geo_map) do
    if geo_routing_enabled?(link.workspace_id),
      do: geo_routed_url(link, geo_map, base_url),
      else: base_url
  end

  # Resolves a country-routed URL from `link.geo_targeting`. Keys are stored
  # uppercase ISO-3166-1 alpha-2 (enforced by the link changeset); we upcase
  # the resolved country code at lookup time so providers that emit lowercase
  # still match. When a country-specific URL is available, it OVERRIDES any
  # device-specific URL chosen by `select_destination/2` — a German visitor
  # on iOS gets the German page, not the iOS page.
  defp geo_routed_url(%{geo_targeting: targeting} = link, %{country_code: cc}, fallback)
       when is_map(targeting) and is_binary(cc) and cc != "" do
    targeting
    |> Map.get(String.upcase(cc))
    |> resolve_geo_target_url(link, cc, fallback)
  end

  defp geo_routed_url(_, _, fallback), do: fallback

  # Defense-in-depth: the changeset already rejects non-HTTP(S) URLs, but a
  # raw SQL write or stale data could still slip through. A bad URL falls
  # back to the device/default destination and logs a single warning.
  defp resolve_geo_target_url(url, link, cc, fallback) when is_binary(url) and url != "" do
    if Link.valid_http_url?(url),
      do: url,
      else: log_invalid_geo_url(link, cc, fallback)
  end

  defp resolve_geo_target_url(_url, _link, _cc, fallback), do: fallback

  defp log_invalid_geo_url(link, cc, fallback) do
    Logger.warning(
      "GoodAnalytics: geo_targeting URL failed scheme/host check; falling back. " <>
        "link_id=#{inspect(link.id)} cc=#{cc}"
    )

    fallback
  end

  # Calls the host-app `:geo_routing_enabled_fn` callback. Defaults to `false`
  # so links never silently start routing by country — operators must explicitly
  # opt in. Callback contract is documented in the @moduledoc; it MUST return
  # a boolean and MUST NOT raise.
  defp geo_routing_enabled?(workspace_id) do
    case Application.get_env(:good_analytics, :geo_routing_enabled_fn) do
      {mod, fun} -> apply(mod, fun, [workspace_id]) == true
      _ -> false
    end
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
