defmodule GoodAnalytics.Core.Events.DeviceBackfillTest do
  use GoodAnalytics.DataCase, async: false

  import Ecto.Query

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.{DeviceBackfill, Event}

  @desktop_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  defp insert_legacy_event!(attrs) do
    seed = %Event{id: Uniq.UUID.uuid7(), inserted_at: DateTime.utc_now()}

    cast_attrs =
      Map.merge(
        %{
          workspace_id: GoodAnalytics.default_workspace_id(),
          visitor_id: Uniq.UUID.uuid7(),
          event_type: "pageview"
        },
        attrs
      )

    seed
    |> Event.changeset(cast_attrs)
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  defp insert_legacy_event_with_id!(id, inserted_at, attrs) do
    seed = %Event{id: id, inserted_at: inserted_at}

    cast_attrs =
      Map.merge(
        %{
          workspace_id: GoodAnalytics.default_workspace_id(),
          visitor_id: Uniq.UUID.uuid7(),
          event_type: "pageview"
        },
        attrs
      )

    seed
    |> Event.changeset(cast_attrs)
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  describe "run_batch/1" do
    test "parses user_agent into device columns for null-device rows" do
      event = insert_legacy_event!(%{user_agent: @desktop_ua})
      assert event.device_type == nil

      assert {:updated, 1, _cursor} = DeviceBackfill.run_batch(batch_size: 100)

      reloaded = Events.get_by_id(event.id)
      assert reloaded.device_type == "desktop"
      assert reloaded.browser == "Chrome"
      assert reloaded.os == "Mac"
      assert reloaded.browser_version == "120.0.0.0"
      assert reloaded.os_version == "10.15.7"
      assert reloaded.device_brand == "Apple"
    end

    test "skips rows with no user_agent (leaves device NULL)" do
      event = insert_legacy_event!(%{user_agent: nil})

      assert {:done, 0} = DeviceBackfill.run_batch(batch_size: 100)
      assert Events.get_by_id(event.id).device_type == nil
    end

    test "marks unparseable nonblank user_agent rows as unknown" do
      event = insert_legacy_event!(%{user_agent: "x"})

      assert {:updated, 1, _cursor} = DeviceBackfill.run_batch(batch_size: 100)
      assert Events.get_by_id(event.id).device_type == "unknown"
      assert {:done, 0} = DeviceBackfill.run_batch(batch_size: 100)
    end

    test "marks browser-only parsed user_agent rows with terminal unknown device_type" do
      event = insert_legacy_event!(%{user_agent: "curl/8.0.1"})

      assert {:updated, 1, _cursor} = DeviceBackfill.run_batch(batch_size: 100)

      reloaded = Events.get_by_id(event.id)
      assert reloaded.device_type == "unknown"
      assert reloaded.browser == "curl"
      assert reloaded.browser_version == "8.0.1"
      assert {:done, 0} = DeviceBackfill.run_batch(batch_size: 100)
    end

    test "returns {:done, 0} when there is nothing to backfill" do
      assert {:done, 0} = DeviceBackfill.run_batch(batch_size: 100)
    end

    test "updates rows by composite id and inserted_at" do
      id = Uniq.UUID.uuid7()
      first_at = ~U[2026-01-01 00:00:00.000000Z]
      second_at = ~U[2026-01-02 00:00:00.000000Z]

      first = insert_legacy_event_with_id!(id, first_at, %{user_agent: @desktop_ua})
      second = insert_legacy_event_with_id!(id, second_at, %{user_agent: @desktop_ua})

      assert {:updated, 1, %{id: ^id, inserted_at: ^first_at}} =
               DeviceBackfill.run_batch(batch_size: 1)

      assert reloaded(first).device_type == "desktop"
      assert reloaded(second).device_type == nil
    end
  end

  describe "run/1 (runtime-callable resumable loop)" do
    test "backfills all UA-bearing rows across multiple batches without Mix" do
      for _ <- 1..5, do: insert_legacy_event!(%{user_agent: @desktop_ua})

      assert {:ok, 5} = DeviceBackfill.run(batch_size: 2)

      count =
        from(e in Event, where: e.device_type == "desktop")
        |> GoodAnalytics.TestRepo.aggregate(:count, prefix: "good_analytics")

      assert count == 5
    end

    test "is idempotent -- a second run does no work" do
      insert_legacy_event!(%{user_agent: @desktop_ua})
      assert {:ok, 1} = DeviceBackfill.run(batch_size: 10)
      assert {:ok, 0} = DeviceBackfill.run(batch_size: 10)
    end
  end

  defp reloaded(%Event{} = event) do
    from(e in Event,
      where: e.id == ^event.id,
      where: e.inserted_at == ^event.inserted_at,
      limit: 1
    )
    |> GoodAnalytics.TestRepo.one(prefix: "good_analytics")
  end
end
