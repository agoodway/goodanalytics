defmodule GoodAnalytics.Core.Tracking.BeaconController do
  @moduledoc """
  Handles beacon POSTs from the JS client and client-side click tracking.
  """

  # NOTE: Rate limiting is expected at the infrastructure level (nginx, CloudFlare, etc.).
  # For application-level rate limiting, consider adding PlugAttack or Hammer.

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias GoodAnalytics.Connectors.Signals
  alias GoodAnalytics.Core.{Events.Event, Events.Recorder, IdentityResolver, Links, Partners}
  alias GoodAnalytics.Core.Partners.Attribution
  alias GoodAnalytics.Core.Tracking.ReferralCookie
  alias GoodAnalytics.Core.Tracking.SourceClassifier
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Geo
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
  @max_url_length 2083
  @max_fingerprint_length 128
  @max_event_name_length 100
  @max_anonymous_id_length 128
  # Maximum number of event properties preserved after sanitization.
  @max_properties 50

  @doc """
  Receives beacon events from the JS snippet.

  Expected payload:
  ```json
  {
    "event_type": "pageview",
    "event_name": "Page View",
    "url": "https://example.com/page",
    "referrer": "https://google.com",
    "fingerprint": "fp_abc",
    "ga_id": "click-123",
    "event_id": "67c12c6e-117a-4c14-94cb-50f62fb81c4e",
    "properties": {}
  }
  ```
  """
  def event(conn, params) do
    workspace_id = workspace_id(conn, params)
    source = ga_source(conn)
    log_beacon_debug(conn, params, source, "event")

    signals = %{
      ga_id: Map.get(params, "ga_id"),
      fingerprint: validate_fingerprint(Map.get(params, "fingerprint")),
      anonymous_id: validate_anonymous_id(Map.get(params, "anonymous_id")),
      source: source
    }

    case IdentityResolver.resolve(signals, workspace_id: workspace_id) do
      {:ok, visitor} ->
        reconcile_only? = reconcile_only?(params)

        _ =
          Recorder.backfill_link_click_fingerprint(
            Map.get(params, "ga_id"),
            validate_fingerprint(Map.get(params, "fingerprint"))
          )

        event_type = Map.get(params, "event_type", "pageview")

        cond do
          event_type not in Event.ingest_types() ->
            conn
            |> put_status(422)
            |> json(%{status: "error", message: "invalid event_type"})

          reconcile_only? ->
            json(conn, %{status: "ok"})

          true ->
            # Extract connector signals from JS payload and merge with server signals
            js_signals = Signals.extract_from_payload(params)

            server_signals = connector_signals(conn.assigns[:ga_signals])
            connector_signals = Signals.merge([server_signals, js_signals])

            # Derive referral context from payload token or visitor state
            referral_attrs = derive_referral_context(visitor, params)

            event_attrs =
              %{
                url: sanitize_url(Map.get(params, "url")),
                referrer: sanitize_url(Map.get(params, "referrer")),
                event_name: validate_event_name(Map.get(params, "event_name")),
                source: source,
                properties: sanitize_properties(Map.get(params, "properties", %{})),
                event_id: validate_event_id(Map.get(params, "event_id")),
                fingerprint: validate_fingerprint(Map.get(params, "fingerprint")),
                ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
                user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
                connector_signals: connector_signals
              }
              |> Map.merge(referral_attrs)

            Recorder.record(visitor, event_type, event_attrs)
            Geo.enqueue_enrichment(visitor.id, conn.remote_ip)
            json(conn, %{status: "ok"})
        end

      {:error, reason} ->
        Logger.warning("GoodAnalytics: identity resolution failed in beacon: #{inspect(reason)}")
        json(conn, %{status: "ok"})
    end
  end

  @doc """
  Handles client-side click tracking (via= param flow).

  Expected payload:
  ```json
  {
    "key": "john",
    "fingerprint": "fp_abc",
    "url": "https://example.com/pricing?via=john",
    "referrer": "https://twitter.com"
  }
  ```

  Returns `{ga_id: "...", visitor_id: "..."}`.
  """
  def click(conn, params) do
    key = Map.get(params, "key")
    tenant_workspace_id = conn.private[:workspace_id]
    domain = click_domain(conn, params, tenant_workspace_id)

    case Links.resolve_live_link(domain, key) do
      {:error, :not_found} ->
        conn
        |> put_status(404)
        |> json(%{status: "error", message: "Link not found"})

      {:error, :expired} ->
        conn
        |> put_status(410)
        |> json(%{status: "error", message: "Link expired"})

      {:ok, link} ->
        handle_click(conn, params, link, tenant_workspace_id)
    end
  end

  defp handle_click(conn, params, link, tenant_workspace_id) do
    click_id = Uniq.UUID.uuid7()

    workspace_id =
      tenant_workspace_id ||
        validate_workspace_id(params["workspace_id"]) ||
        link.workspace_id ||
        GoodAnalytics.default_workspace_id()

    # Validate referral partner if this is a referral link
    referral_context = build_referral_context(link, click_id)
    source = ga_source(conn)
    log_beacon_debug(conn, params, source, "click")

    signals = %{
      click_id: click_id,
      fingerprint: validate_fingerprint(Map.get(params, "fingerprint")),
      anonymous_id: validate_anonymous_id(Map.get(params, "anonymous_id")),
      source: source
    }

    case IdentityResolver.resolve(signals, workspace_id: workspace_id) do
      {:ok, visitor} ->
        # Update visitor partner attribution for referral clicks
        if referral_context do
          Attribution.set_partner_attribution(visitor.id, referral_context)
        end

        click_attrs =
          %{
            click_id: click_id,
            source: source,
            ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
            user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
            url: sanitize_url(Map.get(params, "url")),
            referrer: sanitize_url(Map.get(params, "referrer"))
          }
          |> Attribution.merge_into_attrs(referral_context)

        case Recorder.record_click(visitor, link, click_attrs) do
          {:ok, _event} -> Links.increment_clicks(link.id, true)
          {:error, _changeset} -> :ok
        end

        Geo.enqueue_enrichment(visitor.id, conn.remote_ip)

        response = %{status: "ok", ga_id: click_id, visitor_id: visitor.id}

        conn
        |> Attribution.maybe_set_cookie(referral_context)
        |> json(response)

      {:error, _reason} ->
        json(conn, %{status: "ok", ga_id: click_id})
    end
  end

  defp derive_referral_context(%Visitor{} = visitor, params) do
    # Priority: payload token > visitor last_partner attribution
    case verify_payload_ref_token(params) do
      {:ok, context} ->
        Map.take(context, [:partner_id, :referral_link_id, :referral_click_id])

      {:error, _} ->
        if visitor.last_partner_id do
          %{
            partner_id: visitor.last_partner_id,
            referral_link_id: visitor.last_referral_link_id,
            referral_click_id: visitor.last_referral_click_id
          }
        else
          %{}
        end
    end
  end

  defp verify_payload_ref_token(%{"_ga_ref" => token}) when is_binary(token) do
    ReferralCookie.verify(token)
  end

  defp verify_payload_ref_token(_), do: {:error, :not_present}

  # Use an upstream-assigned source (e.g. Pro's Ingest.Filter) when present;
  # otherwise classify from this request so bare hosts still get attribution.
  defp ga_source(conn), do: conn.assigns[:ga_source] || SourceClassifier.classify(conn)

  defp build_referral_context(%{link_type: "referral", partner_id: pid} = link, click_id)
       when is_binary(pid) do
    case Partners.get_active_partner(link.workspace_id, pid) do
      nil ->
        nil

      _partner ->
        %{
          partner_id: pid,
          referral_link_id: link.id,
          referral_click_id: click_id,
          workspace_id: link.workspace_id
        }
    end
  end

  defp build_referral_context(_link, _click_id), do: nil

  defp workspace_id(conn, params) do
    conn.private[:workspace_id] ||
      validate_workspace_id(params["workspace_id"]) ||
      GoodAnalytics.default_workspace_id()
  end

  defp click_domain(conn, _params, workspace_id) when is_binary(workspace_id),
    do: request_host(conn)

  defp click_domain(conn, _params, _workspace_id), do: request_host(conn)

  defp connector_signals(%{connector_signals: connector_signals}) when is_map(connector_signals),
    do: connector_signals

  defp connector_signals(_signals), do: %{}

  defp request_host(%Plug.Conn{host: host, port: port}) when port in [80, 443], do: host

  defp request_host(%Plug.Conn{host: host, port: port}) when is_integer(port),
    do: "#{host}:#{port}"

  defp request_host(%Plug.Conn{host: host}), do: host

  defp reconcile_only?(params) do
    truthy?(Map.get(params, "reconcile_only")) or
      truthy?(get_in(params, ["properties", "reconcile_only"]))
  end

  defp truthy?(value) when value in [true, "true", 1, "1"], do: true
  defp truthy?(_), do: false

  defp sanitize_url(nil), do: nil
  defp sanitize_url(val) when is_binary(val), do: String.slice(val, 0, @max_url_length)
  defp sanitize_url(_), do: nil

  defp validate_fingerprint(nil), do: nil

  defp validate_fingerprint(fp) when is_binary(fp), do: fp |> String.trim() |> valid_fingerprint()

  defp validate_fingerprint(_), do: nil

  defp valid_fingerprint(fp) when fp != "" and byte_size(fp) <= @max_fingerprint_length, do: fp
  defp valid_fingerprint(_fp), do: nil

  defp validate_event_name(name) when is_binary(name) do
    trimmed = String.trim(name)
    if trimmed != "" and byte_size(trimmed) <= @max_event_name_length, do: trimmed, else: nil
  end

  defp validate_event_name(_), do: nil

  defp validate_anonymous_id(id) when is_binary(id) do
    trimmed = String.trim(id)
    if trimmed != "" and byte_size(trimmed) <= @max_anonymous_id_length, do: trimmed, else: nil
  end

  defp validate_anonymous_id(_), do: nil

  defp validate_event_id(nil), do: nil

  defp validate_event_id(value) when is_binary(value) do
    if Regex.match?(@uuid_regex, value), do: value, else: nil
  end

  defp validate_event_id(_), do: nil

  defp sanitize_properties(props) when is_map(props) do
    props
    |> Enum.filter(fn {k, v} ->
      is_binary(k) and (is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v))
    end)
    |> Enum.take(@max_properties)
    |> Map.new()
  end

  defp sanitize_properties(_), do: %{}

  defp validate_workspace_id(nil), do: nil

  defp validate_workspace_id(val) when is_binary(val) do
    if Regex.match?(@uuid_regex, val), do: val, else: nil
  end

  defp validate_workspace_id(_), do: nil

  # --- Temporary beacon diagnostics (opt-in) -------------------------------
  #
  # Logs one structured line per inbound beacon comparing three views of the
  # same request: the server-read REQUEST HEADERS (User-Agent, Referer, the
  # CDN/edge forwarding headers, query string), the JS-supplied BODY (url,
  # referrer, event_type, event_name), and the COMPUTED source classification.
  #
  # This exists to diagnose attribution loss behind a CDN/edge rewrite (Vercel,
  # Cloudflare, etc.) where a request is re-originated and header-derived signals
  # (UA/Referer/IP) may differ from what the browser actually sent in the body.
  # Compare `hdr_ua`/`hdr_referer` against `body_url`/`body_referrer` to see what
  # survives, and `body_event_name` to confirm the JS payload arrives intact.
  #
  # Disabled by default. Enable per environment without a code change via either:
  #   config :good_analytics, debug_beacon: true
  #   # or an env var wired in the host app, e.g.
  #   GOODANALYTICS_DEBUG_BEACON=1
  # Grep the logs for the `ga_beacon` tag. Remove once the fix is designed.
  defp log_beacon_debug(conn, params, source, endpoint) do
    if debug_beacon_enabled?() do
      hdr = fn name -> conn |> Plug.Conn.get_req_header(name) |> List.first() end

      Logger.info(
        # body_keys=0 with a present content-type means the JSON body did not
        # parse (e.g. an edge rewrite changed content-type) vs. headers stripped.
        "ga_beacon endpoint=#{endpoint} " <>
          "remote_ip=#{conn.remote_ip |> :inet.ntoa() |> to_string()} " <>
          "hdr_ua=#{inspect(truncate_log(hdr.("user-agent")))} " <>
          "hdr_referer=#{inspect(truncate_log(hdr.("referer")))} " <>
          "hdr_ct=#{inspect(hdr.("content-type"))} " <>
          "hdr_xff=#{inspect(hdr.("x-forwarded-for"))} " <>
          "hdr_xvff=#{inspect(hdr.("x-vercel-forwarded-for"))} " <>
          "hdr_cf=#{inspect(hdr.("cf-connecting-ip"))} " <>
          "hdr_host=#{inspect(hdr.("host"))} " <>
          "qs=#{inspect(truncate_log(conn.query_string))} " <>
          "body_keys=#{map_size(params)} " <>
          "body_event_type=#{inspect(Map.get(params, "event_type"))} " <>
          "body_event_name=#{inspect(Map.get(params, "event_name"))} " <>
          "body_url=#{inspect(truncate_log(Map.get(params, "url")))} " <>
          "body_referrer=#{inspect(truncate_log(Map.get(params, "referrer")))} " <>
          "source_assigned=#{not is_nil(conn.assigns[:ga_source])} " <>
          "source=#{inspect(source)}"
      )
    end
  rescue
    # Diagnostics must never break ingestion.
    _ -> :ok
  end

  defp debug_beacon_enabled? do
    Application.get_env(:good_analytics, :debug_beacon, false) or
      System.get_env("GOODANALYTICS_DEBUG_BEACON") in ["1", "true"]
  end

  defp truncate_log(nil), do: nil
  defp truncate_log(value) when is_binary(value), do: String.slice(value, 0, 256)
  defp truncate_log(value), do: value
end
