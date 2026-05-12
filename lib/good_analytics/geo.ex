defmodule GoodAnalytics.Geo do
  @moduledoc """
  Facade for IP → geo lookup.

  Reads configuration from `config :good_analytics, :geo`:

      config :good_analytics, :geo,
        provider: GoodAnalytics.Geo.Locus,
        loader: {:maxmind, "GeoLite2-City"},
        normalizer: GoodAnalytics.Geo.Normalizer.MaxMind  # default

  Returns the normalized canonical map (see
  `GoodAnalytics.Geo.Normalizer.normalized`) on success.

  ## Failure modes

    * `{:error, :geo_disabled}` — the `:locus` dependency is not loaded
      OR no `:provider` is configured. Callers SHOULD treat this as
      non-fatal and continue without enrichment.

    * `{:error, :loader_not_ready}` — provider is configured but the
      MMDB loader has not finished initialising (cold start, or fetch
      failure). The redirect path falls back to the link's default URL
      and skips `geo_targeting`.

    * `{:error, :not_found}` — IP did not match any range in the
      loaded database (private/reserved range, etc.).

    * `{:error, {:invalid_ip, value}}` — the input could not be parsed
      as an IP address.
  """

  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Geo.Normalizer
  alias GoodAnalytics.Geo.Normalizer.MaxMind
  alias GoodAnalytics.GeoTaskSupervisor

  require Logger

  @doc """
  Looks up the geo data for an IP.

  Accepts a string, an `:inet.ip_address/0` tuple, or an `EctoNetwork.INET`
  struct.
  """
  @spec lookup(term()) :: {:ok, Normalizer.normalized()} | {:error, term()}
  def lookup(ip) do
    with {:ok, provider} <- fetch_provider(),
         :ok <- ensure_locus_loaded(),
         {:ok, parsed_ip} <- parse_ip(ip),
         {:ok, raw} <- provider.lookup(parsed_ip) do
      {:ok, normalizer().normalize(raw)}
    end
  end

  @doc "True when geo enrichment is configured AND `:locus` is loaded."
  @spec enabled?() :: boolean()
  def enabled? do
    case {fetch_provider(), Code.ensure_loaded?(:locus)} do
      {{:ok, _}, true} -> true
      _ -> false
    end
  end

  # ── Internals ────────────────────────────────────────────────────────────

  defp fetch_provider do
    case Application.get_env(:good_analytics, :geo, [])[:provider] do
      nil -> {:error, :geo_disabled}
      provider -> {:ok, provider}
    end
  end

  defp ensure_locus_loaded do
    if Code.ensure_loaded?(:locus), do: :ok, else: {:error, :geo_disabled}
  end

  defp normalizer do
    Application.get_env(:good_analytics, :geo, [])[:normalizer] || MaxMind
  end

  # ── IP parsing ───────────────────────────────────────────────────────────

  @doc """
  Parses a value into an `:inet.ip_address/0` tuple.

  Accepts:
    * an `:inet.ip_address/0` tuple (passes through)
    * a string (parsed via `:inet.parse_address/1`)
    * a `Postgrex.INET` struct (the underlying type backing `EctoNetwork.INET`
      — `:address` is unwrapped)
  """
  @spec parse_ip(term()) :: {:ok, :inet.ip_address()} | {:error, {:invalid_ip, term()}}
  def parse_ip({a, b, c, d} = ip)
      when is_integer(a) and a in 0..255 and is_integer(b) and b in 0..255 and
             is_integer(c) and c in 0..255 and is_integer(d) and d in 0..255,
      do: {:ok, ip}

  def parse_ip(ip) when is_tuple(ip) and tuple_size(ip) == 8 do
    if Enum.all?(Tuple.to_list(ip), &(is_integer(&1) and &1 in 0..65_535)),
      do: {:ok, ip},
      else: {:error, {:invalid_ip, ip}}
  end

  def parse_ip(%Postgrex.INET{address: addr}), do: parse_ip(addr)

  # 45 bytes covers the longest valid IPv6 textual form
  # (`0000:0000:0000:0000:0000:ffff:255.255.255.255`). Anything longer is
  # rejected without allocating a charlist or invoking `:inet`.
  def parse_ip(ip) when is_binary(ip) and byte_size(ip) <= 45 do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, {:invalid_ip, ip}}
    end
  end

  def parse_ip(other), do: {:error, {:invalid_ip, other}}

  # ── Async enrichment helper ─────────────────────────────────────────────

  @doc """
  Fire-and-forget geo enrichment for a known visitor.

  No-op when geo is not enabled. Tasks run under `GoodAnalytics.GeoTaskSupervisor`
  which is capped at 10,000 in-flight tasks; when the cap is reached the
  enrichment is dropped and a single info-level log line is emitted. Event
  ingest is never affected — enrichment is purely advisory.
  """
  @spec enqueue_enrichment(Ecto.UUID.t(), term()) :: :ok
  def enqueue_enrichment(visitor_id, ip) do
    if enabled?(), do: spawn_enrichment(visitor_id, ip)
    :ok
  end

  defp spawn_enrichment(visitor_id, ip) do
    GeoTaskSupervisor
    |> Task.Supervisor.start_child(fn -> enrich_visitor(visitor_id, ip) end)
    |> handle_spawn_result()
  end

  # Cap reached — enrichment dropped for this event. Logged at info because
  # it's expected under spikes and not actionable per-call.
  defp handle_spawn_result({:error, :max_children}) do
    Logger.info("GoodAnalytics.Geo: enrichment dropped (max_children cap reached)")
    :ok
  end

  # `:noproc` during shutdown, or anything else. Don't crash the caller;
  # we're already past the HTTP response.
  defp handle_spawn_result({:error, reason}) do
    Logger.warning("GoodAnalytics.Geo: enqueue_enrichment failed (#{inspect(reason)}); skipping")

    :ok
  end

  defp handle_spawn_result(_ok_or_ignore), do: :ok

  defp enrich_visitor(visitor_id, ip) do
    case lookup(ip) do
      {:ok, geo} -> handle_set_geo(Visitors.maybe_set_geo(visitor_id, geo))
      _ -> :ok
    end
  end

  defp handle_set_geo({:ok, _}), do: :ok
  defp handle_set_geo(:noop), do: :ok
  defp handle_set_geo({:error, :not_found}), do: :ok

  defp handle_set_geo(other) do
    Logger.warning("GoodAnalytics.Geo: unexpected maybe_set_geo result: #{inspect(other)}")
    :ok
  end
end
