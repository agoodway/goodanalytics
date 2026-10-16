defmodule GoodAnalytics.Migrations.IdentityMergeRepairTest do
  use GoodAnalytics.DataCase, async: false

  alias EctoEvolver.Adapters.Postgres
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Core.Visitors.Visitor

  test "recovers all identifier arrays through merge chains and remains idempotent" do
    workspace_id = Uniq.UUID.uuid7()
    primary_click = Uniq.UUID.uuid7()
    old_click = Uniq.UUID.uuid7()
    primary = visitor(workspace_id, %{anonymous_ids: ["primary"], click_ids: [primary_click]})

    intermediate =
      visitor(workspace_id, %{
        status: "merged",
        merged_into_id: primary.id,
        anonymous_ids: ["second", "primary"],
        fingerprints: ["second-device"]
      })

    oldest =
      visitor(workspace_id, %{
        status: "merged",
        merged_into_id: intermediate.id,
        anonymous_ids: ["third"],
        fingerprints: ["third-device"],
        click_ids: [old_click]
      })

    assert %{num_rows: 1} = run_repair()
    repaired = Visitors.get_visitor(primary.id)
    assert Enum.sort(repaired.anonymous_ids) == ["primary", "second", "third"]
    assert Enum.sort(repaired.fingerprints) == ["second-device", "third-device"]
    assert Enum.sort(repaired.click_ids) == Enum.sort([primary_click, old_click])
    assert repaired.person_email == primary.person_email
    assert repaired.person_external_id == primary.person_external_id
    assert repaired.geo == primary.geo
    assert repaired.last_seen_at == primary.last_seen_at
    assert Visitors.get_visitor(intermediate.id) == intermediate
    assert Visitors.get_visitor(oldest.id) == oldest

    assert %{num_rows: 0} = run_repair()
    assert Visitors.get_visitor(primary.id) == repaired

    for signal <- [
          %{anonymous_id: "third"},
          %{fingerprint: "third-device"},
          %{click_id: old_click}
        ] do
      assert {:ok, %{id: id}} = IdentityResolver.resolve(signal, workspace_id: workspace_id)
      assert id == primary.id
    end
  end

  test "keeps unrelated workspaces, broken links, and cycles untouched" do
    workspace_id = Uniq.UUID.uuid7()
    primary = visitor(workspace_id, %{anonymous_ids: ["same-cookie"]})
    unrelated = visitor(workspace_id, %{anonymous_ids: ["same-cookie"]})

    foreign =
      visitor(Uniq.UUID.uuid7(), %{
        status: "merged",
        merged_into_id: primary.id,
        anonymous_ids: ["foreign-cookie"]
      })

    dangling = visitor(workspace_id, %{status: "merged", merged_into_id: Uniq.UUID.uuid7()})
    cycle1 = visitor(workspace_id, %{status: "merged"})
    cycle2 = visitor(workspace_id, %{status: "merged", merged_into_id: cycle1.id})

    cycle1 =
      cycle1
      |> Ecto.Changeset.change(merged_into_id: cycle2.id)
      |> TestRepo.update!()

    before = [primary, unrelated, foreign, dangling, cycle1, cycle2]
    run_repair()
    assert Enum.map(before, &Visitors.get_visitor(&1.id)) == before
  end

  test "uses an alternate schema and handles legacy null arrays" do
    prefix = "merge_repair_#{System.unique_integer([:positive])}"
    escaped = Postgres.escape_identifier(prefix)
    base = Postgres.escape_identifier(GoodAnalytics.schema_name())
    TestRepo.query!("CREATE SCHEMA #{escaped}")

    TestRepo.query!(
      "CREATE TABLE #{escaped}.ga_visitors (LIKE #{base}.ga_visitors INCLUDING ALL)"
    )

    workspace_id = Uniq.UUID.uuid7()

    primary =
      visitor(workspace_id, %{anonymous_ids: nil, fingerprints: nil, click_ids: nil}, prefix)

    visitor(
      workspace_id,
      %{status: "merged", merged_into_id: primary.id, anonymous_ids: ["restored-cookie"]},
      prefix
    )

    run_repair(prefix)
    repaired = TestRepo.get!(from(v in Visitor, prefix: ^prefix), primary.id)
    assert repaired.anonymous_ids == ["restored-cookie"]
    assert repaired.fingerprints == []
    assert repaired.click_ids == []
  end

  defp run_repair(prefix \\ GoodAnalytics.schema_name()) do
    :good_analytics
    |> :code.priv_dir()
    |> Path.join("good_analytics/sql/versions/v14/v14_up.sql")
    |> File.read!()
    |> String.replace("$SCHEMA$", Postgres.escape_identifier(prefix))
    |> String.split("--SPLIT--")
    |> Enum.map(&TestRepo.query!/1)
    |> List.last()
  end

  defp visitor(workspace_id, attrs, prefix \\ GoodAnalytics.schema_name()) do
    now = DateTime.utc_now()

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(
      Map.merge(%{workspace_id: workspace_id, first_seen_at: now, last_seen_at: now}, attrs)
    )
    |> TestRepo.insert!(prefix: prefix)
  end
end
