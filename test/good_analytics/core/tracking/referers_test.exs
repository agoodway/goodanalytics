defmodule GoodAnalytics.Core.Tracking.ReferersTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Tracking.Referers

  describe "lookup/1" do
    test "finds exact hosts" do
      assert %{platform: :brave, medium: :organic} = Referers.lookup("search.brave.com")
      assert %{platform: :gmail, medium: :email} = Referers.lookup("com.google.android.gm")
    end

    test "walks parent domains" do
      assert %{platform: :google, medium: :organic} = Referers.lookup("www.google.com.hk")
      assert %{medium: :email} = Referers.lookup("mail3.spectrum.net")
      assert %{medium: :email} = Referers.lookup("abc123.click.mailersend.net")
    end

    test "resolves TLD wildcards" do
      assert %{platform: :google, medium: :organic} = Referers.lookup("google.co.uk")
      assert %{platform: :google, medium: :organic} = Referers.lookup("google.de")
    end

    test "returns the display name" do
      assert %{name: "Gmail"} = Referers.lookup("com.google.android.gm")
    end

    test "parent walk never matches a TLD or foreign suffix" do
      assert Referers.lookup("brave.com.evil.net") == nil
      assert Referers.lookup("google.evil.net") == nil
      assert Referers.lookup("net") == nil
      assert Referers.lookup("forum.example.org") == nil
    end

    test "candidates stop at two labels and never include a bare TLD" do
      assert Referers.candidates("a.b.c.net") == ["a.b.c.net", "b.c.net", "c.net"]
      assert Referers.candidates("c.net") == ["c.net"]
      assert Referers.candidates("net") == []
      assert Referers.candidates("") == []
    end

    test "Google and Yahoo product and sign-in hosts are not widened into organic search" do
      for host <- ~w(docs.google.com classroom.google.com play.google.com calendar.google.com
                     meet.google.com login.yahoo.com) do
        assert %{medium: :referral} = Referers.lookup(host), "#{host} should be :referral"
      end

      for host <- ~w(accounts.google.com accounts.google.com.hk accounts.google.de) do
        assert %{medium: :ignore} = Referers.lookup(host), "#{host} should be :ignore"
      end

      assert %{platform: :google, medium: :organic} = Referers.lookup("www.google.com")
      assert %{platform: :yahoo, medium: :organic} = Referers.lookup("search.yahoo.com")
    end

    test "list sections map to Decision 4 mediums" do
      assert %{medium: :referral} = Referers.lookup("support.google.com")
      assert %{medium: :ai} = Referers.lookup("chatgpt.com")
      assert %{medium: :organic} = Referers.lookup("search.brave.com")
    end

    test "Teams is social, you.com is an AI assistant, AT&T has a mail and search platform" do
      assert %{platform: :microsoft_teams, medium: :social} =
               Referers.lookup("statics.teams.cdn.office.net")

      assert %{platform: :you, medium: :ai} = Referers.lookup("you.com")
      assert %{platform: :att_mail, medium: :email} = Referers.lookup("webmail.att.net")
      assert %{medium: :organic} = Referers.lookup("start.att.net")
    end

    test "supplement hosts and ignore medium" do
      assert %{medium: :organic} = Referers.lookup("search.nortonsafesearch.com")
      assert %{medium: :ignore} = Referers.lookup("checkout.stripe.com")
    end

    test "is case-insensitive and accepts URLs and android-app schemes" do
      assert %{platform: :brave} = Referers.lookup("SEARCH.Brave.com")
      assert %{platform: :brave} = Referers.lookup("https://search.brave.com/search?q=x")
      assert %{platform: :gmail} = Referers.lookup("android-app://com.google.android.gm")
    end
  end

  describe "host/1" do
    test "extracts hosts from URLs, protocol-relative URLs and packages" do
      assert Referers.host("https://Search.Brave.com/x?q=1") == "search.brave.com"
      assert Referers.host("//example.com/x") == "example.com"
      assert Referers.host("android-app://com.google.android.gm") == "com.google.android.gm"
      assert Referers.host("com.example.app") == "com.example.app"
    end

    test "non-URL junk is not a host" do
      assert Referers.host("garbage") == nil
      assert Referers.host("not a host.com") == nil
      assert Referers.host("") == nil
      assert Referers.lookup("garbage") == nil
    end
  end

  describe "canonical_platform/1" do
    test "applies aliases, ignoring case, www. and punctuation" do
      assert Referers.canonical_platform("meta") == :facebook
      assert Referers.canonical_platform(:meta) == :facebook
      assert Referers.canonical_platform("Facebook") == :facebook
      assert Referers.canonical_platform("x") == :twitter
      assert Referers.canonical_platform("Twitter") == :twitter
      assert Referers.canonical_platform("Duck.ai") == :duck_ai
      assert Referers.canonical_platform("duckai") == :duck_ai
      assert Referers.canonical_platform("Perplexity.ai") == :perplexity
      assert Referers.canonical_platform("perplexity") == :perplexity
      assert Referers.canonical_platform("Claude.ai") == :claude
      assert Referers.canonical_platform("claude") == :claude
      assert Referers.canonical_platform("yahoo_mail") == :yahoo_mail
      assert Referers.canonical_platform("Yahoo! Mail") == :yahoo_mail
      assert Referers.canonical_platform("google_jobs_apply") == :google_jobs
      assert Referers.canonical_platform("www.copilot.com") == :copilot
    end

    test "returns nil for unknown values" do
      assert Referers.canonical_platform("totally-unknown-thing") == nil
      assert Referers.canonical_platform(nil) == nil
    end
  end

  describe "name/1" do
    test "returns display names for canonical platforms" do
      assert Referers.name(:facebook) == "Facebook"
      assert Referers.name(:twitter) == "X (Twitter)"
      assert Referers.name(:google_jobs) == "Google for Jobs"
      assert Referers.name(:gmail) == "Gmail"
    end

    test "a name with a plus sign does not collide with its base name" do
      assert Referers.name(:google) == "Google"
      assert Referers.resolve("google").medium == :organic
    end

    test "resolves aliases and returns nil for unknown platforms" do
      assert Referers.name(:meta) == "Facebook"
      assert Referers.name(:nope_not_a_platform) == nil
    end
  end

  describe "resolve/1" do
    test "matches hosts first, then aliases, with the platform's primary medium" do
      assert %{platform: :copilot, medium: :ai} = Referers.resolve("copilot.com")
      assert %{platform: :perplexity, medium: :ai} = Referers.resolve("perplexity")
      assert %{platform: :linkedin, medium: :social} = Referers.resolve("linkedin")
      assert %{platform: :facebook, medium: :social} = Referers.resolve("meta")
      assert %{platform: :google_jobs, medium: :organic} = Referers.resolve("google_jobs_apply")
    end

    test "returns nil for unknown or ignored sources" do
      assert Referers.resolve("newsletter") == nil
      assert Referers.resolve("checkout.stripe.com") == nil
    end
  end

  describe "coverage" do
    test "every host in the audit list resolves" do
      for host <- ~w(
            com.google.android.gm com.google.android.googlequicksearchbox com.linkedin.android
            startpage.com search.brave.com search.yahoo.com r.search.yahoo.com ecosia.org
            google.com.hk ya.ru duck.ai claude.ai gemini.google.com chatgpt.com perplexity.ai
            com.slack webmail.centurylink.net mail3.spectrum.net webmail1.earthlink.net
            cb.everymail.com webmail.aruba.it ui-deref.de abc123.click.mailersend.net
            statics.teams.cdn.office.net search.nortonsafesearch.com copilot.com
            checkout.stripe.com
          ) do
        assert Referers.lookup(host), "#{host} should resolve"
      end
    end
  end

  describe "bare_host/1" do
    test "lowercases and strips www and port" do
      assert Referers.bare_host("WWW.Example.com") == "example.com"
      assert Referers.bare_host("www.example.com:8080") == "example.com"
      assert Referers.bare_host("https://www.Example.com:8443/a?b=1") == "example.com"
      assert Referers.bare_host("mail.example.com") == "mail.example.com"
    end

    test "returns nil for nil and non-hosts" do
      assert Referers.bare_host(nil) == nil
      assert Referers.bare_host("") == nil
      assert Referers.bare_host("not a host") == nil
    end
  end

  describe "generic aliases" do
    test "generic words do not resolve through the .com strip" do
      for word <- ~w(mail search you pi web app) do
        assert Referers.resolve(word) == nil, word
      end
    end

    test "explicit short aliases still resolve" do
      for {key, platform} <- [
            {"fb", :facebook},
            {"ig", :instagram},
            {"li", :linkedin},
            {"x", :twitter}
          ] do
        assert %{platform: ^platform} = Referers.resolve(key)
      end
    end

    test "the host you.com still resolves" do
      assert %{platform: :you} = Referers.resolve("you.com")
    end
  end

  describe "bare_host/2 allow_single_label" do
    test "accepts a single-label dev host only when asked" do
      assert Referers.bare_host("http://localhost:4000/x") == nil

      assert Referers.bare_host("http://localhost:4000/x", allow_single_label: true) ==
               "localhost"

      assert Referers.bare_host("LocalHost:4000", allow_single_label: true) == "localhost"

      assert Referers.bare_host("https://www.Example.com/x", allow_single_label: true) ==
               "example.com"

      assert Referers.bare_host("not a host", allow_single_label: true) == nil
    end
  end

  describe "Key" do
    alias GoodAnalytics.Core.Tracking.Referers.Key

    test "invalid UTF-8 is nil, not a crash" do
      assert Key.normalize(<<224, 164, 37, 97>>) == nil
      assert Key.slug(<<224, 164, 37, 97>>) == nil
    end
  end
end
