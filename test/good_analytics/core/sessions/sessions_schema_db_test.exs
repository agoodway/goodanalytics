defmodule GoodAnalytics.Core.Sessions.SessionsSchemaDBTest do
  use GoodAnalytics.DataCase, async: false

  @session_columns ~w(
    id workspace_id visitor_id anonymous_id started_at last_event_at
    entry_url entry_page exit_page pageviews events duration_seconds
    engaged_seconds is_bounce is_engaged source_platform source_medium
    source_campaign click_id device_type browser os inserted_at updated_at
  )

  defp columns(table) do
    %{rows: rows} =
      GoodAnalytics.TestRepo.query!(
        """
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema = 'good_analytics' AND table_name = $1
        """,
        [table]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  test "ga_sessions has all session columns (V10 schema)" do
    present = columns("ga_sessions")

    for col <- @session_columns do
      assert MapSet.member?(present, col), "expected ga_sessions.#{col} to exist"
    end
  end

  test "ga_events has a session_id column (V10 schema)" do
    assert MapSet.member?(columns("ga_events"), "session_id")
  end

  test "the (workspace_id, session_id) index exists on ga_events" do
    %{rows: rows} =
      GoodAnalytics.TestRepo.query!(
        """
        SELECT
          pg_get_indexdef(i.indexrelid),
          pg_get_expr(i.indpred, i.indrelid),
          i.indisvalid
        FROM pg_index i
        JOIN pg_class idx ON idx.oid = i.indexrelid
        JOIN pg_namespace ns ON ns.oid = idx.relnamespace
        WHERE ns.nspname = 'good_analytics'
          AND idx.relname = 'idx_ga_events_workspace_session'
        """,
        []
      )

    assert [[indexdef, predicate, true]] = rows
    assert indexdef =~ "ON ONLY good_analytics.ga_events"
    assert indexdef =~ "(workspace_id, session_id, inserted_at DESC)"
    assert predicate == "(session_id IS NOT NULL)"
  end
end
