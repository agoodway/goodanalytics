defmodule GoodAnalytics.Core.Events.PartnerSnapshotTest do
  @moduledoc """
  Tests for partner attribution snapshot persistence and immutability on events.

  The event's partner_id / referral_link_id / referral_click_id columns are
  written at ingest time and must never change, even if the owning visitor's
  partner attribution is later updated.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.Visitors.Visitor

  @workspace_id GoodAnalytics.default_workspace_id()

  @partner_id "cccccccc-0000-7000-8000-000000000001"
  @partner_id_2 "dddddddd-0000-7000-8000-000000000002"
  @link_id "cccccccc-0000-7000-8000-000000000011"
  @click_id "cccccccc-0000-7000-8000-000000000021"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_visitor!(attrs \\ %{}) do
    base = %{
      workspace_id: @workspace_id,
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.Repo.repo().insert!(prefix: GoodAnalytics.schema_name())
  end

  defp update_visitor_last_partner!(visitor, partner_id) do
    visitor
    |> Visitor.changeset(%{last_partner_id: partner_id})
    |> GoodAnalytics.Repo.repo().update!(prefix: GoodAnalytics.schema_name())
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "record/3 — partner attribution snapshot" do
    test "event persists partner_id, referral_link_id, referral_click_id from attrs" do
      visitor = insert_visitor!()

      assert {:ok, event} =
               Recorder.record(visitor, "pageview", %{
                 partner_id: @partner_id,
                 referral_link_id: @link_id,
                 referral_click_id: @click_id,
                 url: "https://example.com"
               })

      assert event.partner_id == @partner_id
      assert event.referral_link_id == @link_id
      assert event.referral_click_id == @click_id

      # Verify the values survive a round-trip through the DB
      db_event = Events.get_by_id(event.id)
      assert db_event.partner_id == @partner_id
      assert db_event.referral_link_id == @link_id
      assert db_event.referral_click_id == @click_id
    end

    test "event without partner attrs has nil partner fields" do
      visitor = insert_visitor!()

      assert {:ok, event} =
               Recorder.record(visitor, "pageview", %{url: "https://example.com"})

      assert is_nil(event.partner_id)
      assert is_nil(event.referral_link_id)
      assert is_nil(event.referral_click_id)
    end

    test "event partner snapshot is immutable after visitor's last_partner_id changes" do
      visitor =
        insert_visitor!(%{
          last_partner_id: @partner_id,
          last_referral_link_id: @link_id,
          last_referral_click_id: @click_id
        })

      assert {:ok, event} =
               Recorder.record(visitor, "sale", %{
                 partner_id: @partner_id,
                 referral_link_id: @link_id,
                 referral_click_id: @click_id,
                 amount_cents: 4900,
                 currency: "USD"
               })

      assert event.partner_id == @partner_id

      # Simulate visitor attribution being updated (e.g. new referral visit)
      _updated_visitor = update_visitor_last_partner!(visitor, @partner_id_2)

      # The original event row must be unchanged
      db_event = Events.get_by_id(event.id)

      assert db_event.partner_id == @partner_id,
             "event partner snapshot must not change when visitor attribution is updated"
    end
  end

  describe "record_click/3 — partner attribution snapshot" do
    test "link click event stores partner context from attrs" do
      visitor = insert_visitor!()
      link = create_link!()
      click_id = Uniq.UUID.uuid7()

      assert {:ok, event} =
               Recorder.record_click(visitor, link, %{
                 click_id: click_id,
                 partner_id: @partner_id,
                 referral_link_id: @link_id,
                 referral_click_id: @click_id
               })

      assert event.event_type == "link_click"
      assert event.partner_id == @partner_id
      assert event.referral_link_id == @link_id
      assert event.referral_click_id == @click_id
    end

    test "link click event without partner attrs has nil partner fields" do
      visitor = insert_visitor!()
      link = create_link!()
      click_id = Uniq.UUID.uuid7()

      assert {:ok, event} = Recorder.record_click(visitor, link, %{click_id: click_id})

      assert is_nil(event.partner_id)
      assert is_nil(event.referral_link_id)
      assert is_nil(event.referral_click_id)
    end
  end

  describe "record_sale/2 — partner attribution snapshot" do
    test "sale event stores partner context from attrs" do
      visitor = insert_visitor!()

      assert {:ok, event} =
               Recorder.record_sale(visitor, %{
                 partner_id: @partner_id,
                 referral_link_id: @link_id,
                 referral_click_id: @click_id,
                 amount_cents: 9900,
                 currency: "USD"
               })

      assert event.event_type == "sale"
      assert event.amount_cents == 9900
      assert event.partner_id == @partner_id
      assert event.referral_link_id == @link_id
      assert event.referral_click_id == @click_id

      # Verify persistence
      db_event = Events.get_by_id(event.id)
      assert db_event.partner_id == @partner_id
      assert db_event.referral_link_id == @link_id
      assert db_event.referral_click_id == @click_id
    end

    test "sale event without partner attrs has nil partner fields" do
      visitor = insert_visitor!()

      assert {:ok, event} =
               Recorder.record_sale(visitor, %{amount_cents: 1000, currency: "USD"})

      assert is_nil(event.partner_id)
      assert is_nil(event.referral_link_id)
      assert is_nil(event.referral_click_id)
    end
  end
end
