defmodule GoodAnalytics.Core.Sessions.EngagementTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.Sessions
  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Core.Visitors

  @ws GoodAnalytics.default_workspace_id()

  defp record(visitor, type, attrs),
    do: Recorder.record(visitor, type, attrs)

  defp reload_session(id),
    do: GoodAnalytics.TestRepo.get(Session, id, prefix: "good_analytics")

  test "engagement accumulates engaged_seconds and bumps last_event_at on the live session" do
    visitor = create_visitor!()
    {:ok, pv} = record(visitor, "pageview", %{url: "https://x.test/a"})
    session_before = reload_session(pv.session_id)

    {:ok, eng} = record(visitor, "engagement", %{engaged_ms: 12_000, scroll_depth: 75})

    # The engagement event is recorded and tied to the same live session.
    assert eng.session_id == pv.session_id

    session_after = reload_session(pv.session_id)
    assert session_after.engaged_seconds == session_before.engaged_seconds + 12

    assert DateTime.compare(session_after.last_event_at, session_before.last_event_at) in [
             :gt,
             :eq
           ]

    # engaged_ms / scroll_depth persisted on the event properties.
    assert eng.properties["engaged_ms"] == 12_000
    assert eng.properties["scroll_depth"] == 75
  end

  test "engagement increases duration_seconds by the capped event hop" do
    visitor = create_visitor!()
    {:ok, pv} = record(visitor, "pageview", %{url: "https://x.test/a"})
    session_before = reload_session(pv.session_id)
    ts = DateTime.add(session_before.last_event_at, 45, :second)

    assert {:ok, session_after} =
             Sessions.record_engagement(
               %{workspace_id: visitor.workspace_id, visitor_id: visitor.id},
               %{engaged_ms: 5_000},
               ts
             )

    assert session_after.duration_seconds == session_before.duration_seconds + 45

    capped_ts = DateTime.add(session_after.last_event_at, 30 * 60, :second)

    assert {:ok, capped_session} =
             Sessions.record_engagement(
               %{workspace_id: visitor.workspace_id, visitor_id: visitor.id},
               %{engaged_ms: 5_000},
               capped_ts
             )

    assert capped_session.duration_seconds == session_after.duration_seconds + 30 * 60

    stale_ts = DateTime.add(capped_session.last_event_at, 31 * 60, :second)

    assert :no_session =
             Sessions.record_engagement(
               %{workspace_id: visitor.workspace_id, visitor_id: visitor.id},
               %{engaged_ms: 5_000},
               stale_ts
             )
  end

  test "engagement does NOT un-bounce a single-pageview session" do
    visitor = create_visitor!()
    {:ok, pv} = record(visitor, "pageview", %{url: "https://x.test/a"})

    {:ok, _} = record(visitor, "engagement", %{engaged_ms: 30_000})

    assert reload_session(pv.session_id).is_bounce == true
    # ...but enough dwell makes it engaged.
    assert reload_session(pv.session_id).is_engaged == true
  end

  test "engagement with no live session is dropped without creating a session" do
    # A visitor with no prior pageview => no live session.
    visitor = create_visitor!()

    sessions_before =
      from(s in Session, where: s.workspace_id == ^@ws)
      |> GoodAnalytics.TestRepo.aggregate(:count, prefix: "good_analytics")

    assert {:ok, :dropped} = record(visitor, "engagement", %{engaged_ms: 5_000})

    sessions_after =
      from(s in Session, where: s.workspace_id == ^@ws)
      |> GoodAnalytics.TestRepo.aggregate(:count, prefix: "good_analytics")

    assert sessions_after == sessions_before
    assert Visitors.get_visitor(visitor.id).total_sessions == 0
    assert Events.count_events(@ws, event_type: "engagement") == 0
  end

  test "invalid engagement event attrs do not update the live session" do
    visitor = create_visitor!()
    {:ok, pv} = record(visitor, "pageview", %{url: "https://x.test/a"})
    session_before = reload_session(pv.session_id)

    assert {:error, changeset} =
             record(visitor, "engagement", %{engaged_ms: 12_000, properties: []})

    assert errors_on(changeset)[:properties]

    session_after = reload_session(pv.session_id)
    assert session_after.engaged_seconds == session_before.engaged_seconds
    assert session_after.duration_seconds == session_before.duration_seconds
    assert session_after.last_event_at == session_before.last_event_at
  end
end
