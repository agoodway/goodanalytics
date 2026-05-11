defmodule GoodAnalytics.PartitionManagerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.PartitionManager
  alias GoodAnalytics.TestRepo

  @schema "good_analytics"

  describe "create_partitions_direct/0" do
    test "creates the current and next two months when default partition is empty" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      :ok = PartitionManager.create_partitions_direct()

      partitions = list_partitions()

      for offset <- 0..2 do
        name = PartitionManager.partition_name(month_start(offset))
        assert name in partitions, "missing partition #{name}; got #{inspect(partitions)}"
      end
    end

    test "drains rows from the default partition into a new monthly partition on check_violation" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      polluting_at = DateTime.utc_now() |> DateTime.truncate(:second)
      polluted_id = Ecto.UUID.generate()
      workspace_id = Ecto.UUID.generate()
      visitor_id = Ecto.UUID.generate()

      insert_default_event!(polluted_id, workspace_id, visitor_id, polluting_at)

      assert default_count_in_window(polluting_at) == 1

      :ok = PartitionManager.create_partitions_direct()

      assert default_count_in_window(polluting_at) == 0

      partition = PartitionManager.partition_name(month_start(0))
      assert partition_count(partition, polluted_id) == 1
    end
  end

  describe "process_partitions/0" do
    test "returns one map per processed month with required keys and :ok status" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      results = PartitionManager.process_partitions()

      assert is_list(results)
      assert length(results) >= PartitionManager.months_ahead() + 1

      for result <- results do
        assert %{partition_name: name, month_start: %Date{}, status: status} = result
        assert is_binary(name)
        assert status in [:ok, :recovered]
      end

      partitions = list_partitions()

      for offset <- 0..PartitionManager.months_ahead() do
        name = PartitionManager.partition_name(month_start(offset))
        assert name in partitions
      end
    end

    test "marks the polluted month as :recovered" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      polluting_at = DateTime.utc_now() |> DateTime.truncate(:second)
      polluted_id = Ecto.UUID.generate()
      workspace_id = Ecto.UUID.generate()
      visitor_id = Ecto.UUID.generate()

      insert_default_event!(polluted_id, workspace_id, visitor_id, polluting_at)

      results = PartitionManager.process_partitions()

      current_month = month_start(0)
      current = Enum.find(results, &(&1.month_start == current_month))

      assert current.status == :recovered
    end

    test "does NOT pick up rows from older months in default (broad scan removed)" do
      # Older polluted months should be left alone by the tick path.
      # Operators must run `mix good_analytics.recover_default` to address them.
      drop_recent_monthly_partitions!()
      truncate_default!()

      old_at =
        DateTime.utc_now()
        |> DateTime.add(-100, :day)
        |> DateTime.truncate(:second)

      old_id = Ecto.UUID.generate()
      workspace_id = Ecto.UUID.generate()
      visitor_id = Ecto.UUID.generate()

      insert_default_event!(old_id, workspace_id, visitor_id, old_at)

      results = PartitionManager.process_partitions()

      old_month_start = old_at |> DateTime.to_date() |> Date.beginning_of_month()
      refute Enum.any?(results, &(&1.month_start == old_month_start))

      # The old polluted row remains in default — tick path should not touch it.
      old_partition = PartitionManager.partition_name(old_month_start)
      partitions = list_partitions()
      refute old_partition in partitions
    end
  end

  describe "ensure_initial_partitions/0" do
    test "creates the same set as process_partitions/0" do
      drop_recent_monthly_partitions!()
      truncate_default!()

      results = PartitionManager.ensure_initial_partitions()

      assert is_list(results)
      assert length(results) == PartitionManager.months_ahead() + 1

      partitions = list_partitions()

      for offset <- 0..PartitionManager.months_ahead() do
        name = PartitionManager.partition_name(month_start(offset))
        assert name in partitions
      end
    end
  end

  describe "advisory_lock_key/0" do
    test "is a stable integer derived from the schema prefix" do
      key = PartitionManager.advisory_lock_key()
      assert is_integer(key)
      assert key >= 0
      # Stable across calls
      assert PartitionManager.advisory_lock_key() == key
    end
  end

  defp month_start(offset) do
    today = Date.utc_today()
    Date.new!(today.year, today.month, 1) |> Date.shift(month: offset)
  end

  defp list_partitions do
    {:ok, %{rows: rows}} =
      TestRepo.query("""
      SELECT inhrelid::regclass::text
      FROM pg_inherits
      WHERE inhparent = '#{@schema}.ga_events'::regclass
      """)

    Enum.map(rows, fn [name] -> name |> String.split(".") |> List.last() end)
  end

  defp default_count_in_window(%DateTime{} = at) do
    month = month_start(0)
    next_month = Date.shift(month, month: 1)

    {:ok, %{rows: [[count]]}} =
      TestRepo.query(
        ~s|SELECT count(*) FROM "#{@schema}".ga_events_default
           WHERE inserted_at >= $1::timestamptz AND inserted_at < $2::timestamptz|,
        [
          DateTime.new!(month, ~T[00:00:00], "Etc/UTC"),
          DateTime.new!(next_month, ~T[00:00:00], "Etc/UTC")
        ]
      )

    _ = at
    count
  end

  defp partition_count(partition_name, id) do
    {:ok, %{rows: [[count]]}} =
      TestRepo.query(
        ~s|SELECT count(*) FROM "#{@schema}"."#{partition_name}" WHERE id = $1::uuid|,
        [Ecto.UUID.dump!(id)]
      )

    count
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
end
