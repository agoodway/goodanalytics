defmodule GoodAnalytics.Migrations.NilSourceRepairTest do
  use GoodAnalytics.DataCase, async: false

  alias EctoEvolver.Adapters.Postgres
  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Sessions.Backfill

  @ws GoodAnalytics.default_workspace_id()

  test "turns the legacy 'nil' string into NULL on events and sessions, keeps real sources" do
    visitor_id = create_visitor!().id
    broken = insert_event!(visitor_id, "/a", %{source_platform: "nil", source_medium: "nil"})
    real = insert_event!(visitor_id, "/b", %{source_platform: "google", source_medium: "organic"})

    assert {:ok, _} = Backfill.run(batch_size: 100)

    TestRepo.query!(
      "UPDATE good_analytics.ga_sessions SET source_medium = 'nil', source_campaign = 'nil' WHERE visitor_id = $1",
      [Ecto.UUID.dump!(visitor_id)]
    )

    run_repair()
    run_repair()

    assert %{source_platform: nil, source_medium: nil} = reload(broken)
    assert %{source_platform: "google", source_medium: "organic"} = reload(real)

    assert %{rows: [[nil, nil]]} =
             TestRepo.query!(
               "SELECT source_medium, source_campaign FROM good_analytics.ga_sessions WHERE visitor_id = $1 LIMIT 1",
               [Ecto.UUID.dump!(visitor_id)]
             )
  end

  defp reload(%Event{id: id}), do: Events.get_event(@ws, id)

  defp insert_event!(visitor_id, path, attrs) do
    %Event{id: Uniq.UUID.uuid7(), inserted_at: DateTime.utc_now()}
    |> Event.changeset(
      Map.merge(
        %{workspace_id: @ws, visitor_id: visitor_id, event_type: "pageview", path: path},
        attrs
      )
    )
    |> TestRepo.insert!(prefix: "good_analytics")
  end

  defp run_repair do
    :good_analytics
    |> :code.priv_dir()
    |> Path.join("good_analytics/sql/versions/v15/v15_up.sql")
    |> File.read!()
    |> String.replace("$SCHEMA$", Postgres.escape_identifier(GoodAnalytics.schema_name()))
    |> String.split("--SPLIT--")
    |> Enum.each(&TestRepo.query!/1)
  end
end
