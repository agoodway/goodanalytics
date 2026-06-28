defmodule GoodAnalytics.Core.Sessions.AcquisitionTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Sessions.Acquisition
  alias GoodAnalytics.Core.Sessions.Session

  defp session(attrs), do: struct(%Session{}, attrs)

  describe "direct?/1" do
    test "true when no acquisition signals are present" do
      assert Acquisition.direct?(%{
               source_platform: nil,
               source_medium: nil,
               source_campaign: nil,
               click_id: nil
             })
    end

    test "true for empty-string signals (normalized to nil)" do
      assert Acquisition.direct?(%{source_platform: "", source_medium: "  "})
    end

    test "true for direct sentinels when no campaign or click_id is present" do
      assert Acquisition.direct?(%{source_platform: "direct", source_medium: "direct"})
      assert Acquisition.direct?(%{source_platform: :direct, source_medium: :direct})
    end

    test "false when any real acquisition signal is present" do
      refute Acquisition.direct?(%{source_platform: "google"})
      refute Acquisition.direct?(%{click_id: Uniq.UUID.uuid7()})
    end

    test "false when direct sentinels carry campaign or click_id context" do
      refute Acquisition.direct?(%{source_platform: "direct", source_campaign: "spring"})
      refute Acquisition.direct?(%{source_medium: :direct, click_id: Uniq.UUID.uuid7()})
    end
  end

  describe "decision/2 — continue vs new vs update_source" do
    test "continue when the new event has no acquisition (direct events never split)" do
      live = session(source_platform: "google", source_medium: "cpc")
      assert Acquisition.decision(live, %{source_platform: nil}) == :continue
    end

    test "continue when the new event is explicit direct traffic" do
      live = session(source_platform: "google", source_medium: "cpc")

      assert Acquisition.decision(live, %{
               source_platform: "direct",
               source_medium: "direct"
             }) == :continue
    end

    test "continue when acquisition is unchanged" do
      live = session(source_platform: "google", source_medium: "cpc", source_campaign: "spring")

      assert Acquisition.decision(live, %{
               source_platform: "google",
               source_medium: "cpc",
               source_campaign: "spring"
             }) == :continue
    end

    test "new_session when a non-direct acquisition meaningfully differs" do
      live = session(source_platform: "google", source_medium: "cpc")

      assert Acquisition.decision(live, %{source_platform: "facebook", source_medium: "cpc"}) ==
               :new_session
    end

    test "new_session on a click_id change" do
      live = session(click_id: Uniq.UUID.uuid7())
      assert Acquisition.decision(live, %{click_id: Uniq.UUID.uuid7()}) == :new_session
    end

    test "update_source guard: direct live session + later real source UPDATEs (no split)" do
      live =
        session(source_platform: nil, source_medium: nil, source_campaign: nil, click_id: nil)

      assert Acquisition.decision(live, %{source_platform: "google", source_medium: "organic"}) ==
               :update_source
    end

    test "update_source guard handles explicit direct live sessions" do
      live =
        session(
          source_platform: "direct",
          source_medium: "direct",
          source_campaign: nil,
          click_id: nil
        )

      assert Acquisition.decision(live, %{source_platform: "google", source_medium: "organic"}) ==
               :update_source
    end

    test "compares only acquisition signals, not referrer host" do
      live = session(source_platform: "google", source_medium: "organic")

      # Same acquisition, different referrer — must NOT split.
      assert Acquisition.decision(live, %{
               source_platform: "google",
               source_medium: "organic",
               referrer: "https://news.ycombinator.com/"
             }) == :continue
    end

    test "supports string-keyed attrs from decoded payloads" do
      live = session(source_platform: "google", source_medium: "organic")

      assert Acquisition.decision(live, %{
               "source_platform" => "google",
               "source_medium" => "organic"
             }) == :continue
    end

    test "canonicalizes equivalent click_id values before comparing" do
      click_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
      live = session(click_id: String.upcase(click_id))

      assert Acquisition.decision(live, %{click_id: click_id}) == :continue
    end
  end

  describe "to_session_acquisition/1" do
    test "extracts normalized acquisition attrs for a new session" do
      attrs =
        Acquisition.to_session_acquisition(%{
          source_platform: "google",
          source_medium: " cpc ",
          source_campaign: "",
          click_id: nil,
          irrelevant: "x"
        })

      assert attrs.source_platform == "google"
      assert attrs.source_medium == "cpc"
      assert attrs.source_campaign == nil
      refute Map.has_key?(attrs, :irrelevant)
    end

    test "normalizes direct sentinels and canonicalizes click_id" do
      attrs =
        Acquisition.to_session_acquisition(%{
          "source_platform" => "direct",
          "source_medium" => :direct,
          "click_id" => "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
        })

      assert attrs.source_platform == nil
      assert attrs.source_medium == nil
      assert attrs.click_id == "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    end
  end
end
