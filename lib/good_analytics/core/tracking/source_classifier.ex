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

  @base_referer_map %{
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
    # Email (webmail UIs that send a referer on click)
    "mail.google.com" => {:gmail, :email},
    "mail.googleusercontent.com" => {:gmail, :email},
    "outlook.live.com" => {:outlook, :email},
    "outlook.office.com" => {:outlook, :email},
    "outlook.office365.com" => {:outlook, :email},
    "outlook.com" => {:outlook, :email},
    "mail.yahoo.com" => {:yahoo_mail, :email},
    "mail.yahoo.co.jp" => {:yahoo_mail, :email},
    "mail.icloud.com" => {:icloud_mail, :email},
    "mail.aol.com" => {:aol_mail, :email},
    "mail.proton.me" => {:proton_mail, :email},
    "mail.zoho.com" => {:zoho_mail, :email},
    "mail.gmx.com" => {:gmx, :email},
    "mail.gmx.net" => {:gmx, :email},
    "mail.gmx.de" => {:gmx, :email},
    "mail.web.de" => {:web_de, :email},
    "e.mail.ru" => {:mailru, :email},
    "mail.yandex.ru" => {:yandex_mail, :email},
    "mail.yandex.com" => {:yandex_mail, :email},
    "mail.naver.com" => {:naver_mail, :email},
    "app.fastmail.com" => {:fastmail, :email},
    "mail.tutanota.com" => {:tuta, :email},
    "app.hey.com" => {:hey, :email},
    # Messaging
    "web.whatsapp.com" => {:whatsapp, :messaging},
    "web.telegram.org" => {:telegram, :messaging},
    "slack.com" => {:slack, :messaging},
    "app.slack.com" => {:slack, :messaging},
    "discord.com" => {:discord, :messaging}
  }

  # AI assistant referrers (research-documented; medium :ai). Each host maps to a
  # canonical vendor so the referer and utm_source paths agree. Extensible at
  # runtime via the `:overrides` option.
  @ai_referer_map %{
    "chatgpt.com" => {:chatgpt, :ai},
    "chat.openai.com" => {:chatgpt, :ai},
    "chat-gpt.org" => {:chatgpt, :ai},
    "openai.com" => {:chatgpt, :ai},
    "claude.ai" => {:claude, :ai},
    "anthropic.com" => {:claude, :ai},
    "perplexity.ai" => {:perplexity, :ai},
    "copilot.microsoft.com" => {:copilot, :ai},
    "edgeservices.bing.com" => {:copilot, :ai},
    "turing.microsoft.com" => {:copilot, :ai},
    "cosmos.microsoft.com" => {:copilot, :ai},
    "gemini.google.com" => {:gemini, :ai},
    "bard.google.com" => {:gemini, :ai},
    "deepmind.com" => {:gemini, :ai},
    "grok.com" => {:grok, :ai},
    "grok.x.com" => {:grok, :ai},
    "x.ai" => {:grok, :ai},
    "deepseek.com" => {:deepseek, :ai},
    "you.com" => {:you, :ai},
    "meta.ai" => {:meta_ai, :ai},
    "mistral.ai" => {:mistral, :ai},
    "chat.mistral.ai" => {:mistral, :ai},
    "character.ai" => {:character_ai, :ai},
    "huggingface.co" => {:huggingchat, :ai},
    "huggingchat.com" => {:huggingchat, :ai},
    "phind.com" => {:phind, :ai},
    "pi.ai" => {:pi, :ai},
    "zhipu.ai" => {:zhipu, :ai},
    "chatglm.cn" => {:zhipu, :ai},
    "qwenlm.ai" => {:qwen, :ai},
    "chat.qwen.ai" => {:qwen, :ai},
    "felo.ai" => {:felo, :ai},
    "komo.ai" => {:komo, :ai},
    "iask.ai" => {:iask, :ai},
    "sider.ai" => {:sider, :ai},
    "venice.ai" => {:venice, :ai},
    "duck.ai" => {:duckai, :ai},
    "cohere.ai" => {:cohere, :ai},
    "jasper.ai" => {:jasper, :ai},
    "writesonic.com" => {:writesonic, :ai},
    "quillbot.com" => {:quillbot, :ai},
    "wordtune.com" => {:wordtune, :ai},
    "copy.ai" => {:copyai, :ai},
    "blackbox.ai" => {:blackbox, :ai},
    "openchat.so" => {:openchat, :ai},
    "open-assistant.io" => {:open_assistant, :ai},
    "openrouter.ai" => {:openrouter, :ai},
    "lmarena.ai" => {:lmarena, :ai},
    "coze.com" => {:coze, :ai},
    "exa.ai" => {:exa, :ai},
    "forefront.ai" => {:forefront, :ai},
    "reka.ai" => {:reka, :ai},
    "ai21.com" => {:ai21, :ai},
    "deepl.com" => {:deepl, :ai},
    "chat.suno.com" => {:suno, :ai},
    "neeva.com" => {:neeva, :ai},
    "nimble.ai" => {:nimble, :ai},
    "bnngpt.com" => {:bnngpt, :ai},
    "firefly.adobe.com" => {:adobe_firefly, :ai}
  }

  @referer_map Map.merge(@base_referer_map, @ai_referer_map)

  # Canonical platform per AI domain, for matching `utm_source` values that
  # arrive without a referrer (e.g. ?utm_source=chatgpt.com).
  @ai_sources Map.new(@ai_referer_map, fn {host, {platform, _medium}} -> {host, platform} end)

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
      raw_source = Map.get(utms, "utm_source")
      ai_platform = ai_source_platform(raw_source)

      %{
        platform: ai_platform || raw_source,
        medium:
          if(ai_platform,
            do: :ai,
            else: normalize_medium(Map.get(utms, "utm_medium", "unknown"))
          ),
        campaign: Map.get(utms, "utm_campaign"),
        content: Map.get(utms, "utm_content"),
        term: Map.get(utms, "utm_term"),
        confidence: :medium
      }
    end
  end

  # Maps a known AI `utm_source` domain to its canonical platform (`nil` otherwise).
  defp ai_source_platform(nil), do: nil

  defp ai_source_platform(source) when is_binary(source) do
    Map.get(@ai_sources, source |> String.downcase() |> String.replace_prefix("www.", ""))
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
