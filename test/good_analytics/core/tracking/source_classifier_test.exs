defmodule GoodAnalytics.Core.Tracking.SourceClassifierTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Tracking.SourceClassifier

  describe "classify/2 with click IDs" do
    test "detects gclid as google_ads paid" do
      result = classify_params(%{"gclid" => "Cj0KCQ..."})
      assert result.platform == :google_ads
      assert result.medium == :paid
      assert result.click_id_type == "gclid"
      assert result.click_id_value == "Cj0KCQ..."
      assert result.confidence == :high
    end

    test "detects fbclid as facebook social" do
      result = classify_params(%{"fbclid" => "IwAR2X..."})
      assert result.platform == :facebook
      assert result.medium == :social
    end

    test "detects msclkid as microsoft_ads paid" do
      result = classify_params(%{"msclkid" => "abc123"})
      assert result.platform == :microsoft_ads
      assert result.medium == :paid
    end

    test "captures all click IDs present" do
      params = %{"gclid" => "g_val", "fbclid" => "fb_val"}
      result = classify_params(params)
      assert result.captured_click_ids == %{"gclid" => "g_val", "fbclid" => "fb_val"}
    end

    test "click ID takes priority over UTM" do
      params = %{
        "gclid" => "g_val",
        "utm_source" => "newsletter",
        "utm_medium" => "email"
      }

      result = classify_params(params)
      # Click ID overrides UTM platform
      assert result.platform == :google_ads
      assert result.confidence == :high
    end
  end

  describe "classify/2 with UTM params" do
    test "parses UTM source and medium" do
      params = %{"utm_source" => "twitter", "utm_medium" => "social", "utm_campaign" => "launch"}
      result = classify_params(params)
      assert result.platform == :twitter
      assert result.medium == :social
      assert result.campaign == "launch"
    end

    test "parses all UTM fields" do
      params = %{
        "utm_source" => "google",
        "utm_medium" => "cpc",
        "utm_campaign" => "winter",
        "utm_content" => "banner",
        "utm_term" => "analytics"
      }

      result = classify_params(params)
      assert result.content == "banner"
      assert result.term == "analytics"
    end
  end

  describe "classify/2 with referer" do
    test "classifies google.com as organic" do
      result = classify_with_referer("https://www.google.com/search?q=test")
      assert result.platform == :google
      assert result.medium == :organic
    end

    test "classifies t.co as twitter social" do
      result = classify_with_referer("https://t.co/abc123")
      assert result.platform == :twitter
      assert result.medium == :social
    end

    test "classifies unknown referer as referral" do
      result = classify_with_referer("https://some-blog.com/post/123")
      assert result.platform == :referral
      assert result.medium == :referral
      assert result.referer_domain == "some-blog.com"
    end

    test "classifies nil referer as direct" do
      result = classify_with_referer(nil)
      assert result.platform == :direct
      assert result.medium == :direct
    end

    test "classifies empty referer as direct" do
      result = classify_with_referer("")
      assert result.platform == :direct
      assert result.medium == :direct
    end

    test "strips www. from referer domain" do
      result = classify_with_referer("https://www.facebook.com/feed")
      assert result.platform == :facebook
      assert result.medium == :social
    end
  end

  describe "classify/2 with GA params" do
    test "detects via= param" do
      result = classify_params(%{"via" => "john"})
      assert result.partner_code == "john"
      assert result.medium == :referral
    end

    test "detects ref= param" do
      result = classify_params(%{"ref" => "partner123"})
      assert result.partner_code == "partner123"
    end

    test "via takes precedence over ref" do
      result = classify_params(%{"via" => "john", "ref" => "other"})
      assert result.partner_code == "john"
    end
  end

  describe "classify/2 priority ordering" do
    test "click ID > GA params > UTM > referer" do
      params = %{
        "gclid" => "g_val",
        "via" => "john",
        "utm_source" => "newsletter"
      }

      result =
        SourceClassifier.classify(%{
          query_params: params,
          referer: "https://facebook.com"
        })

      # Click ID wins for platform
      assert result.platform == :google_ads
      assert result.confidence == :high
      # But GA param info is still merged
      assert result.partner_code == "john"
    end
  end

  describe "normalize_medium/1" do
    test "normalizes cpc to paid" do
      assert SourceClassifier.normalize_medium("cpc") == :paid
    end

    test "normalizes ppc to paid" do
      assert SourceClassifier.normalize_medium("ppc") == :paid
    end

    test "normalizes paid to paid" do
      assert SourceClassifier.normalize_medium("paid") == :paid
    end

    test "normalizes email" do
      assert SourceClassifier.normalize_medium("email") == :email
    end

    test "passes through unknown medium" do
      assert SourceClassifier.normalize_medium("custom") == "custom"
    end
  end

  describe "capture_all_click_ids/2" do
    test "captures multiple click IDs" do
      params = %{"gclid" => "g", "fbclid" => "f", "other" => "ignored"}
      result = SourceClassifier.capture_all_click_ids(params)
      assert result == %{"gclid" => "g", "fbclid" => "f"}
    end

    test "returns empty map when no click IDs present" do
      assert SourceClassifier.capture_all_click_ids(%{}) == %{}
    end
  end

  describe "classify/2 with runtime overrides" do
    test "uses custom click_id_params" do
      custom_params = %{"my_click" => {:my_platform, :paid}}
      params = %{"my_click" => "abc"}

      result =
        SourceClassifier.classify(
          %{query_params: params, referer: nil},
          overrides: %{click_id_params: custom_params}
        )

      assert result.platform == :my_platform
      assert result.click_id_type == "my_click"
    end

    test "uses custom referer_map" do
      custom_map = %{"myblog.com" => {:my_blog, :content}}

      result =
        SourceClassifier.classify(
          %{query_params: %{}, referer: "https://myblog.com/post"},
          overrides: %{referer_map: custom_map}
        )

      assert result.platform == :my_blog
      assert result.medium == :content
    end
  end

  describe "classify/2 AI referrals" do
    test "classifies known AI referrer hosts as :ai with a canonical platform" do
      for {referer, platform} <- [
            {"https://chatgpt.com/", :chatgpt},
            {"https://chat.openai.com/", :chatgpt},
            {"https://www.perplexity.ai/", :perplexity},
            {"https://claude.ai/", :claude},
            {"https://copilot.microsoft.com/", :copilot},
            {"https://gemini.google.com/", :gemini}
          ] do
        result = classify_with_referer(referer)
        assert result.medium == :ai, "#{referer} should be :ai"
        assert result.platform == platform, "#{referer} should be #{platform}"
      end
    end

    test "recognizes an AI utm_source even with no referrer (stripped-referrer case)" do
      result = classify_params(%{"utm_source" => "chatgpt.com"})
      assert result.medium == :ai
      assert result.platform == :chatgpt
    end

    test "recognizes AI utm_source across vendors and normalizes www./case" do
      for {source, platform} <- [
            {"perplexity.ai", :perplexity},
            {"claude.ai", :claude},
            {"www.perplexity.ai", :perplexity},
            {"ChatGPT.com", :chatgpt}
          ] do
        result = classify_params(%{"utm_source" => source})
        assert result.medium == :ai, "utm_source=#{source} should be :ai"
        assert result.platform == platform, "utm_source=#{source} should be #{platform}"
      end
    end

    test "an AI utm_source outranks a non-AI referer (UTM > referer)" do
      result =
        SourceClassifier.classify(%{
          query_params: %{"utm_source" => "perplexity.ai"},
          referer: "https://facebook.com/"
        })

      assert result.medium == :ai
      assert result.platform == :perplexity
    end

    test "a paid click ID outranks an AI referer (click ID > referer)" do
      result =
        SourceClassifier.classify(%{
          query_params: %{"gclid" => "g_val"},
          referer: "https://chatgpt.com/"
        })

      # The paid click wins platform + confidence; the AI referer must not
      # downgrade an attributable paid visit to :ai.
      assert result.platform == :google_ads
      assert result.medium == :paid
      assert result.confidence == :high
    end

    test "canonicalizes openai and chatgpt.com to the same platform" do
      a = classify_with_referer("https://chat.openai.com/x")
      b = classify_with_referer("https://chatgpt.com/y")
      assert a.platform == b.platform
    end

    test "a non-AI referrer is unaffected" do
      result = classify_with_referer("https://example.com/")
      assert result.medium == :referral
    end
  end

  describe "classify/2 webmail referrals" do
    test "classifies known webmail hosts as :email with a canonical platform" do
      for {referer, platform} <- [
            {"https://mail.google.com/", :gmail},
            {"https://outlook.live.com/", :outlook},
            {"https://outlook.office365.com/", :outlook},
            {"https://mail.yahoo.com/", :yahoo_mail},
            {"https://mail.proton.me/", :proton_mail},
            {"https://app.fastmail.com/", :fastmail}
          ] do
        result = classify_with_referer(referer)
        assert result.medium == :email, "#{referer} should be :email"
        assert result.platform == platform, "#{referer} should be #{platform}"
      end
    end

    test "a webmail host is distinguished from the same provider's search host" do
      # yahoo.com is organic search; mail.yahoo.com is an email client.
      assert classify_with_referer("https://yahoo.com/").medium == :organic
      assert classify_with_referer("https://mail.yahoo.com/").medium == :email
    end
  end

  describe "classify/2 vendored referrer data" do
    test "search engines resolve through the vendored lists" do
      for {referer, platform} <- [
            {"https://search.brave.com/search?q=x", :brave},
            {"https://startpage.com/do/search", :startpage},
            {"https://ecosia.org/search", :ecosia},
            {"https://search.yahoo.com/search", :yahoo},
            {"https://www.google.com.hk/", :google},
            {"https://google.de/", :google},
            {"https://google.co.uk/", :google}
          ] do
        result = classify_with_referer(referer)
        assert result.medium == :organic, "#{referer} should be :organic"
        assert result.platform == platform, "#{referer} should be #{platform}"
      end
    end

    test "ISP webmail and email click trackers are email" do
      for referer <- [
            "https://webmail.centurylink.net/",
            "https://mail3.spectrum.net/",
            "https://zr6ke4n3e8ylon12.click.mailersend.net/x"
          ] do
        assert classify_with_referer(referer).medium == :email, "#{referer} should be :email"
      end
    end

    test "android-app referrers use the package as the host" do
      for {referer, platform, medium} <- [
            {"android-app://com.google.android.gm", :gmail, :email},
            {"com.google.android.gm", :gmail, :email},
            {"android-app://com.linkedin.android", :linkedin, :social},
            {"android-app://com.google.android.googlequicksearchbox", :google, :organic}
          ] do
        result = classify_with_referer(referer)
        assert {result.platform, result.medium} == {platform, medium}, referer
      end
    end

    test "supplement search host" do
      assert classify_with_referer("https://search.nortonsafesearch.com/").medium == :organic
    end

    test "ignore-medium hosts classify to no source" do
      assert classify_with_referer("https://checkout.stripe.com/pay") == nil
    end

    test "unlisted hosts and unknown packages are referral with the domain kept" do
      for domain <- ["forum.example.org", "com.example.app"] do
        result = classify_with_referer("https://" <> domain <> "/x")
        assert result.platform == :referral
        assert result.medium == :referral
        assert result.referer_domain == domain
      end
    end

    test "parent walk never matches a TLD or foreign suffix" do
      result = classify_with_referer("https://brave.com.evil.net/")
      assert result.platform == :referral
      assert result.referer_domain == "brave.com.evil.net"
    end

    test "utm_source=copilot.com without a medium is ai copilot" do
      result = classify_params(%{"utm_source" => "copilot.com"})
      assert result.platform == :copilot
      assert result.medium == :ai
    end

    test "utm_source and referer agree on the canonical platform" do
      perplexity_utm = classify_params(%{"utm_source" => "perplexity"})
      perplexity_ref = classify_with_referer("https://perplexity.ai/")

      assert perplexity_utm.platform == :perplexity
      assert perplexity_ref.platform == :perplexity

      meta_utm = classify_params(%{"utm_source" => "meta"})
      fbclid = classify_params(%{"fbclid" => "IwAR"})
      facebook_ref = classify_with_referer("https://l.facebook.com/l.php")

      assert meta_utm.platform == :facebook
      assert fbclid.platform == :facebook
      assert facebook_ref.platform == :facebook
    end

    test "referer_map overrides extend the vendored data" do
      overrides = %{referer_map: %{"myblog.com" => {:my_blog, :content}}}

      custom =
        SourceClassifier.classify(
          %{query_params: %{}, referer: "https://myblog.com/post"},
          overrides: overrides
        )

      vendored =
        SourceClassifier.classify(
          %{query_params: %{}, referer: "https://search.brave.com/"},
          overrides: overrides
        )

      assert {custom.platform, custom.medium} == {:my_blog, :content}
      assert vendored.platform == :brave
    end

    test "an override beats the vendored data for the same host" do
      result =
        SourceClassifier.classify(
          %{query_params: %{}, referer: "https://search.brave.com/"},
          overrides: %{referer_map: %{"search.brave.com" => {:custom, :content}}}
        )

      assert {result.platform, result.medium} == {:custom, :content}
    end

    test "Google product pages are referral, not organic search" do
      result = classify_with_referer("https://docs.google.com/document/d/1")
      assert result.medium == :referral
      assert result.referer_domain == "docs.google.com"

      assert classify_with_referer("https://accounts.google.com.hk/signin") == nil
    end

    test "a referer that is not a URL or host is direct" do
      result = classify_with_referer("garbage")
      assert result.platform == :direct
      refute Map.has_key?(result, :referer_domain)
    end

    test "a protocol-relative referer yields its host" do
      assert classify_with_referer("//search.brave.com/x").platform == :brave
    end
  end

  describe "internal navigation" do
    test "same-host referer is internal" do
      assert SourceClassifier.classify(
               %{query_params: %{}, referer: "https://www.site.test/a"},
               page_host: "www.site.test"
             ) == nil
    end

    test "apex and www are the same host" do
      assert SourceClassifier.classify(
               %{query_params: %{}, referer: "site.test"},
               page_host: "www.site.test"
             ) == nil

      assert SourceClassifier.classify(
               %{query_params: %{}, referer: "https://www.site.test/"},
               page_host: "site.test"
             ) == nil
    end

    test "configured internal host" do
      assert SourceClassifier.classify(
               %{query_params: %{}, referer: "https://go.site.test/abc"},
               page_host: "site.test",
               internal_hosts: ["go.site.test"]
             ) == nil
    end

    test "internal_hosts defaults to application config, read at call time" do
      Application.put_env(:good_analytics, :internal_hosts, ["go.site.test"])
      on_exit(fn -> Application.delete_env(:good_analytics, :internal_hosts) end)

      assert SourceClassifier.classify(%{
               query_params: %{},
               referer: "https://go.site.test/abc"
             }) == nil
    end

    test "UTMs on an internal navigation still count" do
      result =
        SourceClassifier.classify(
          %{
            query_params: %{"utm_source" => "newsletter"},
            referer: "https://www.site.test/a"
          },
          page_host: "site.test"
        )

      assert result.platform == "newsletter"
    end

    test "a click id or via param on an internal navigation still counts" do
      assert %{platform: :google_ads} =
               SourceClassifier.classify(
                 %{query_params: %{"gclid" => "g"}, referer: "https://site.test/a"},
                 page_host: "site.test"
               )

      assert %{partner_code: "p"} =
               SourceClassifier.classify(
                 %{query_params: %{"via" => "p"}, referer: "https://site.test/a"},
                 page_host: "site.test"
               )
    end

    test "external referer unaffected" do
      assert %{platform: :google} =
               SourceClassifier.classify(
                 %{query_params: %{}, referer: "https://www.google.com/"},
                 page_host: "site.test"
               )
    end

    test "a lookalike host is not internal" do
      assert %{platform: :referral} =
               SourceClassifier.classify(
                 %{query_params: %{}, referer: "https://site.test.evil.net/"},
                 page_host: "site.test"
               )
    end

    test "a string internal_hosts config is accepted" do
      assert SourceClassifier.classify(
               %{query_params: %{}, referer: "https://go.site.test/a"},
               internal_hosts: "go.site.test"
             ) == nil
    end

    test "single-label hosts such as localhost are internal, with or without a port" do
      assert SourceClassifier.classify(
               %{query_params: %{}, referer: "http://localhost:4000/a"},
               page_host: "localhost:4000"
             ) == nil

      assert SourceClassifier.internal_referer?("http://localhost:4000/a", ["localhost"])
    end

    test "a port-like query string does not affect the host comparison" do
      refute SourceClassifier.internal_referer?("https://other.test/?next=site.test:80/x", [
               "site.test"
             ])
    end

    test "classify_beacon/2 reads url query and referrer, with page_host from the url" do
      assert SourceClassifier.classify_beacon(%{
               "url" => "https://www.site.test/jobs/1",
               "referrer" => "https://site.test/"
             }) == nil

      assert %{platform: "newsletter", medium: :email} =
               SourceClassifier.classify_beacon(%{
                 "url" => "https://site.test/a?utm_source=newsletter&utm_medium=email",
                 "referrer" => ""
               })

      assert %{platform: :direct} = SourceClassifier.classify_beacon(%{})

      assert %{platform: :google} =
               SourceClassifier.classify_beacon(%{
                 "url" => "https://site.test/a",
                 "referrer" => "https://www.google.com/"
               })
    end

    test "internal_referer?/2" do
      assert SourceClassifier.internal_referer?("https://WWW.Site.test:8080/a", ["site.test"])
      refute SourceClassifier.internal_referer?("https://other.test/", ["site.test"])
      assert SourceClassifier.internal_referer?("site.test:4000/x", ["site.test:4000"])
      refute SourceClassifier.internal_referer?(nil, ["site.test"])
      refute SourceClassifier.internal_referer?("", ["site.test"])
      refute SourceClassifier.internal_referer?("garbage", ["site.test"])
      refute SourceClassifier.internal_referer?("https://site.test/", [nil])
    end
  end

  describe "classify/2 utm_source without utm_medium" do
    test "a known source infers its medium" do
      for {source, platform, medium} <- [
            {"linkedin", :linkedin, :social},
            {"perplexity", :perplexity, :ai},
            {"copilot.com", :copilot, :ai},
            {"fb", :facebook, :social}
          ] do
        result = classify_params(%{"utm_source" => source})
        assert {result.platform, result.medium} == {platform, medium}, source
      end
    end

    test "newsletter and email sources are email and keep their name" do
      for source <- ["newsletter", "email"] do
        result = classify_params(%{"utm_source" => source})
        assert result.medium == :email, source
        assert result.platform == source
      end
    end

    test "an unknown source is referral and keeps its platform string" do
      result = classify_params(%{"utm_source" => "examplepartner"})
      assert result.medium == :referral
      assert result.platform == "examplepartner"
    end

    test "a blank utm_medium is treated as missing" do
      assert classify_params(%{"utm_source" => "linkedin", "utm_medium" => ""}).medium == :social
    end

    test "the medium is never \"unknown\"" do
      for params <- [
            %{"utm_source" => "linkedin"},
            %{"utm_source" => "somepartner"},
            %{"utm_source" => "newsletter"},
            %{"utm_campaign" => "spring"}
          ] do
        refute classify_params(params).medium == "unknown"
      end
    end

    test "source names match case-insensitively" do
      assert %{platform: "Email", medium: :email} = classify_params(%{"utm_source" => "Email"})

      assert %{platform: :linkedin, medium: :social} =
               classify_params(%{"utm_source" => "LinkedIn"})
    end

    test "a campaign alone is direct and keeps the campaign" do
      result = classify_params(%{"utm_campaign" => "spring"})
      assert result.platform == :direct
      assert result.medium == :direct
      assert result.campaign == "spring"
    end

    test "a campaign alone defers to the referer and keeps the campaign" do
      hn =
        SourceClassifier.classify(%{
          query_params: %{"utm_campaign" => "spring"},
          referer: "https://forum.example.org/t/1"
        })

      assert {hn.platform, hn.medium} == {:referral, :referral}
      assert hn.referer_domain == "forum.example.org"
      assert hn.campaign == "spring"

      google =
        SourceClassifier.classify(%{
          query_params: %{"utm_campaign" => "spring", "utm_source" => " ", "utm_medium" => ""},
          referer: "https://www.google.com/"
        })

      assert {google.platform, google.medium} == {:google, :organic}
      assert google.campaign == "spring"
    end

    test "a campaign alone does not turn internal navigation into a source" do
      assert SourceClassifier.classify(
               %{query_params: %{"utm_campaign" => "spring"}, referer: "https://site.test/a"},
               page_host: "site.test"
             ) == nil
    end

    test "an explicit utm_medium still wins for non-AI sources" do
      assert classify_params(%{"utm_source" => "linkedin", "utm_medium" => "cpc"}).medium ==
               :paid
    end
  end

  describe "classify_beacon/2 robustness" do
    test "a malformed percent-encoded url query does not raise" do
      result =
        SourceClassifier.classify_beacon(%{"url" => "https://x.test/?a=%zz", "referrer" => nil})

      assert is_nil(result) or is_map(result)
    end

    test "a non-UTF-8 utm_source does not raise" do
      for url <- [
            "https://site.test/?utm_source=%E0%A4%A",
            "https://site.test/?utm_source=caf%E9&utm_medium=email"
          ] do
        result = SourceClassifier.classify_beacon(%{"url" => url, "referrer" => ""})
        assert is_nil(result) or is_map(result)
      end
    end

    test "valid pairs survive next to an invalid one" do
      url = "https://site.test/?utm_source=caf%E9&utm_campaign=spring"
      result = SourceClassifier.classify_beacon(%{"url" => url, "referrer" => ""})

      assert result.campaign == "spring"
    end
  end

  describe "generic words as utm_source" do
    test "mail, search, you and pi stay referral with their raw platform string" do
      for word <- ~w(mail search you pi) do
        assert %{platform: ^word, medium: :referral} = classify_params(%{"utm_source" => word})
      end
    end

    test "you.com as a host still resolves" do
      assert %{platform: :you, medium: :ai} = classify_with_referer("https://you.com/search")
    end
  end

  describe "utm_medium casing" do
    test "Email resolves to :email" do
      assert classify_params(%{"utm_source" => "somepartner", "utm_medium" => " Email "}).medium ==
               :email
    end
  end

  describe "internal_hosts/0 and same_site?/2" do
    test "same_site? compares a destination url to hosts" do
      assert SourceClassifier.same_site?("https://www.site.test/jobs", ["site.test"])
      refute SourceClassifier.same_site?("https://other.test/jobs", ["site.test"])
    end

    test "internal_hosts reads the config" do
      previous = Application.get_env(:good_analytics, :internal_hosts)
      Application.put_env(:good_analytics, :internal_hosts, ["a.test"])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:good_analytics, :internal_hosts, previous),
          else: Application.delete_env(:good_analytics, :internal_hosts)
      end)

      assert SourceClassifier.internal_hosts() == ["a.test"]
    end
  end

  # Helpers

  defp classify_params(params) do
    SourceClassifier.classify(%{query_params: params, referer: nil})
  end

  defp classify_with_referer(referer) do
    SourceClassifier.classify(%{query_params: %{}, referer: referer})
  end
end
