defmodule Mix.Tasks.GoodAnalytics.Referers.UpdateTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.GoodAnalytics.Referers.Builder
  alias Mix.Tasks.GoodAnalytics.Referers.Update

  @snowplow_sha "snowplowsha111"
  @matomo_sha "matomosha222"

  @snowplow """
  unknown:
    Acme Docs:
      domains:
        - docs.acme.test
  email:
    Gmail:
      domains:
        - mail.google.com
        - com.google.android.gm
  search:
    Google:
      domains:
        - www.google.com
        - www.google.com.hk
    Duck.ai Search:
      domains:
        - overlap.example
  chatbot:
    Perplexity.ai:
      domains:
        - perplexity.ai
      utm_sources:
        - perplexity.ai
  """

  @matomo_search """
  Google:
    - urls:
        - google.{}
        - www.google.{}
        - google.{}/imgres
      params:
        - q
  StartPage:
    - urls:
        - startpage.com
        - "{}.startpage.com"
      params:
        - query
  Overlap Engine:
    - urls:
        - overlap.example
      params:
        - q
  """

  @matomo_socials """
  Mastodon Test:
    - mastodon.example
  """

  @matomo_ai """
  Some Assistant:
    - assistant.example
    - overlap.example
  """

  @supplement """
  aliases:
    meta: facebook
    perplexity_ai: perplexity
  email:
    # ISP webmail
    CenturyLink Mail:
      domains:
        - centurylink.net
  ignore:
    # people returning from paying
    Stripe Checkout:
      domains:
        - checkout.stripe.test
  search:
    # supplement must beat snowplow for this host
    Supplement Engine:
      domains:
        - overlap.example
  """

  @tag :tmp_dir
  test "writes one merged file with the header, precedence and medium sections", ctx do
    {out, supplement} = paths(ctx.tmp_dir)

    capture_io(fn ->
      assert {:ok, _} = Update.update([], opts(out, supplement))
    end)

    contents = File.read!(out)

    assert String.starts_with?(
             contents,
             "# snowplow: #{@snowplow_sha}, matomo: #{@matomo_sha}, generated: 2026-01-02\n"
           )

    doc = Builder.parse!(contents)

    # supplement > snowplow > matomo: overlap.example goes to the supplement entry only
    assert domains(doc, "search", "Supplement Engine") == ["overlap.example"]
    refute domains(doc, "search", "Overlap Engine")
    refute domains(doc, "search", "Duck.ai Search")
    refute domains(doc, "chatbot", "Some Assistant") |> Enum.member?("overlap.example")

    # medium sections: Matomo engines -> search, socials -> social, assistants -> chatbot
    assert "startpage.com" in domains(doc, "search", "StartPage")
    assert domains(doc, "social", "Mastodon Test") == ["mastodon.example"]
    assert "assistant.example" in domains(doc, "chatbot", "Some Assistant")

    # supplement-only mediums survive
    assert domains(doc, "ignore", "Stripe Checkout") == ["checkout.stripe.test"]
    assert domains(doc, "email", "CenturyLink Mail") == ["centurylink.net"]

    # Snowplow www. prefixes are dropped, TLD wildcards kept, path-qualified urls skipped
    assert "google.com.hk" in domains(doc, "search", "Google")
    assert "google.{}" in domains(doc, "search", "Google")
    refute Enum.any?(domains(doc, "search", "Google"), &String.contains?(&1, "/"))

    # Matomo-only leading {}. wildcards collapse to the parent domain
    assert "startpage.com" in domains(doc, "search", "StartPage")
    refute Enum.any?(domains(doc, "search", "StartPage"), &String.contains?(&1, "{}"))

    # snowplow beats matomo for the same engine name host
    assert doc["search"]["Google"]["platform"] == "google"
  end

  @tag :tmp_dir
  test "writes alias table with hand aliases, names and utm sources", ctx do
    {out, supplement} = paths(ctx.tmp_dir)
    capture_io(fn -> assert {:ok, _} = Update.update([], opts(out, supplement)) end)
    doc = Builder.parse!(File.read!(out))

    assert doc["aliases"]["meta"] == "facebook"
    assert doc["aliases"]["perplexityai"] == "perplexity"
    assert doc["aliases"]["gmail"] == "gmail"
    assert doc["chatbot"]["Perplexity.ai"]["platform"] == "perplexity"
  end

  @tag :tmp_dir
  test "--dry-run writes nothing", ctx do
    {out, supplement} = paths(ctx.tmp_dir)

    output =
      capture_io(fn ->
        assert {:ok, _} = Update.update(["--dry-run"], opts(out, supplement))
      end)

    refute File.exists?(out)
    assert output =~ "dry run"
  end

  @tag :tmp_dir
  test "uses given refs and resolves master when no ref is given", ctx do
    {out, supplement} = paths(ctx.tmp_dir)
    parent = self()

    fetch = fn url ->
      send(parent, {:fetched, url})
      fetch(url)
    end

    capture_io(fn ->
      assert {:ok, _} =
               Update.update(
                 ["--snowplow-ref", "pinned1", "--matomo-ref", "pinned2"],
                 opts(out, supplement, fetch: fetch)
               )
    end)

    assert_received {:fetched,
                     "https://raw.githubusercontent.com/snowplow-referer-parser/referer-parser/pinned1/resources/referers.yml"}

    assert_received {:fetched,
                     "https://raw.githubusercontent.com/matomo-org/searchengine-and-social-list/pinned2/SearchEngines.yml"}

    refute_received {:fetched, "https://api.github.com" <> _}
    assert File.read!(out) =~ "# snowplow: pinned1, matomo: pinned2,"
  end

  @tag :tmp_dir
  test "returns an error and writes nothing when a fetch fails", ctx do
    {out, supplement} = paths(ctx.tmp_dir)

    capture_io(fn ->
      assert {:error, {:fetch_failed, _url, :nxdomain}} =
               Update.update([], opts(out, supplement, fetch: fn _ -> {:error, :nxdomain} end))
    end)

    refute File.exists?(out)
  end

  @tag :tmp_dir
  test "raises on unknown switches", ctx do
    {out, supplement} = paths(ctx.tmp_dir)

    assert_raise Mix.Error, ~r/--bogus/, fn ->
      Update.update(["--bogus"], opts(out, supplement))
    end

    refute File.exists?(out)
  end

  # Helpers

  defp paths(dir) do
    supplement = Path.join(dir, "supplement.yml")
    File.write!(supplement, @supplement)
    {Path.join(dir, "referers.yml"), supplement}
  end

  defp opts(out, supplement, extra \\ []) do
    Keyword.merge(
      [output: out, supplement: supplement, fetch: &fetch/1, today: ~D[2026-01-02]],
      extra
    )
  end

  defp domains(doc, medium, name) do
    case doc[medium][name] do
      nil -> nil
      entry -> entry["domains"] || []
    end
  end

  defp fetch(
         "https://api.github.com/repos/snowplow-referer-parser/referer-parser/commits/master"
       ),
       do: {:ok, ~s({"sha": "#{@snowplow_sha}"})}

  defp fetch(
         "https://api.github.com/repos/matomo-org/searchengine-and-social-list/commits/master"
       ),
       do: {:ok, ~s({"sha": "#{@matomo_sha}"})}

  defp fetch(url) do
    cond do
      String.ends_with?(url, "/resources/referers.yml") -> {:ok, @snowplow}
      String.ends_with?(url, "/SearchEngines.yml") -> {:ok, @matomo_search}
      String.ends_with?(url, "/Socials.yml") -> {:ok, @matomo_socials}
      String.ends_with?(url, "/AIAssistants.yml") -> {:ok, @matomo_ai}
      true -> {:error, {:unexpected_url, url}}
    end
  end
end
