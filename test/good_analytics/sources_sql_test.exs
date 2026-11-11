defmodule GoodAnalytics.SourcesSQLTest do
  use GoodAnalytics.DataCase, async: true

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Tracking.Referers
  alias GoodAnalytics.Sources
  require GoodAnalytics.Sources

  @cases [
    {"organic", nil},
    {"social", "linkedin"},
    {"paid", "facebook"},
    {"cpc", "meta"},
    {"cpc", "google"},
    {"paid", nil},
    {"email", "gmail"},
    {"ai", "chatgpt"},
    {"affiliate", nil},
    {"sms", nil},
    {"messaging", nil},
    {"referral", "referral"},
    {"direct", "direct"},
    {nil, nil},
    {"(none)", nil},
    {"unknown", nil},
    {"unknown", "linkedin"},
    {"unknown", "perplexity"},
    {"unknown", "foo"},
    {"unknown", "google"},
    {"unknown", "gmail"},
    {"unknown", "acuity_ads"},
    {"Unknown", "Google"},
    {"unknown", "fb"},
    {" Unknown ", "ChatGPT"},
    {"CPC", "Facebook"},
    {" paid ", "fb"},
    {"newsletter", nil},
    {"video", nil}
  ]

  test "the SQL CASE agrees with channel/2 for every case" do
    rows = for {medium, platform} <- @cases, do: [medium, platform]

    %{rows: result} =
      TestRepo.query!(
        "SELECT e.source_medium, e.source_platform, #{Sources.channel_sql("e")} " <>
          "FROM (SELECT * FROM unnest($1::text[], $2::text[]) AS t(source_medium, source_platform)) e",
        [Enum.map(rows, &Enum.at(&1, 0)), Enum.map(rows, &Enum.at(&1, 1))]
      )

    assert length(result) == length(@cases)

    for [medium, platform, key] <- result do
      assert key == Atom.to_string(Sources.channel(medium, platform)),
             "#{inspect({medium, platform})} -> #{key}"
    end
  end

  test "the Ecto fragment agrees with channel/2 for every case" do
    mediums = Enum.map(@cases, &elem(&1, 0))
    platforms = Enum.map(@cases, &elem(&1, 1))

    query =
      from(
        t in fragment(
          "SELECT * FROM unnest(?::text[], ?::text[]) AS t(m, p)",
          ^mediums,
          ^platforms
        ),
        select: %{
          medium: fragment("?", t.m),
          platform: fragment("?", t.p),
          key: Sources.channel_fragment(t.m, t.p)
        }
      )

    rows = TestRepo.all(query)
    assert length(rows) == length(@cases)

    for %{medium: medium, platform: platform, key: key} <- rows do
      assert key == Atom.to_string(Sources.channel(medium, platform)),
             "#{inspect({medium, platform})} -> #{key}"
    end
  end

  test "medium_filter/2 treats a missing or blank medium as direct" do
    mediums = ["direct", nil, "  ", "organic", "email"]

    run = fn operator, value ->
      condition = Sources.medium_filter(operator, value)

      from(t in fragment("SELECT * FROM unnest(?::text[]) AS t(source_medium)", ^mediums),
        where: ^condition,
        select: fragment("?", t.source_medium)
      )
      |> TestRepo.all()
      |> Enum.sort()
    end

    assert run.(:eq, "direct") == [nil, "  ", "direct"]
    assert run.(:in, ["direct", "none"]) == [nil, "  ", "direct"]
    assert run.(:not_in, ["direct"]) == ["email", "organic"]
    assert run.(:neq, "organic") |> length() == 4
    assert Sources.medium_filter(:in, []) == nil
    assert Sources.medium_filter(:ilike, "x") == nil
  end

  test "medium_filter/2 drills match mediums case-insensitively and trimmed, like the channel CASE" do
    visitor = create_visitor!()
    record_event!(visitor, "pageview", %{source: %{medium: "Email"}})
    record_event!(visitor, "pageview", %{source: %{medium: " None "}})

    run = fn condition ->
      from(e in Event, where: ^condition, select: e.source_medium)
      |> TestRepo.all(prefix: "good_analytics")
    end

    assert run.(Sources.medium_filter(:eq, "email")) == ["Email"]
    assert run.(Sources.medium_filter(:in, Sources.mediums(:email))) == ["Email"]
    assert run.(Sources.medium_filter(:in, Sources.mediums(:direct))) == [" None "]
    assert Sources.channel("Email") == :email
    assert Sources.channel(" None ") == :direct
  end

  test "medium_filter/2 normalizes filter values the same way as the stored key" do
    visitor = create_visitor!()
    record_event!(visitor, "pageview", %{source: %{medium: "email"}})
    record_event!(visitor, "pageview", %{source: %{medium: "Newsletter"}})

    run = fn condition ->
      from(e in Event, where: ^condition, select: e.source_medium)
      |> TestRepo.all(prefix: "good_analytics")
    end

    assert run.(Sources.medium_filter(:eq, "Email")) == ["email"]
    assert run.(Sources.medium_filter(:eq, " EMAIL ")) == ["email"]
    assert run.(Sources.medium_filter(:in, ["EMAIL"])) == ["email"]
    assert run.(Sources.medium_filter(:in, [:email])) == ["email"]
    assert run.(Sources.medium_filter(:not_in, ["EMAIL"])) == ["Newsletter"]
    assert run.(Sources.medium_filter(:neq, "Email")) == ["Newsletter"]
    assert run.(Sources.medium_filter(:in, [nil])) == []
    assert Sources.medium_filter(:eq, nil) == nil
  end

  test "unknown reads the platform's primary medium in every implementation" do
    assert Sources.channel("unknown", "google") == :organic_search
    assert Sources.channel("unknown", "gmail") == :email
    assert Sources.channel("unknown", "acuity_ads") == :paid_search
    assert Sources.channel("unknown", "linkedin") == :organic_social
    assert Sources.channel("unknown", "perplexity") == :ai_assistant
    assert Sources.channel("unknown", "foo") == :referral

    for platform <- ~w(google gmail acuity_ads linkedin perplexity foo) do
      assert Sources.channel(%{source_platform: platform, source_medium: "unknown"}) ==
               Sources.channel("unknown", platform)
    end
  end

  test "the primary-medium platform key lists are disjoint" do
    keys =
      for medium <- [:ai, :social, :organic, :email, :paid],
          key <- Referers.primary_platform_keys(medium),
          do: key

    assert keys == Enum.uniq(keys)
  end
end
