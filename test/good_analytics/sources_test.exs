defmodule GoodAnalytics.SourcesTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Sources

  describe "label/1" do
    test "names the channel and the platform" do
      for {source, expected} <- [
            {%{platform: :google, medium: :organic}, "Organic Search · Google"},
            {%{platform: :linkedin, medium: :social}, "Organic Social · LinkedIn"},
            {%{platform: :gmail, medium: :email}, "Email · Gmail"},
            {%{platform: "newsletter", medium: "email"}, "Email · Newsletter"},
            {%{platform: :chatgpt, medium: :ai}, "AI Assistant · ChatGPT"},
            {%{"platform" => "linkedin", "medium" => "social"}, "Organic Social · LinkedIn"},
            {%{platform: :meta, medium: :social}, "Organic Social · Facebook"},
            {%{platform: :google, medium: :cpc}, "Paid Search · Google"},
            {%{platform: :facebook, medium: :paid}, "Paid Social · Facebook"}
          ] do
        assert Sources.label(source) == expected
      end
    end

    test "referrals name the domain" do
      assert Sources.label(%{
               platform: :referral,
               medium: :referral,
               referer_domain: "forum.example.org"
             }) ==
               "Referral · forum.example.org"

      assert Sources.label(%{
               source_medium: "referral",
               source_platform: "referral",
               referrer: "https://forum.example.org/t/1"
             }) == "Referral · forum.example.org"

      assert Sources.label(%{platform: "somepartner", medium: "referral"}) ==
               "Referral · somepartner"

      assert Sources.label(%{platform: "referral", medium: "referral"}) == "Referral"
    end

    test "direct, nil and empty are Direct" do
      assert Sources.label(nil) == "Direct"
      assert Sources.label(%{}) == "Direct"
      assert Sources.label(%{platform: :direct, medium: :direct}) == "Direct"
      assert Sources.label(%{"medium" => "(none)"}) == "Direct"
    end

    test "shows just the channel when the platform name repeats it or is missing" do
      assert Sources.label(%{medium: "email"}) == "Email"
      assert Sources.label(%{platform: "email", medium: "email"}) == "Email"
    end

    test "infers the channel from a known platform when the medium is missing" do
      assert Sources.label(%{"platform" => "linkedin"}) == "Organic Social · LinkedIn"
    end

    test "a direct platform without a medium is Direct" do
      assert Sources.label(%{"platform" => "direct"}) == "Direct"
      assert Sources.label(%{platform: :direct}) == "Direct"
    end

    test "referral domains drop www and port" do
      assert Sources.label(%{medium: "referral", referer_domain: "www.Example.com"}) ==
               "Referral · example.com"

      assert Sources.label(%{medium: "referral", referrer: "https://www.example.com:8443/x"}) ==
               "Referral · example.com"
    end

    test "old utm_source shorthands canonicalise" do
      assert Sources.label(%{platform: "fb", medium: "social"}) == "Organic Social · Facebook"
      assert Sources.label(%{platform: "ig", medium: "social"}) == "Organic Social · Instagram"
      assert Sources.label(%{platform: "li", medium: "social"}) == "Organic Social · LinkedIn"
      assert Sources.channel("cpc", "fb") == :paid_social
      assert Sources.label(%{platform: :youtube, medium: :social}) == "Organic Social · YouTube"
    end

    test "accepts event columns" do
      assert Sources.label(%{source_platform: "perplexity_ai", source_medium: "ai"}) ==
               "AI Assistant · Perplexity"
    end
  end

  describe "channel/1 and channel/2" do
    test "covers every medium normalize_medium/1 handles" do
      for {medium, channel} <- [
            {"cpc", :paid_search},
            {"ppc", :paid_search},
            {"paid", :paid_search},
            {"email", :email},
            {"social", :organic_social},
            {"organic", :organic_search},
            {"referral", :referral},
            {"affiliate", :affiliates},
            {"newsletter", :email},
            {"sms", :sms},
            {"messaging", :organic_social},
            {"ai", :ai_assistant},
            {"video", :organic_video},
            {"display", :display},
            {"direct", :direct},
            {"(none)", :direct},
            {"", :direct},
            {nil, :direct},
            {"unknown", :referral},
            {:organic, :organic_search},
            {:paid, :paid_search},
            {:ai, :ai_assistant},
            {"CPC", :paid_search}
          ] do
        assert Sources.channel(medium) == channel, "medium #{inspect(medium)}"
      end
    end

    test "splits paid by platform" do
      assert Sources.channel("paid", "facebook") == :paid_social
      assert Sources.channel("cpc", :linkedin) == :paid_social
      assert Sources.channel("paid", "meta") == :paid_social
      assert Sources.channel("cpc", "google") == :paid_search
      assert Sources.channel("paid", nil) == :paid_search
    end

    test "accepts a source map" do
      assert Sources.channel(%{platform: :facebook, medium: :paid}) == :paid_social
      assert Sources.channel(%{"source_medium" => "organic"}) == :organic_search
      assert Sources.channel(%{}) == :direct
    end
  end

  describe "channel_name/1" do
    test "returns GA4 names" do
      assert Sources.channel_name(:organic_search) == "Organic Search"
      assert Sources.channel_name(:ai_assistant) == "AI Assistant"
      assert Sources.channel_name(:sms) == "SMS"
      assert Sources.channel_name(:affiliates) == "Affiliates"
      assert Sources.channel_name(:other) == "Other"
    end
  end

  describe "mediums/1 and parse_channel/1" do
    test "mediums is the inverse of channel/1" do
      for channel <- Sources.channels(), medium <- Sources.mediums(channel) do
        assert Sources.channel(medium, if(channel == :paid_social, do: "facebook")) == channel,
               "#{medium} -> #{channel}"
      end

      assert Sources.mediums(:paid_search) == ["cpc", "paid", "paid_search", "ppc"]
      assert Sources.mediums(:paid_social) == ["cpc", "paid", "paid_social", "ppc"]
      assert Enum.sort(Sources.mediums(:direct)) == ["", "(none)", "direct", "none"]
      assert "email" in Sources.mediums(:email)
      assert Sources.mediums(:other) == []
    end

    test "parse_channel never crashes on junk" do
      assert Sources.parse_channel("organic_search") == {:ok, :organic_search}
      assert Sources.parse_channel("paid") == :error
      assert Sources.parse_channel(nil) == :error
      assert Sources.parse_channel("zzz") == :error
    end
  end

  describe "platform_name/1" do
    test "uses the vendored names and falls back to capitalize" do
      assert Sources.platform_name("linkedin") == "LinkedIn"
      assert Sources.platform_name(:chatgpt) == "ChatGPT"
      assert Sources.platform_name("duckduckgo") == "DuckDuckGo"
      assert Sources.platform_name("somepartner") == "Somepartner"
    end
  end

  describe "channel_sql/1" do
    test "returns a static CASE over the alias" do
      sql = Sources.channel_sql("e")
      refute sql =~ "?"
      assert sql =~ "btrim(coalesce(e.source_medium"
      assert sql =~ "e.source_platform"
      assert sql =~ "'organic_search'"
      assert sql =~ "'paid_social'"
      assert sql =~ "'ai_assistant'"
      assert String.starts_with?(sql, "CASE")
    end

    test "rejects an unsafe alias" do
      assert_raise ArgumentError, fn -> Sources.channel_sql("e; drop") end
      assert_raise ArgumentError, fn -> Sources.channel_sql("E") end
    end

    test "every channel key in SQL is a channel atom" do
      keys = Regex.scan(~r/THEN '([a-z_]+)'/, Sources.channel_sql("e"), capture: :all_but_first)
      allowed = Enum.map(Sources.channels(), &Atom.to_string/1)
      assert keys != []
      assert Enum.all?(List.flatten(keys), &(&1 in allowed))
    end
  end

  describe "channel/1 agrees with label/1" do
    test "the label starts with the channel name for sources without a medium" do
      for source <- [
            %{source_platform: "google_jobs_apply"},
            %{source_platform: "somepartner"},
            %{source_platform: "linkedin"},
            %{platform: "newsletter"},
            %{platform: "perplexity", medium: "unknown"},
            %{platform: "linkedin", medium: "unknown"},
            %{source_platform: "foo", source_medium: "unknown"},
            %{source_medium: "organic"},
            %{source_platform: "direct"},
            %{source_platform: "referral"},
            %{}
          ] do
        label = Sources.label(source)
        name = source |> Sources.channel() |> Sources.channel_name()

        assert label == name or String.starts_with?(label, name <> " · "),
               "#{inspect(source)}: #{label} vs #{name}"
      end
    end

    test "a missing or unknown medium is inferred from the platform" do
      assert Sources.channel(%{source_platform: "google_jobs_apply"}) == :organic_search
      assert Sources.channel(%{source_platform: "somepartner"}) == :referral
      assert Sources.channel(%{platform: "linkedin", medium: "unknown"}) == :organic_social
      assert Sources.channel(%{platform: "perplexity", medium: "unknown"}) == :ai_assistant
      assert Sources.channel(%{platform: "foo", medium: "unknown"}) == :referral
    end
  end

  describe "label/1 for list-unknown referral entries" do
    test "prefers the referer domain over the platform name" do
      assert Sources.label(%{
               platform: :google,
               medium: :referral,
               referer_domain: "docs.google.com"
             }) ==
               "Referral · docs.google.com"

      assert Sources.label(%{
               source_platform: "google",
               source_medium: "referral",
               referrer: "https://docs.google.com/x"
             }) == "Referral · docs.google.com"
    end

    test "a raw utm platform keeps its own name" do
      assert Sources.label(%{
               platform: "somepartner",
               medium: :referral,
               referer_domain: "x.test"
             }) ==
               "Referral · somepartner"
    end
  end
end
