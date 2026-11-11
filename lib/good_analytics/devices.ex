defmodule GoodAnalytics.Devices do
  @moduledoc """
  User-agent intelligence for GoodAnalytics, wrapping `:ua_inspector`.

  The single owner of UAInspector access in the library. Pure functions — no
  Ecto, no side effects:

    * `parse/1`         — normalize a user agent into a storable device map
    * `label/1`         — humanize a UA string or a stored device map
    * `humanize_type/1` — collapse a raw device type into a coarse bucket
    * `bot?/1`          — crawler predicate

  `parse/1` stores raw `:ua_inspector` field values (names + versions); consumers
  group/humanize via `label/1` and `humanize_type/1`.
  """

  alias UAInspector.Result

  @type device_map :: %{optional(String.t()) => String.t()}
  @type bot_kind ::
          :ai_crawler
          | :ai_assistant
          | :search_crawler
          | :crawler
          | :social_preview
          | :seo_tool
          | :monitoring
          | :other

  @automation_category "Automation"

  # Generic HTTP clients and headless browsers that ua_inspector does not flag.
  # Each entry is {label, pattern}; the label names the matched tool.
  @automation_patterns [
    {"curl", ~r/\bcurl(?![a-z])/i},
    {"wget", ~r/\bwget(?![a-z])/i},
    {"python-requests", ~r/\bpython-requests(?![a-z])/i},
    {"python-urllib", ~r/\bpython-urllib(?![a-z])/i},
    {"httpx", ~r/\bhttpx(?![a-z])/i},
    {"aiohttp", ~r/\baiohttp(?![a-z])/i},
    {"okhttp", ~r/\bokhttp(?![a-z])/i},
    {"go-http-client", ~r/\bgo-http-client(?![a-z])/i},
    {"java", ~r/\bjava(?![a-z])(?!;\s*U;)/i},
    {"libwww-perl", ~r/\blibwww-perl(?![a-z])/i},
    {"node-fetch", ~r/\bnode-fetch(?![a-z])/i},
    {"undici", ~r/\bundici(?![a-z])/i},
    {"axios", ~r/\baxios(?![a-z])/i},
    {"HeadlessChrome", ~r/\bHeadlessChrome(?![a-z])/i},
    {"PhantomJS", ~r/\bPhantomJS(?![a-z])/i},
    {"Playwright", ~r/\bPlaywright\b/i},
    {"Puppeteer", ~r/\bPuppeteer\b/i},
    {"Selenium", ~r/\bSelenium\b/i},
    {"Scrapy", ~r/\bScrapy\b/i}
  ]

  # SEO tooling is identified by name: ua_inspector files these under generic
  # categories such as "Crawler" or "Site Monitor".
  @seo_tool_pattern ~r/ahrefs|semrush|mj12|majestic|dotbot|rogerbot|serpstat|screaming frog|seokicks|blexbot/i

  @doc """
  Normalize a user agent into a device map. Empty map when blank/unknown.

  Bots carry `"type" => "bot"`, the bot `"name"` and the raw ua_inspector
  `"bot_category"`. Generic automation (curl, HeadlessChrome, ...) that
  ua_inspector misses is named by the matched tool with category `"Automation"`.
  """
  @spec parse(String.t() | nil) :: device_map()
  def parse(ua) when is_binary(ua) and ua != "" do
    case UAInspector.parse(ua) do
      %Result.Bot{name: name, category: category} ->
        drop_blanks(%{
          "type" => "bot",
          "name" => name,
          "bot_category" => known_string(category)
        })

      %Result{} = result ->
        parse_client(ua, result)

      _other ->
        %{}
    end
  end

  def parse(_ua), do: %{}

  defp parse_client(ua, result) do
    case automation_match(ua) do
      nil -> parse_result(result)
      label -> %{"type" => "bot", "name" => label, "bot_category" => @automation_category}
    end
  end

  defp parse_result(result) do
    drop_blanks(%{
      "type" => field(result.device, :type),
      "brand" => field(result.device, :brand),
      "model" => field(result.device, :model),
      "os" => field(result.os, :name),
      "os_version" => field(result.os, :version),
      "browser" => field(result.client, :name),
      "browser_version" => field(result.client, :version)
    })
  end

  @doc "True when the user agent matches the generic automation denylist (HTTP clients, headless browsers)."
  @spec automation_ua?(String.t() | nil) :: boolean()
  def automation_ua?(ua) when is_binary(ua) and ua != "", do: automation_match(ua) != nil
  def automation_ua?(_ua), do: false

  @doc """
  Classifies a `parse/1` device map's bot into a coarse kind, or `nil` when the
  map is not a bot. `:search_crawler` is ua_inspector's "Search bot" category;
  `:crawler` is its generic "Crawler" catch-all; SEO tools are matched by name first.
  """
  @spec bot_kind(device_map() | nil) :: bot_kind() | nil
  def bot_kind(%{"type" => "bot"} = device) do
    if seo_tool?(Map.get(device, "name")) do
      :seo_tool
    else
      category_kind(Map.get(device, "bot_category"))
    end
  end

  def bot_kind(_device), do: nil

  defp seo_tool?(name) when is_binary(name), do: Regex.match?(@seo_tool_pattern, name)
  defp seo_tool?(_name), do: false

  defp category_kind(category) when category in ["AI Search Crawler", "AI Data Scraper"],
    do: :ai_crawler

  defp category_kind(category) when category in ["AI Assistant", "AI Agent"], do: :ai_assistant
  defp category_kind("Search bot"), do: :search_crawler
  defp category_kind("Crawler"), do: :crawler
  defp category_kind("Social Media Agent"), do: :social_preview

  defp category_kind(category) when category in ["Site Monitor", "Network Monitor", "Automation"],
    do: :monitoring

  defp category_kind(_category), do: :other

  defp automation_match(ua) do
    Enum.find_value(@automation_patterns, fn {label, pattern} ->
      if Regex.match?(pattern, ua), do: label
    end)
  end

  defp known_string(value) when is_binary(value), do: value
  defp known_string(_unknown), do: nil

  @doc """
  Maps a `parse/1` device map onto event-grain column attrs.

  Keys absent from the device map are omitted so the `Event` changeset leaves
  the corresponding column NULL. The raw `:ua_inspector` device type is stored
  verbatim (`humanize_type/1` is applied at read time, not here). For bots,
  `device_type` is `"bot"` and `bot_name` carries the crawler name.
  """
  @spec to_event_attrs(device_map() | nil) :: %{optional(atom()) => String.t()}
  def to_event_attrs(device) when is_map(device) do
    %{
      device_type: Map.get(device, "type"),
      browser: Map.get(device, "browser"),
      os: Map.get(device, "os"),
      browser_version: Map.get(device, "browser_version"),
      os_version: Map.get(device, "os_version"),
      device_brand: Map.get(device, "brand"),
      device_model: Map.get(device, "model"),
      bot_name: Map.get(device, "name")
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  def to_event_attrs(_device), do: %{}

  @doc "Humanize a UA string or a stored device map into a short label."
  @spec label(String.t() | map() | nil) :: String.t()
  def label(nil), do: "Unknown"
  def label(ua) when is_binary(ua), do: ua |> parse() |> label()
  def label(%{"type" => "bot", "name" => name}) when is_binary(name), do: "Bot · #{name}"
  def label(%{"type" => "bot"}), do: "Bot"

  def label(%{} = map) do
    label =
      [
        map |> Map.get("type") |> humanize_type_or_nil(),
        version_part(Map.get(map, "os"), Map.get(map, "os_version")),
        version_part(Map.get(map, "browser"), Map.get(map, "browser_version"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    if label == "", do: "Unknown", else: label
  end

  @doc "Collapse a raw `:ua_inspector` device type into a coarse breakdown bucket."
  @spec humanize_type(String.t() | nil) :: String.t()
  def humanize_type(type) when type in [nil, ""], do: "Unknown"
  def humanize_type("desktop"), do: "Desktop"
  def humanize_type("smartphone"), do: "Mobile"
  def humanize_type("phablet"), do: "Mobile"
  def humanize_type("tablet"), do: "Tablet"
  def humanize_type("tv"), do: "TV"
  def humanize_type("console"), do: "Console"
  def humanize_type("car browser"), do: "Car"
  def humanize_type("portable media player"), do: "Media Player"
  def humanize_type("wearable"), do: "Wearable"
  def humanize_type("bot"), do: "Bot"
  def humanize_type(other) when is_binary(other), do: String.capitalize(other)

  @doc "ua_inspector-detected bot (excludes the automation denylist; see `automation_ua?/1`). Tolerates blanks."
  @spec bot?(String.t() | nil) :: boolean()
  def bot?(ua) when is_binary(ua) and ua != "", do: UAInspector.bot?(ua)
  def bot?(_ua), do: false

  # -- private --

  # `:ua_inspector` reports a missing component as the `:unknown` atom (not a
  # struct) and a missing field within a component as `:unknown` too.
  defp field(component, key) when is_map(component) do
    case Map.get(component, key) do
      value when is_binary(value) -> value
      _unknown -> nil
    end
  end

  defp field(_component, _key), do: nil

  defp drop_blanks(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp humanize_type_or_nil(nil), do: nil
  defp humanize_type_or_nil(""), do: nil
  defp humanize_type_or_nil(type), do: humanize_type(type)

  defp version_part(nil, _version), do: nil
  defp version_part("", _version), do: nil
  defp version_part(name, version) when version in [nil, ""], do: name
  defp version_part(name, version), do: "#{name} #{major_version(version)}"

  defp major_version(version) when is_binary(version) do
    case String.split(version, ".") do
      [major] -> major
      [major, minor | _rest] -> "#{major}.#{minor}"
    end
  end

  defp major_version(version), do: to_string(version)
end
