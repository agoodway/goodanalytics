defmodule GoodAnalytics.Core.Tracking.SourceClassifier do
  @moduledoc """
  Classifies the source of an inbound request.

  Classification priority (highest to lowest):
  1. Platform click IDs (gclid, fbclid, etc.) — highest confidence
  2. GoodAnalytics params (via=, ref=) — referral tracking
  3. UTM parameters — explicit marketer intent
  4. Referer header — domain-based classification

  Compile-time defaults for click ID params and referer map can be
  overridden at runtime via `GoodAnalytics.Settings`.
  """

  @click_id_params %{
    "gclid" => {:google_ads, :paid},
    "gbraid" => {:google_ads, :paid},
    "wbraid" => {:google_ads, :paid},
    "msclkid" => {:microsoft_ads, :paid},
    "fbclid" => {:meta, :social},
    "ttclid" => {:tiktok, :paid},
    "twclid" => {:twitter_ads, :paid},
    "li_fat_id" => {:linkedin_ads, :paid},
    "sccid" => {:snapchat_ads, :paid},
    "dclid" => {:google_display, :paid},
    "epik" => {:pinterest_ads, :paid},
    "irclickid" => {:impact_radius, :affiliate}
  }

  @referer_map %{
    # Social
    "facebook.com" => {:facebook, :social},
    "m.facebook.com" => {:facebook, :social},
    "l.facebook.com" => {:facebook, :social},
    "lm.facebook.com" => {:facebook, :social},
    "fb.com" => {:facebook, :social},
    "fb.me" => {:facebook, :social},
    "instagram.com" => {:instagram, :social},
    "l.instagram.com" => {:instagram, :social},
    "t.co" => {:twitter, :social},
    "twitter.com" => {:twitter, :social},
    "x.com" => {:twitter, :social},
    "linkedin.com" => {:linkedin, :social},
    "lnkd.in" => {:linkedin, :social},
    "youtube.com" => {:youtube, :social},
    "youtu.be" => {:youtube, :social},
    "reddit.com" => {:reddit, :social},
    "old.reddit.com" => {:reddit, :social},
    "out.reddit.com" => {:reddit, :social},
    "tiktok.com" => {:tiktok, :social},
    "pinterest.com" => {:pinterest, :social},
    "threads.net" => {:threads, :social},
    "bsky.app" => {:bluesky, :social},
    # Search
    "google.com" => {:google, :organic},
    "google.co.uk" => {:google, :organic},
    "bing.com" => {:bing, :organic},
    "duckduckgo.com" => {:duckduckgo, :organic},
    "yahoo.com" => {:yahoo, :organic},
    "baidu.com" => {:baidu, :organic},
    # Email
    "mail.google.com" => {:gmail, :email},
    "outlook.live.com" => {:outlook, :email},
    "outlook.office.com" => {:outlook, :email},
    "mail.yahoo.com" => {:yahoo_mail, :email},
    # Messaging
    "web.whatsapp.com" => {:whatsapp, :messaging},
    "web.telegram.org" => {:telegram, :messaging},
    "slack.com" => {:slack, :messaging},
    "app.slack.com" => {:slack, :messaging},
    "discord.com" => {:discord, :messaging}
  }

  @doc """
  Classifies the source of an inbound request.

  Accepts a `Plug.Conn` or a map with `:query_params` and `:referer` keys.

  ## Options

    * `:overrides` - map with optional `:click_id_params` and `:referer_map`
      keys to override compile-time defaults.

  Returns a map with source classification fields.
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
    ref_map = Map.get(overrides, :referer_map, @referer_map)

    captured_click_ids = capture_all_click_ids(params, click_id_map)
    click_id_source = detect_primary_click_id(params, click_id_map)
    utm_source = parse_utms(params)
    referer_source = classify_referer(referer, ref_map)
    ga_source = detect_ga_params(params)

    merge_sources(click_id_source, ga_source, utm_source, referer_source)
    |> Map.put(:captured_click_ids, captured_click_ids)
  end

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

  defp parse_utms(params) do
    utms = Map.take(params, ~w(utm_source utm_medium utm_campaign utm_content utm_term))

    if map_size(utms) > 0 do
      %{
        platform: Map.get(utms, "utm_source"),
        medium: normalize_medium(Map.get(utms, "utm_medium", "unknown")),
        campaign: Map.get(utms, "utm_campaign"),
        content: Map.get(utms, "utm_content"),
        term: Map.get(utms, "utm_term"),
        confidence: :medium
      }
    end
  end

  defp classify_referer(nil, _ref_map),
    do: %{platform: :direct, medium: :direct, confidence: :low}

  defp classify_referer("", _ref_map),
    do: %{platform: :direct, medium: :direct, confidence: :low}

  defp classify_referer(referer, ref_map) do
    domain =
      URI.parse(referer).host
      |> to_string()
      |> String.replace_prefix("www.", "")

    case Map.get(ref_map, domain) do
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
