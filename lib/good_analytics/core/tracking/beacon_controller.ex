defmodule GoodAnalytics.Core.Tracking.BeaconController do
  @moduledoc """
  Handles beacon POSTs from the JS client and client-side click tracking.
  """

  # NOTE: Rate limiting is expected at the infrastructure level (nginx, CloudFlare, etc.).
  # For application-level rate limiting, consider adding PlugAttack or Hammer.

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias GoodAnalytics.Connectors.Signals
  alias GoodAnalytics.Core.{Events.Recorder, IdentityResolver, Links}
  alias GoodAnalytics.Geo

  @valid_event_types ~w(link_click pageview session_start identify lead sale share engagement custom)
  @uuid_regex ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

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

    signals = %{
      ga_id: Map.get(params, "ga_id"),
      fingerprint: validate_fingerprint(Map.get(params, "fingerprint")),
      anonymous_id: Map.get(params, "anonymous_id"),
      source: conn.assigns[:ga_source]
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
          event_type not in @valid_event_types ->
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

            event_attrs = %{
              url: sanitize_url(Map.get(params, "url")),
              referrer: sanitize_url(Map.get(params, "referrer")),
              source: conn.assigns[:ga_source],
              properties: sanitize_properties(Map.get(params, "properties", %{})),
              event_id: validate_event_id(Map.get(params, "event_id")),
              fingerprint: validate_fingerprint(Map.get(params, "fingerprint")),
              ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
              user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
              connector_signals: connector_signals
            }

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

    signals = %{
      click_id: click_id,
      fingerprint: validate_fingerprint(Map.get(params, "fingerprint")),
      anonymous_id: Map.get(params, "anonymous_id"),
      source: conn.assigns[:ga_source]
    }

    case IdentityResolver.resolve(signals, workspace_id: workspace_id) do
      {:ok, visitor} ->
        record_result =
          Recorder.record_click(visitor, link, %{
            click_id: click_id,
            source: conn.assigns[:ga_source],
            ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
            user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
            url: sanitize_url(Map.get(params, "url")),
            referrer: sanitize_url(Map.get(params, "referrer"))
          })

        case record_result do
          {:ok, _event} ->
            Links.increment_clicks(link.id, true)

          {:error, _changeset} ->
            :ok
        end

        Geo.enqueue_enrichment(visitor.id, conn.remote_ip)

        json(conn, %{
          status: "ok",
          ga_id: click_id,
          visitor_id: visitor.id
        })

      {:error, _reason} ->
        json(conn, %{status: "ok", ga_id: click_id})
    end
  end

  defp workspace_id(conn, params) do
    conn.private[:workspace_id] ||
      validate_workspace_id(params["workspace_id"]) ||
      GoodAnalytics.default_workspace_id()
  end

  defp click_domain(conn, _params, workspace_id) when is_binary(workspace_id),
    do: request_host(conn)

  defp click_domain(conn, params, _workspace_id), do: Map.get(params, "domain", conn.host)

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

  @max_url_length 2048
  @max_fingerprint_length 128
  # Maximum number of event properties preserved after sanitization.
  @max_properties 50

  defp sanitize_url(nil), do: nil
  defp sanitize_url(val) when is_binary(val), do: String.slice(val, 0, @max_url_length)
  defp sanitize_url(_), do: nil

  defp validate_fingerprint(nil), do: nil

  defp validate_fingerprint(fp) when is_binary(fp), do: fp |> String.trim() |> valid_fingerprint()

  defp validate_fingerprint(_), do: nil

  defp valid_fingerprint(fp) when fp != "" and byte_size(fp) <= @max_fingerprint_length, do: fp
  defp valid_fingerprint(_fp), do: nil

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
end
