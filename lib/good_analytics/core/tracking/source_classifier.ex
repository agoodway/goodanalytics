defmodule GoodAnalytics.Core.Tracking.SourceClassifier do
  @moduledoc """
  Classifies the source of an inbound request.

  Classification priority (highest to lowest):
  1. Platform click IDs (gclid, fbclid, etc.) — highest confidence
  2. GoodAnalytics params (via=, ref=) — referral tracking
  3. UTM parameters — explicit marketer intent
  4. Referer header — domain-based classification

  A referer on the page's own host (`www.` ignored) or on a configured internal
  host is internal navigation, not a source: `classify/2` returns `nil` for it,
  the same as for ignored hand-off hosts (`nil` is the one "no source" result:
  callers keep the visitor's previous source). It is only considered when no
  click id, `via`/`ref` param or UTM matched; explicit intent still wins.

  Internal hosts are the `:page_host` option plus `:internal_hosts` (option, or
  `config :good_analytics, internal_hosts: ["go.example.com"]`, read at call
  time). `internal_hosts` should list ALL of a site's own domains, short-link
  and alias domains included, since only the page's own host is known
  automatically. Hosts compare lowercase, ignoring `www.` and any port.

  Referer hosts, UTM source names and display names come from the vendored
  referrer database (`GoodAnalytics.Core.Tracking.Referers`). Compile-time
  defaults for click ID params can be overridden, and the referer lookup
  extended, at runtime via the `:overrides` option.
  """

  alias GoodAnalytics.Core.Events.UrlNormalizer
  alias GoodAnalytics.Core.Tracking.Referers
  alias GoodAnalytics.Text

  @email_sources ~w(newsletter email)

  @click_id_params %{
    "gclid" => {:google_ads, :paid},
    "gbraid" => {:google_ads, :paid},
    "wbraid" => {:google_ads, :paid},
    "msclkid" => {:microsoft_ads, :paid},
    "fbclid" => {:facebook, :social},
    "ttclid" => {:tiktok, :paid},
    "twclid" => {:twitter_ads, :paid},
    "li_fat_id" => {:linkedin_ads, :paid},
    "sccid" => {:snapchat_ads, :paid},
    "dclid" => {:google_display, :paid},
    "epik" => {:pinterest_ads, :paid},
    "irclickid" => {:impact_radius, :affiliate}
  }

  @doc """
  Classifies the source of an inbound request.

  Accepts a `Plug.Conn` or a map with `:query_params` and `:referer` keys.

  ## Options

    * `:overrides` - map with optional `:click_id_params` (replaces the
      defaults) and `:referer_map` (exact-domain entries consulted before the
      vendored referrer database).

    * `:page_host` - host of the page being visited. A referer on this host is
      internal navigation.
    * `:internal_hosts` - extra hosts treated as internal. Defaults to
      `Application.get_env(:good_analytics, :internal_hosts, [])`.

  Returns a map with source classification fields, or `nil` when there is no
  source (internal navigation, or an ignored hand-off host).
  """
  def classify(conn_or_map, opts \\ [])

  def classify(%Plug.Conn{} = conn, opts) do
    classify(
      %{
        query_params: conn.query_params,
        referer: Plug.Conn.get_req_header(conn, "referer") |> List.first()
      },
      opts
    )
  end

  def classify(%{query_params: params} = data, opts) do
    referer = Map.get(data, :referer)
    overrides = Keyword.get(opts, :overrides, %{})

    click_id_map = Map.get(overrides, :click_id_params, @click_id_params)
    ref_map = Map.get(overrides, :referer_map, %{})

    captured_click_ids = capture_all_click_ids(params, click_id_map)
    click_id_source = detect_primary_click_id(params, click_id_map)
    utm_source = parse_utms(params)
    utm_intent = if match?(%{medium: _}, utm_source), do: utm_source
    ga_source = detect_ga_params(params)

    if internal_navigation?(referer, [click_id_source, ga_source, utm_intent], opts) do
      nil
    else
      referer_source = classify_referer(referer, ref_map)

      case merge_sources(click_id_source, ga_source, utm_source, referer_source) do
        %{medium: _} = merged -> Map.put(merged, :captured_click_ids, captured_click_ids)
        _no_source -> nil
      end
    end
  end

  @doc """
  Classifies a tracker beacon payload (`"url"` and `"referrer"` keys).

  Builds the signal from the page URL's query string and the document referrer,
  with the page URL's host as `:page_host`. Accepts the same options as
  `classify/2`. Returns `nil` when there is no source.
  """
  @spec classify_beacon(map(), keyword()) :: map() | nil
  def classify_beacon(params, opts \\ []) when is_map(params) do
    url = Map.get(params, "url")

    classify(
      %{query_params: url_query_params(url), referer: Map.get(params, "referrer")},
      Keyword.put_new(opts, :page_host, page_host(url))
    )
  end

  @doc """
  Returns true when `referer` is on one of `hosts`.

  Hosts compare lowercase with `www.`, port and trailing dot ignored. Nil,
  blank and unparseable referers are never internal.
  """
  @spec internal_referer?(String.t() | nil, [String.t() | nil]) :: boolean()
  def internal_referer?(referer, hosts) when is_binary(referer) and is_list(hosts) do
    case comparable_host(referer) do
      nil -> false
      host -> host in Enum.flat_map(hosts, &List.wrap(comparable_host(&1)))
    end
  end

  def internal_referer?(_referer, _hosts), do: false

  @doc """
  Returns true when a destination URL (or bare host) is on one of `hosts`.

  The same comparison as `internal_referer?/2`, named for ownership of a link
  destination rather than the origin of a visit.
  """
  @spec same_site?(String.t() | nil, [String.t() | nil]) :: boolean()
  def same_site?(url_or_host, hosts), do: internal_referer?(url_or_host, hosts)

  @doc """
  The configured internal hosts: `config :good_analytics, internal_hosts: [...]`,
  read at call time.
  """
  @spec internal_hosts() :: [String.t()]
  def internal_hosts, do: List.wrap(Application.get_env(:good_analytics, :internal_hosts, []))

  @doc """
  Captures all recognized ad platform click IDs from query params.

  Returns a map of `%{"gclid" => "value", "fbclid" => "value"}`.
  """
  def capture_all_click_ids(params, click_id_map \\ @click_id_params) do
    Enum.reduce(click_id_map, %{}, fn {param, _}, acc ->
      case Map.get(params, param) do
        nil -> acc
        value -> Map.put(acc, param, value)
      end
    end)
  end

  @doc """
  Normalizes UTM medium values to canonical forms.

  - cpc, ppc, paid -> :paid
  - email -> :email
  - social -> :social
  - organic -> :organic
  - referral -> :referral
  - affiliate -> :affiliate
  - anything else -> passed through as-is
  """
  def normalize_medium(m) when m in ["cpc", "ppc", "paid"], do: :paid
  def normalize_medium("email"), do: :email
  def normalize_medium("social"), do: :social
  def normalize_medium("organic"), do: :organic
  def normalize_medium("referral"), do: :referral
  def normalize_medium("affiliate"), do: :affiliate
  def normalize_medium(other), do: other

  # -- Private --

  defp internal_navigation?(referer, explicit_sources, opts) do
    Enum.all?(explicit_sources, &is_nil/1) and
      internal_referer?(referer, request_hosts(opts))
  end

  defp request_hosts(opts) do
    configured = Keyword.get_lazy(opts, :internal_hosts, &internal_hosts/0)
    [Keyword.get(opts, :page_host) | List.wrap(configured)]
  end

  defp page_host(url) when is_binary(url), do: UrlNormalizer.host(url)
  defp page_host(_url), do: nil

  defp url_query_params(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{query: query} when is_binary(query) ->
        query |> URI.decode_query() |> drop_invalid_utf8()

      _uri ->
        %{}
    end
  end

  defp url_query_params(_url), do: %{}

  # A percent-escape can decode to invalid UTF-8 (`%E9`), which later string
  # and regex work raises on; such a pair carries nothing usable.
  defp drop_invalid_utf8(params) do
    Map.filter(params, fn {key, value} -> String.valid?(key) and String.valid?(value) end)
  end

  # Single-label dev hosts such as `localhost` are comparable too.
  defp comparable_host(value) when is_binary(value),
    do: Referers.bare_host(value, allow_single_label: true)

  defp comparable_host(_value), do: nil

  defp detect_primary_click_id(params, click_id_map) do
    Enum.find_value(click_id_map, fn {param, {platform, medium}} ->
      case Map.get(params, param) do
        nil ->
          nil

        value ->
          %{
            platform: platform,
            medium: medium,
            click_id_type: param,
            click_id_value: value,
            confidence: :high
          }
      end
    end)
  end

  # With no `utm_source` and no `utm_medium` there is no source or medium to
  # assert, so a campaign-only map is returned (no `:platform`/`:medium` keys):
  # the referer, or direct, supplies those and the campaign is carried through.
  defp parse_utms(params) do
    utms = Map.take(params, ~w(utm_source utm_medium utm_campaign utm_content utm_term))
    raw_source = utm_value(utms, "utm_source")
    raw_medium = utm_value(utms, "utm_medium")

    cond do
      map_size(utms) == 0 ->
        nil

      is_nil(raw_source) and is_nil(raw_medium) ->
        utm_extras(utms)

      true ->
        {platform, medium} = utm_platform_and_medium(raw_source, raw_medium)

        Map.merge(utm_extras(utms), %{platform: platform, medium: medium, confidence: :medium})
    end
  end

  defp utm_value(utms, key) do
    case Map.get(utms, key) do
      value when is_binary(value) -> Text.blank_to_nil(value)
      _other -> nil
    end
  end

  defp utm_extras(utms) do
    %{
      campaign: Map.get(utms, "utm_campaign"),
      content: Map.get(utms, "utm_content"),
      term: Map.get(utms, "utm_term")
    }
  end

  # A known `utm_source` (host or alias) becomes its canonical platform atom so
  # it agrees with the referer path. AI assistants are always `:ai`; other
  # known platforms keep the marketer's `utm_medium`. Without a `utm_medium`
  # the medium is inferred: the platform's own medium, `:email` for the generic
  # `newsletter`/`email` sources, else `:referral`. Unknown sources keep the raw
  # string. The medium is never `"unknown"`.
  defp utm_platform_and_medium(raw_source, raw_medium) do
    case Referers.resolve(raw_source) do
      %{platform: platform, medium: :ai} -> {platform, :ai}
      %{platform: platform} = known -> {platform, resolve_medium(raw_medium, known.medium)}
      nil -> {raw_source, resolve_medium(raw_medium, generic_source_medium(raw_source))}
    end
  end

  defp resolve_medium(nil, inferred), do: inferred

  defp resolve_medium(medium, _inferred),
    do: medium |> String.trim() |> String.downcase() |> normalize_medium()

  defp generic_source_medium(source) when is_binary(source) do
    if String.downcase(String.trim(source)) in @email_sources, do: :email, else: :referral
  end

  defp generic_source_medium(_source), do: :referral

  defp classify_referer(nil, _ref_map),
    do: %{platform: :direct, medium: :direct, confidence: :low}

  defp classify_referer("", _ref_map),
    do: %{platform: :direct, medium: :direct, confidence: :low}

  defp classify_referer(referer, ref_map) do
    case Referers.bare_host(referer) do
      nil -> classify_referer(nil, ref_map)
      domain -> classify_host(referer, domain, ref_map)
    end
  end

  defp classify_host(referer, domain, ref_map) do
    case lookup_domain(domain, ref_map) do
      {_platform, :ignore} ->
        nil

      {platform, medium} ->
        %{
          platform: platform,
          medium: medium,
          referer_domain: domain,
          referer_url: referer,
          confidence: :medium
        }

      nil ->
        %{
          platform: :referral,
          medium: :referral,
          referer_domain: domain,
          referer_url: referer,
          confidence: :low
        }
    end
  end

  defp lookup_domain(domain, ref_map) do
    case Map.fetch(ref_map, domain) do
      {:ok, found} -> found
      :error -> vendored_lookup(domain)
    end
  end

  defp vendored_lookup(domain) do
    case Referers.lookup(domain) do
      %{platform: platform, medium: medium} -> {platform, medium}
      nil -> nil
    end
  end

  defp detect_ga_params(params) do
    cond do
      via = Map.get(params, "via") -> %{partner_code: via, medium: :referral}
      ref = Map.get(params, "ref") -> %{partner_code: ref, medium: :referral}
      true -> nil
    end
  end

  # Merge priority: click_id > GA params > UTM > referer
  # Higher priority sources are merged LAST so they overwrite lower priority.
  defp merge_sources(click_id, ga, utm, referer) do
    [referer, utm, ga, click_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end
end
