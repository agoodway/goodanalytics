defmodule GoodAnalytics.DevicesTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Devices

  @desktop "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
             "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
  @iphone "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " <>
            "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
  @ipad "Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " <>
          "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
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
end
