defmodule GoodAnalytics.DevicesTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Devices

  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
             "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " <>
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  @googlebot "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"

  describe "parse/1" do
    test "parses a desktop browser into a normalized map" do
      map = Devices.parse(@desktop)
      assert map["type"] == "desktop"
      assert map["os"] == "Mac"
      assert map["browser"] == "Chrome"
      assert is_binary(map["browser_version"])
    end

    test "parses a phone as a smartphone" do
      assert Devices.parse(@iphone)["type"] == "smartphone"
    end

    test "tags a known crawler as a bot" do
      map = Devices.parse(@googlebot)
      assert map["type"] == "bot"
      assert map["name"] =~ "Googlebot"
    end

    test "returns an empty map for blank agents" do
      assert Devices.parse(nil) == %{}
      assert Devices.parse("") == %{}
    end

    test "tolerates user agents whose components UAInspector reports as :unknown" do
      # UAInspector returns the `:unknown` atom (not a struct) for unrecognized
      # device/os/client components — parse/1 must not crash on those.
      assert is_map(Devices.parse("Mozilla/5.0"))
      assert is_map(Devices.parse("SomeApp/1.0 (custom client)"))
    end

    test "treats unparseable junk as a generic bot (UAInspector behavior)" do
      # UAInspector classifies non-browser text as a generic bot; faithful to how
      # pro already formatted bot results. `bot?/1` remains the dedicated bot gate.
      assert Devices.parse("not a real user agent")["type"] == "bot"
    end
  end

  describe "label/1" do
    test "humanizes a user-agent string" do
      assert Devices.label(@desktop) =~ "Desktop"
      assert Devices.label(@desktop) =~ "Chrome"
    end

    test "humanizes a stored device map" do
      map = %{"type" => "smartphone", "os" => "iOS", "browser" => "Safari"}
      assert Devices.label(map) == "Mobile · iOS · Safari"
    end

    test "labels a bot map" do
      assert Devices.label(%{"type" => "bot", "name" => "Googlebot"}) == "Bot · Googlebot"
    end

    test "labels a bot with no usable name as just Bot" do
      assert Devices.label(%{"type" => "bot"}) == "Bot"
      assert Devices.label(%{"type" => "bot", "name" => :unknown}) == "Bot"
    end

    test "falls back to Unknown for empty input" do
      assert Devices.label(%{}) == "Unknown"
      assert Devices.label(nil) == "Unknown"
    end
  end

  describe "humanize_type/1" do
    test "collapses raw device types into coarse buckets" do
      assert Devices.humanize_type("desktop") == "Desktop"
      assert Devices.humanize_type("smartphone") == "Mobile"
      assert Devices.humanize_type("phablet") == "Mobile"
      assert Devices.humanize_type("tablet") == "Tablet"
      assert Devices.humanize_type("bot") == "Bot"
      assert Devices.humanize_type(nil) == "Unknown"
      assert Devices.humanize_type("") == "Unknown"
    end
  end

  describe "bot?/1" do
    test "detects crawlers and tolerates blanks" do
      assert Devices.bot?(@googlebot)
      refute Devices.bot?(@desktop)
      refute Devices.bot?(nil)
      refute Devices.bot?("")
    end
  end

  describe "to_event_attrs/1" do
    test "maps a parsed desktop device map to event columns" do
      attrs = @desktop |> Devices.parse() |> Devices.to_event_attrs()

      assert attrs.device_type == "desktop"
      assert attrs.browser == "Chrome"
      assert attrs.os == "Mac"
      assert is_binary(attrs.browser_version)
      assert Map.has_key?(attrs, :os_version)
    end

    test "maps device brand and model when present" do
      attrs = @iphone |> Devices.parse() |> Devices.to_event_attrs()

      assert attrs.device_type == "smartphone"
      # iPhone reports brand Apple via UAInspector
      assert attrs.device_brand == "Apple"
      assert attrs.device_model == "iPhone"
    end

    test "maps a bot map to device_type bot with bot_name" do
      attrs = @googlebot |> Devices.parse() |> Devices.to_event_attrs()

      assert attrs.device_type == "bot"
      assert attrs.bot_name =~ "Googlebot"
    end

    test "returns an empty map for a blank/empty device map" do
      assert Devices.to_event_attrs(%{}) == %{}
      assert Devices.to_event_attrs(nil) == %{}
    end

    test "omits columns whose source key is absent (leaves them NULL)" do
      attrs = Devices.to_event_attrs(%{"type" => "desktop", "browser" => "Firefox"})

      assert attrs == %{device_type: "desktop", browser: "Firefox"}
      refute Map.has_key?(attrs, :os)
      refute Map.has_key?(attrs, :bot_name)
    end
  end

  describe "bot classification" do
    @headless "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/124.0.0.0 Safari/537.36"
    @oai "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; OAI-SearchBot/1.0; +https://openai.com/searchbot"
    @chatgpt_user "Mozilla/5.0 AppleWebKit/537.36 (KHTML, like Gecko); compatible; ChatGPT-User/1.0; +https://openai.com/bot"
    @bing "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
    @meta_indexer "meta-webindexer/1.1 (+https://developers.facebook.com/docs/sharing/webmasters/web-crawlers/)"
    @ahrefs "Mozilla/5.0 (compatible; AhrefsBot/7.0; +http://ahrefs.com/robot/)"

    test "HeadlessChrome is an automation bot named by the matched tool" do
      map = Devices.parse(@headless)
      assert map["type"] == "bot"
      assert map["name"] == "HeadlessChrome"
      assert map["bot_category"] == "Automation"
      assert Devices.bot_kind(map) == :monitoring
    end

    test "curl is named curl" do
      assert %{"type" => "bot", "name" => "curl", "bot_category" => "Automation"} =
               Devices.parse("curl/8.1.2")
    end

    test "automation_ua?/1" do
      assert Devices.automation_ua?(@headless)
      assert Devices.automation_ua?("python-requests/2.31")
      refute Devices.automation_ua?(@desktop)
      refute Devices.automation_ua?(nil)
    end

    test "keeps the ua_inspector category" do
      assert Devices.parse(@oai)["bot_category"] == "AI Search Crawler"
    end

    test "bot_kind/1 maps categories" do
      assert Devices.bot_kind(Devices.parse(@oai)) == :ai_crawler
      assert Devices.bot_kind(Devices.parse("GPTBot/1.1")) == :ai_crawler
      assert Devices.bot_kind(Devices.parse(@chatgpt_user)) == :ai_assistant
      assert Devices.bot_kind(Devices.parse(@bing)) == :search_crawler

      assert Devices.bot_kind(%{"type" => "bot", "bot_category" => "Crawler", "name" => "X"}) ==
               :crawler

      assert Devices.bot_kind(
               Devices.parse(
                 "Mozilla/5.0 (compatible; SemrushBot/7~bl; +http://www.semrush.com/bot.html)"
               )
             ) == :seo_tool

      assert Devices.bot_kind(Devices.parse(@meta_indexer)) == :social_preview
      assert Devices.bot_kind(Devices.parse(@ahrefs)) == :seo_tool
    end

    test "denylist patterns need a trailing boundary" do
      refute Devices.automation_ua?("Chrome/130.0 Safari/537.36 CurlyApp/1.0")
      refute Devices.parse("Mozilla/5.0 CurlyApp/1.0")["type"] == "bot"
      assert Devices.automation_ua?("curl/8.1.2")
      assert Devices.automation_ua?("Mozilla/5.0 HeadlessChrome/124.0")
    end

    test "java matches the runtime but not J2ME feature phones or JavaScript" do
      assert Devices.automation_ua?("Java/11.0.2")
      assert Devices.automation_ua?("Apache-HttpClient/4.5 (Java/11)")

      refute Devices.automation_ua?(
               "UCWEB/2.0 (Java; U; MIDP-2.0; en-US; Nokia6300) U2/1.0.0 UCBrowser/9.4"
             )

      refute Devices.automation_ua?("Mozilla/5.0 JavaScriptCore")
    end

    test "a normal browser is not a bot" do
      map = Devices.parse(@desktop)
      refute map["type"] == "bot"
      assert Devices.bot_kind(map) == nil
      assert Devices.bot_kind(%{}) == nil
      assert Devices.bot_kind(nil) == nil
    end
  end
end
