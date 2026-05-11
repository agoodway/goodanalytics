defmodule GoodAnalytics.Flows.CreatePartitionsTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Flows.CreatePartitions
  alias GoodAnalytics.PartitionManager
  alias GoodAnalytics.TestRepo

  @schema "good_analytics"

  describe "step :create_partitions" do
    test "returns pgflow-shaped payload with one entry per processed month" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      handler = CreatePartitions.__pgflow_handler__(:create_partitions)
      result = handler.(%{}, %{})

      assert %{"partitions" => partitions, "months_ahead" => months_ahead} = result
      assert is_integer(months_ahead)
      assert months_ahead == PartitionManager.months_ahead()
      assert length(partitions) >= months_ahead + 1

      for entry <- partitions do
        assert %{"partition" => name, "status" => status} = entry
        assert is_binary(name)
        assert status in ~w(ok recovered error)
      end
    end

    test "marks recovered months when default partition is polluted" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      polluting_at = DateTime.utc_now() |> DateTime.truncate(:second)

      insert_default_event!(
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        Ecto.UUID.generate(),
        polluting_at
      )

      handler = CreatePartitions.__pgflow_handler__(:create_partitions)
      %{"partitions" => partitions} = handler.(%{}, %{})

      current_name = PartitionManager.partition_name(month_start(0))
      current = Enum.find(partitions, &(&1["partition"] == current_name))

      assert current["status"] == "recovered"
    end
  end

  defp month_start(offset) do
    today = Date.utc_today()
    Date.new!(today.year, today.month, 1) |> Date.shift(month: offset)
  end

  defp drop_recent_monthly_partitions! do
    for offset <- 0..6 do
      name = PartitionManager.partition_name(month_start(offset))

      TestRepo.query!(
        ~s|ALTER TABLE "#{@schema}".ga_events DETACH PARTITION "#{@schema}"."#{name}"|
      )
      |> drop_silently(name)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp drop_silently(_result, name) do
    TestRepo.query!(~s|DROP TABLE IF EXISTS "#{@schema}"."#{name}"|)
  end

  defp truncate_default! do
    TestRepo.query!(~s|TRUNCATE "#{@schema}".ga_events_default|)
    :ok
  end

  defp insert_default_event!(id, workspace_id, visitor_id, %DateTime{} = inserted_at) do
    TestRepo.query!(
      ~s|INSERT INTO "#{@schema}".ga_events_default
         (id, workspace_id, visitor_id, event_type, inserted_at)
         VALUES ($1::uuid, $2::uuid, $3::uuid, $4, $5::timestamptz)|,
      [
        Ecto.UUID.dump!(id),
        Ecto.UUID.dump!(workspace_id),
        Ecto.UUID.dump!(visitor_id),
        "pageview",
        inserted_at
      ]
    )
  end
end
