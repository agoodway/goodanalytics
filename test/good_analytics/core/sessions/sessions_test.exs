defmodule GoodAnalytics.Core.SessionsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Sessions
  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Core.Visitors

  @ws GoodAnalytics.default_workspace_id()

  defp sessionize(vid, event_type, attrs, ts) do
    Sessions.sessionize(
      %{workspace_id: @ws, visitor_id: vid, anonymous_id: Map.get(attrs, :anonymous_id)},
      event_type,
      Map.put(attrs, :__ts__, ts)
    )
  end

  describe "sessionize/3 - creation and continuation" do
    test "creates a new session for a visitor's first event and increments visitor.total_sessions" do
      visitor =
        create_visitor!(%{anonymous_ids: ["anon-1"]})

      vid = visitor.id
      ts = DateTime.utc_now()

      assert {:ok, %Session{} = session} =
               sessionize(vid, "pageview", %{url: "https://x.test/a", path: "/a"}, ts)

      assert session.visitor_id == vid
      assert session.pageviews == 1
      assert session.is_bounce == true

      assert Visitors.get_visitor(visitor.id).total_sessions == 1
    end

    test "continues the same session for events under 30 minutes apart" do
      vid = create_visitor!().id
      t0 = DateTime.utc_now()

      {:ok, s1} = sessionize(vid, "pageview", %{path: "/a"}, t0)
      {:ok, s2} = sessionize(vid, "pageview", %{path: "/b"}, DateTime.add(t0, 20 * 60, :second))

      assert s2.id == s1.id
      assert s2.pageviews == 2
      assert s2.is_bounce == false
      assert s2.exit_page == "/b"
    end

    test "starts a new session after a >30-minute inactivity gap" do
      vid = create_visitor!().id
      t0 = DateTime.utc_now()

      {:ok, s1} = sessionize(vid, "pageview", %{path: "/a"}, t0)
      {:ok, s2} = sessionize(vid, "pageview", %{path: "/b"}, DateTime.add(t0, 31 * 60, :second))

      refute s2.id == s1.id
    end
  end

  describe "sessionize/3 - acquisition boundary" do
    test "splits when a non-direct acquisition changes mid-window" do
      vid = create_visitor!().id
      t0 = DateTime.utc_now()

      {:ok, s1} =
        sessionize(
          vid,
          "pageview",
          %{path: "/a", source_platform: "google", source_medium: "cpc"},
          t0
        )

      {:ok, s2} =
        sessionize(
          vid,
          "pageview",
          %{path: "/b", source_platform: "facebook", source_medium: "cpc"},
          DateTime.add(t0, 60, :second)
        )

      refute s2.id == s1.id
      assert s2.source_platform == "facebook"
    end

    test "direct-to-known guard: a direct session adopts a later source in place (no split)" do
      vid = create_visitor!().id
      t0 = DateTime.utc_now()

      {:ok, s1} = sessionize(vid, "pageview", %{path: "/a"}, t0)

      {:ok, s2} =
        sessionize(
          vid,
          "pageview",
          %{path: "/b", source_platform: "google", source_medium: "organic"},
          DateTime.add(t0, 60, :second)
        )

      assert s2.id == s1.id
      assert s2.source_platform == "google"
      assert s2.source_medium == "organic"
    end
  end

  describe "sessionize/3 - anonymous fallback" do
    test "keys by anonymous_id when the visitor_id is freshly minted but anon matches" do
      vid1 = create_visitor!().id
      vid2 = create_visitor!().id
      t0 = DateTime.utc_now()

      {:ok, s1} =
        Sessions.sessionize(
          %{workspace_id: @ws, visitor_id: vid1, anonymous_id: "shared-anon"},
          "pageview",
          %{path: "/a", __ts__: t0}
        )

      {:ok, s2} =
        Sessions.sessionize(
          %{workspace_id: @ws, visitor_id: vid2, anonymous_id: "shared-anon"},
          "pageview",
          %{path: "/b", __ts__: DateTime.add(t0, 60, :second)}
        )

      assert s2.id == s1.id
      assert s2.visitor_id == vid2
      assert Visitors.get_visitor(vid1).total_sessions == 0
      assert Visitors.get_visitor(vid2).total_sessions == 1
    end

    test "blank anonymous_id is treated as absent" do
      vid1 = create_visitor!().id
      vid2 = create_visitor!().id
      t0 = DateTime.utc_now()

      {:ok, s1} =
        Sessions.sessionize(
          %{workspace_id: @ws, visitor_id: vid1, anonymous_id: ""},
          "pageview",
          %{path: "/a", __ts__: t0}
        )

      {:ok, s2} =
        Sessions.sessionize(
          %{workspace_id: @ws, visitor_id: vid2, anonymous_id: "   "},
          "pageview",
          %{path: "/b", __ts__: DateTime.add(t0, 60, :second)}
        )

      refute s2.id == s1.id
      assert s1.anonymous_id == nil
      assert s2.anonymous_id == nil
      assert Visitors.get_visitor(vid1).total_sessions == 1
      assert Visitors.get_visitor(vid2).total_sessions == 1
    end

    test "parallel fresh visitor ids with the same anonymous_id produce one session" do
      visitor_ids = for _ <- 1..8, do: create_visitor!().id
      anonymous_id = "race-anon"
      ts = DateTime.utc_now()

      tasks =
        for {vid, i} <- Enum.with_index(visitor_ids, 1) do
          Task.async(fn ->
            Sessions.sessionize(
              %{workspace_id: @ws, visitor_id: vid, anonymous_id: anonymous_id},
              "pageview",
              %{path: "/p#{i}", __ts__: ts}
            )
          end)
        end

      results = Task.await_many(tasks, 5_000)
      ids = results |> Enum.map(fn {:ok, s} -> s.id end) |> Enum.uniq()

      assert length(ids) == 1

      count =
        from(s in Session, where: s.anonymous_id == ^anonymous_id)
        |> GoodAnalytics.TestRepo.aggregate(:count, prefix: "good_analytics")

      assert count == 1

      session =
        GoodAnalytics.TestRepo.one!(
          from(s in Session, where: s.anonymous_id == ^anonymous_id),
          prefix: "good_analytics"
        )

      visitor_session_counts =
        Map.new(visitor_ids, fn vid ->
          {vid, Visitors.get_visitor(vid).total_sessions}
        end)

      assert visitor_session_counts[session.visitor_id] == 1

      for {vid, total_sessions} <- visitor_session_counts, vid != session.visitor_id do
        assert total_sessions == 0
      end
    end
  end

  describe "sessionize/3 - concurrency (advisory lock)" do
    test "parallel same-visitor events produce a single session" do
      vid = create_visitor!().id
      ts = DateTime.utc_now()

      tasks =
        for i <- 1..8 do
          Task.async(fn ->
            sessionize(vid, "pageview", %{path: "/p#{i}"}, ts)
          end)
        end

      results = Task.await_many(tasks, 5_000)
      ids = results |> Enum.map(fn {:ok, s} -> s.id end) |> Enum.uniq()

      assert length(ids) == 1

      count =
        from(s in Session, where: s.visitor_id == ^vid)
        |> GoodAnalytics.TestRepo.aggregate(:count, prefix: "good_analytics")

      assert count == 1
    end
  end
end
