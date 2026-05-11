defmodule GoodAnalytics.Core.Tracking.Deduplication do
  @moduledoc """
  IP-based click deduplication.

  Same IP + same link = 1 unique click per hour.
  Uses Nebulex cache (local ETS by default, Replicated for multi-node).
  """

  @cache GoodAnalytics.Cache
  @ttl :timer.seconds(3600)

  @doc """
  Checks if a click is a duplicate.

  Returns `{:ok, true}` if this is a new click, `{:ok, false}` if duplicate.
  """
  def check(conn, link) do
    ip = get_client_ip(conn)
    cache_key = {:click_dedup, ip, link.id}

    case @cache.get(cache_key) do
      nil ->
        @cache.put(cache_key, true, ttl: @ttl)
        {:ok, true}

      _exists ->
        {:ok, false}
    end
  end

  defp get_client_ip(%Plug.Conn{} = conn) do
    # Use conn.remote_ip only — if real client IPs behind a proxy are needed,
    # configure Plug.RewriteOn or RemoteIp at the endpoint level.
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end

  defp get_client_ip(%{ip_address: ip}) when is_binary(ip), do: ip
  defp get_client_ip(_), do: "unknown"
end
