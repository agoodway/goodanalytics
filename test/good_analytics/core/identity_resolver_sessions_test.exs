defmodule GoodAnalytics.Core.IdentityResolverSessionsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Sessions.Session

  @ws GoodAnalytics.default_workspace_id()

  defp insert_session!(visitor_id, attrs) do
    now = DateTime.utc_now()

    %Session{id: Uniq.UUID.uuid7()}
    |> Session.changeset(
      Map.merge(
        %{
          workspace_id: @ws,
          visitor_id: visitor_id,
          started_at: now,
          last_event_at: now
        },
        attrs
      )
    )
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  test "merge_visitors reassigns ga_sessions.visitor_id to the primary" do
    older =
      create_visitor!(%{
        first_seen_at: ~U[2026-06-01 00:00:00.000000Z],
        ga_id: "ga-primary"
      })

    newer =
      create_visitor!(%{
        first_seen_at: ~U[2026-06-02 00:00:00.000000Z],
        ga_id: "ga-primary"
      })

    click_id = Uniq.UUID.uuid7()

    dup_session =
      insert_session!(newer.id, %{
        source_platform: "google",
        source_medium: "cpc",
        source_campaign: "summer",
        click_id: click_id
      })

    # ga_id is a strong signal => merge_allowed?/2 is true.
    {:ok, primary} =
      IdentityResolver.merge_visitors(older, [newer], %{ga_id: "ga-primary"})

    reassigned = GoodAnalytics.TestRepo.get(Session, dup_session.id, prefix: "good_analytics")
    assert reassigned.visitor_id == primary.id
    assert reassigned.source_platform == "google"
    assert reassigned.source_medium == "cpc"
    assert reassigned.source_campaign == "summer"
    assert reassigned.click_id == click_id
    assert primary.id == older.id
  end
end
