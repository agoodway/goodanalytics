defmodule GoodAnalytics.Core.AudienceParityTest do
  @moduledoc """
  Parity: for single-device visitors (where event device == visitor device),
  the event-grain Audience breakdown agrees with a visitor-grain grouping.
  Cross-device visitors are intentionally excluded — visitor-grain grouping is
  wrong for them, since one visitor spans multiple device buckets.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Audience
  alias GoodAnalytics.Core.Events.Event

  @ws GoodAnalytics.default_workspace_id()

  defp window,
    do: %{start_at: ~U[2026-06-01 00:00:00.000000Z], end_at: ~U[2026-06-30 00:00:00.000000Z]}

  # Monotonic-ish clock inside window/0 so each seeded row is distinct.
  defp seed_clock do
    n = System.unique_integer([:positive, :monotonic])
    DateTime.add(~U[2026-06-15 12:00:00.000000Z], n, :microsecond)
  end

  # Visitor whose `device` JSON matches the device columns on its events.
  # Uses direct Event.changeset inserts so the explicit device_type is preserved;
  # Recorder.record/3 drops device fields and re-derives them from user_agent.
  defp single_device_visitor!(type, n) do
    visitor = create_visitor!(%{device: %{"type" => type}})

    for _ <- 1..n do
      %Event{id: Uniq.UUID.uuid7(), inserted_at: seed_clock()}
      |> Event.changeset(%{
        workspace_id: @ws,
        visitor_id: visitor.id,
        event_type: "pageview",
        url: "https://x.test/p",
        path: "/p",
        device_type: type
      })
      |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
    end

    visitor
  end

  # Computes a visitor-grain device breakdown directly (grouping by the
  # visitor's `device->>'type'`), for comparison against the event-grain query.
  defp visitor_grain_device_breakdown do
    import Ecto.Query

    from(e in GoodAnalytics.Core.Events.Event,
      join: v in GoodAnalytics.Core.Visitors.Visitor,
      on: v.id == e.visitor_id and v.workspace_id == e.workspace_id,
      where: e.workspace_id == ^@ws,
      group_by: fragment("coalesce(?->>'type', '(not set)')", v.device),
      select: %{
        value: fragment("coalesce(?->>'type', '(not set)')", v.device),
        count: count(e.id),
        visitors: count(fragment("coalesce(?, ?)", v.merged_into_id, v.id), :distinct)
      }
    )
    |> GoodAnalytics.Repo.repo().all(prefix: "good_analytics")
    |> Map.new(&{&1.value, &1})
  end

  test "event-grain breakdown matches visitor-grain for single-device visitors" do
    single_device_visitor!("desktop", 3)
    single_device_visitor!("desktop", 2)
    single_device_visitor!("mobile", 4)

    visitor_grain = visitor_grain_device_breakdown()

    event_grain_rows =
      Audience.breakdown(@ws, :device_type, window: window(), metrics: [:events, :users])
      |> Map.new(&{&1.value, &1})

    for {value, visitor_row} <- visitor_grain do
      event_row = Map.fetch!(event_grain_rows, value)
      assert event_row.events == visitor_row.count, "events mismatch for #{value}"
      assert event_row.users == visitor_row.visitors, "users mismatch for #{value}"
    end
  end
end
