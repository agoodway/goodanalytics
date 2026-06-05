defmodule GoodAnalytics.Core.Sessions.BackfillTest do
  use GoodAnalytics.DataCase, async: false

  import Ecto.Query

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Sessions
  alias GoodAnalytics.Core.Sessions.{Backfill, Session}

  @ws GoodAnalytics.default_workspace_id()

  defp insert_event!(visitor_id, type, path, ts, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @ws,
          visitor_id: visitor_id,
          event_type: type,
          path: path
        },
        attrs
      )

    %Event{id: Uniq.UUID.uuid7(), inserted_at: ts}
    |> Event.changeset(attrs)
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  test "builds sessions and stamps session_id for a visitor's historical events" do
    vid = create_visitor!().id
    t0 = ~U[2026-05-01 09:00:00.000000Z]

    e1 = insert_event!(vid, "pageview", "/a", t0)
    e2 = insert_event!(vid, "pageview", "/b", DateTime.add(t0, 10 * 60, :second))
    e3 = insert_event!(vid, "pageview", "/c", DateTime.add(t0, 60 * 60, :second))

    assert {:ok, %{events: 3, sessions: 2}} = Backfill.run(batch_size: 100)

    s1 = Events.get_event(@ws, e1.id).session_id
    s2 = Events.get_event(@ws, e2.id).session_id
    s3 = Events.get_event(@ws, e3.id).session_id

    assert s1 == s2
    refute s3 == s1

    session_count =
      from(s in Session, where: s.visitor_id == ^vid)
      |> GoodAnalytics.TestRepo.aggregate(:count, prefix: "good_analytics")

    assert session_count == 2
  end

  test "is idempotent - a second run does no further work" do
    vid = create_visitor!().id
    insert_event!(vid, "pageview", "/a", ~U[2026-05-01 09:00:00.000000Z])

    assert {:ok, %{events: 1, sessions: 1}} = Backfill.run(batch_size: 100)
    assert {:ok, %{events: 0, sessions: 0}} = Backfill.run(batch_size: 100)
  end

  test "continues sessions across batch boundaries" do
    vid = create_visitor!().id
    t0 = ~U[2026-05-01 09:00:00.000000Z]

    e1 = insert_event!(vid, "pageview", "/a", t0)
    e2 = insert_event!(vid, "pageview", "/b", DateTime.add(t0, 10 * 60, :second))

    assert {:ok, %{events: 2, sessions: 1}} = Backfill.run(batch_size: 1)

    assert Events.get_event(@ws, e1.id).session_id == Events.get_event(@ws, e2.id).session_id
  end

  test "derives session entry and exit pages from url when historical events lack path" do
    vid = create_visitor!().id
    t0 = ~U[2026-05-01 09:00:00.000000Z]

    insert_event!(vid, "pageview", nil, t0, %{
      url: "https://x.test/docs/getting-started?utm_source=seed#hero"
    })

    insert_event!(vid, "pageview", nil, DateTime.add(t0, 10 * 60, :second), %{
      url: "https://x.test/pricing?utm_source=seed#plans"
    })

    assert {:ok, %{events: 2, sessions: 1}} = Backfill.run(batch_size: 100)

    session =
      from(s in Session, where: s.visitor_id == ^vid)
      |> GoodAnalytics.TestRepo.one!(prefix: "good_analytics")

    assert session.entry_page == "/docs/getting-started"
    assert session.exit_page == "/pricing"
  end

  test "splits same-window historical sessions when acquisition changes" do
    vid = create_visitor!().id
    t0 = ~U[2026-05-01 09:00:00.000000Z]

    e1 =
      insert_event!(vid, "pageview", "/a", t0, %{
        source_platform: "google",
        source_medium: "cpc"
      })

    e2 =
      insert_event!(vid, "pageview", "/b", DateTime.add(t0, 10 * 60, :second), %{
        source_platform: "facebook",
        source_medium: "cpc"
      })

    assert {:ok, %{events: 2, sessions: 2}} = Backfill.run(batch_size: 100)

    refute Events.get_event(@ws, e1.id).session_id == Events.get_event(@ws, e2.id).session_id
  end

  test "a stale selected event is skipped if it was already stamped" do
    vid = create_visitor!().id
    ts = ~U[2026-05-01 09:00:00.000000Z]
    event = insert_event!(vid, "pageview", "/a", ts)
    session_id = Uniq.UUID.uuid7()

    from(e in Event, where: e.id == ^event.id and e.inserted_at == ^event.inserted_at)
    |> GoodAnalytics.TestRepo.update_all([set: [session_id: session_id]],
      prefix: "good_analytics"
    )

    assert {:ok, %{events: 0, sessions: 0}} = Backfill.run_batch(batch_size: 100)
  end

  test "does not attach historical events to future live sessions" do
    vid = create_visitor!().id
    historical_ts = ~U[2026-05-01 09:00:00.000000Z]
    future_ts = ~U[2026-05-02 09:00:00.000000Z]
    historical = insert_event!(vid, "pageview", "/historical", historical_ts)

    assert {:ok, future_session} =
             Sessions.sessionize(
               %{workspace_id: @ws, visitor_id: vid},
               "pageview",
               %{path: "/future", __ts__: future_ts}
             )

    assert {:ok, %{events: 1, sessions: 1}} = Backfill.run(batch_size: 100)

    historical_session_id = Events.get_event(@ws, historical.id).session_id

    refute historical_session_id == future_session.id
  end
end
