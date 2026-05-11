defmodule GoodAnalytics.Core.Tracking.Plug do
  @moduledoc """
  Phoenix Plug for server-side tracking.

  On each trackable request:
  - Classifies the traffic source
  - Manages ga_id and anonymous cookies
  - Assigns tracking signals to conn for downstream use
  - Sets referrer-policy header

  ## Usage

      plug GoodAnalytics.Core.Tracking.Plug

  """

  @behaviour Plug

  alias GoodAnalytics.Connectors.Signals
  alias GoodAnalytics.Core.Tracking.SourceClassifier

  @ga_cookie "_ga_good"
  @anon_cookie "_ga_anon"
  @cookie_max_age 90 * 86_400

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    if trackable_request?(conn) do
      conn
      |> Plug.Conn.fetch_cookies()
      |> Plug.Conn.fetch_query_params()
      |> classify_source()
      |> manage_cookies()
      |> set_referrer_policy()
      |> assign_signals()
    else
      conn
    end
  end

  defp trackable_request?(conn) do
    conn.method == "GET" and
      not static_asset?(conn.request_path)
  end

  @static_prefixes ~w(/assets /images /fonts)
  @static_extensions ~w(.js .css .ico .png .jpg .svg .woff2)

  defp static_asset?(path) do
    Enum.any?(@static_prefixes, &String.starts_with?(path, &1)) or
      Enum.any?(@static_extensions, &String.ends_with?(path, &1))
  end

  defp classify_source(conn) do
    source = SourceClassifier.classify(conn)
    Plug.Conn.assign(conn, :ga_source, source)
  end

  defp manage_cookies(conn) do
    ga_id = conn.cookies[@ga_cookie] || validate_uuid(conn.query_params["ga_id"])
    anon_id = conn.cookies[@anon_cookie] || generate_anon_id()

    conn
    # NOTE: http_only: false is intentional — the JS client needs to read this cookie
    # for identity reconciliation. XSS mitigation on the host app is critical.
    |> set_cookie(@ga_cookie, ga_id, http_only: false)
    |> set_cookie(@anon_cookie, anon_id, http_only: true)
    |> Plug.Conn.assign(:ga_id, ga_id)
    |> Plug.Conn.assign(:ga_anon_id, anon_id)
  end

  defp set_cookie(conn, _name, nil, _opts), do: conn

  defp set_cookie(conn, name, value, opts) do
    Plug.Conn.put_resp_cookie(conn, name, value,
      max_age: @cookie_max_age,
      http_only: Keyword.get(opts, :http_only, true),
      same_site: "Lax",
      secure: true,
      path: "/"
    )
  end

  defp set_referrer_policy(conn) do
    Plug.Conn.put_resp_header(conn, "referrer-policy", "no-referrer-when-downgrade")
  end

  defp assign_signals(conn) do
    connector_signals = Signals.extract_from_conn(conn)

    signals = %{
      ga_id: conn.assigns[:ga_id],
      anonymous_id: conn.assigns[:ga_anon_id],
      fingerprint: conn.query_params["fp"],
      source: conn.assigns[:ga_source],
      ip_address: conn.remote_ip |> :inet.ntoa() |> to_string(),
      user_agent: Plug.Conn.get_req_header(conn, "user-agent") |> List.first(),
      connector_signals: connector_signals
    }

    Plug.Conn.assign(conn, :ga_signals, signals)
  end

  defp generate_anon_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp validate_uuid(nil), do: nil

  defp validate_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end
end
