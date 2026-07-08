defmodule GoodAnalytics.Core.Visitors.PartnerMergeTest do
  @moduledoc """
  Tests for visitor merge behavior with partner attribution.

  Verifies that `IdentityResolver.merge_visitors/3` correctly applies
  first-touch-wins and last-touch-wins semantics to partner attribution
  fields when consolidating duplicate visitors.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors.Visitor

  @workspace_id GoodAnalytics.default_workspace_id()

  # Stable UUIDs used as stand-in partner/link/click IDs.
  # No real partner rows are required — the visitor columns are plain UUIDs.
  @partner_a_id "aaaaaaaa-0000-7000-8000-000000000001"
  @partner_b_id "bbbbbbbb-0000-7000-8000-000000000002"

  @link_a_id "aaaaaaaa-0000-7000-8000-000000000011"
  @link_b_id "bbbbbbbb-0000-7000-8000-000000000012"

  @click_a_id "aaaaaaaa-0000-7000-8000-000000000021"
  @click_b_id "bbbbbbbb-0000-7000-8000-000000000022"

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp insert_visitor!(attrs) do
    base = %{
      workspace_id: @workspace_id,
      first_seen_at: DateTime.utc_now(),
      last_seen_at: DateTime.utc_now()
    }

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.Repo.repo().insert!(prefix: GoodAnalytics.schema_name())
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "merge_visitors/3 — partner attribution" do
    test "no partner on either visitor — merged result has nil partner fields" do
      primary = insert_visitor!(%{first_seen_at: ~U[2025-01-01 00:00:00Z]})
      duplicate = insert_visitor!(%{first_seen_at: ~U[2025-01-10 00:00:00Z]})

      assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})

      assert is_nil(merged.first_partner_id)
      assert is_nil(merged.first_referral_link_id)
      assert is_nil(merged.first_referral_click_id)
      assert is_nil(merged.last_partner_id)
      assert is_nil(merged.last_referral_link_id)
      assert is_nil(merged.last_referral_click_id)
    end

    test "only primary has partner — merged keeps primary partner unchanged" do
      primary =
        insert_visitor!(%{
          first_seen_at: ~U[2025-01-01 00:00:00Z],
          last_seen_at: ~U[2025-01-15 00:00:00Z],
          first_partner_id: @partner_a_id,
          first_referral_link_id: @link_a_id,
          first_referral_click_id: @click_a_id,
          last_partner_id: @partner_a_id,
          last_referral_link_id: @link_a_id,
          last_referral_click_id: @click_a_id
        })

      duplicate = insert_visitor!(%{first_seen_at: ~U[2025-01-20 00:00:00Z]})

      assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})

      assert merged.first_partner_id == @partner_a_id
      assert merged.first_referral_link_id == @link_a_id
      assert merged.first_referral_click_id == @click_a_id
      assert merged.last_partner_id == @partner_a_id
      assert merged.last_referral_link_id == @link_a_id
      assert merged.last_referral_click_id == @click_a_id
    end

    test "only duplicate has partner — merged adopts duplicate's partner" do
      primary = insert_visitor!(%{first_seen_at: ~U[2025-01-01 00:00:00Z]})

      duplicate =
        insert_visitor!(%{
          first_seen_at: ~U[2025-01-10 00:00:00Z],
          last_seen_at: ~U[2025-01-20 00:00:00Z],
          first_partner_id: @partner_b_id,
          first_referral_link_id: @link_b_id,
          first_referral_click_id: @click_b_id,
          last_partner_id: @partner_b_id,
          last_referral_link_id: @link_b_id,
          last_referral_click_id: @click_b_id
        })

      assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})

      assert merged.first_partner_id == @partner_b_id
      assert merged.first_referral_link_id == @link_b_id
      assert merged.first_referral_click_id == @click_b_id
      assert merged.last_partner_id == @partner_b_id
      assert merged.last_referral_link_id == @link_b_id
      assert merged.last_referral_click_id == @click_b_id
    end

    test "both have first-touch partner — earliest first_seen_at wins" do
      # primary is older → its first-touch partner must survive
      primary =
        insert_visitor!(%{
          first_seen_at: ~U[2025-01-01 00:00:00Z],
          last_seen_at: ~U[2025-01-05 00:00:00Z],
          first_partner_id: @partner_a_id,
          first_referral_link_id: @link_a_id,
          first_referral_click_id: @click_a_id,
          last_partner_id: @partner_a_id,
          last_referral_link_id: @link_a_id,
          last_referral_click_id: @click_a_id
        })

      duplicate =
        insert_visitor!(%{
          first_seen_at: ~U[2025-02-01 00:00:00Z],
          last_seen_at: ~U[2025-02-10 00:00:00Z],
          first_partner_id: @partner_b_id,
          first_referral_link_id: @link_b_id,
          first_referral_click_id: @click_b_id,
          last_partner_id: @partner_b_id,
          last_referral_link_id: @link_b_id,
          last_referral_click_id: @click_b_id
        })

      assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})

      assert merged.first_partner_id == @partner_a_id,
             "first-touch must come from the visitor with the earliest first_seen_at"

      assert merged.first_referral_link_id == @link_a_id
      assert merged.first_referral_click_id == @click_a_id
    end

    test "both have last-touch partner — latest last_seen_at wins" do
      # primary has an earlier last_seen_at → duplicate's last-touch must win
      primary =
        insert_visitor!(%{
          first_seen_at: ~U[2025-01-01 00:00:00Z],
          last_seen_at: ~U[2025-01-05 00:00:00Z],
          first_partner_id: @partner_a_id,
          first_referral_link_id: @link_a_id,
          first_referral_click_id: @click_a_id,
          last_partner_id: @partner_a_id,
          last_referral_link_id: @link_a_id,
          last_referral_click_id: @click_a_id
        })

      duplicate =
        insert_visitor!(%{
          first_seen_at: ~U[2025-02-01 00:00:00Z],
          last_seen_at: ~U[2025-03-01 00:00:00Z],
          first_partner_id: @partner_b_id,
          first_referral_link_id: @link_b_id,
          first_referral_click_id: @click_b_id,
          last_partner_id: @partner_b_id,
          last_referral_link_id: @link_b_id,
          last_referral_click_id: @click_b_id
        })

      assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})

      assert merged.last_partner_id == @partner_b_id,
             "last-touch must come from the visitor with the latest last_seen_at"

      assert merged.last_referral_link_id == @link_b_id
      assert merged.last_referral_click_id == @click_b_id
    end

    test "first-touch and last-touch referral link and click IDs travel with their partner" do
      # primary is oldest (first-touch owner) but has an earlier last_seen_at
      # (so duplicate owns last-touch). All four referral ID columns should
      # track correctly with their respective touch.
      primary =
        insert_visitor!(%{
          first_seen_at: ~U[2025-01-01 00:00:00Z],
          last_seen_at: ~U[2025-01-31 00:00:00Z],
          first_partner_id: @partner_a_id,
          first_referral_link_id: @link_a_id,
          first_referral_click_id: @click_a_id,
          last_partner_id: @partner_a_id,
          last_referral_link_id: @link_a_id,
          last_referral_click_id: @click_a_id
        })

      duplicate =
        insert_visitor!(%{
          first_seen_at: ~U[2025-02-01 00:00:00Z],
          last_seen_at: ~U[2025-03-15 00:00:00Z],
          first_partner_id: @partner_b_id,
          first_referral_link_id: @link_b_id,
          first_referral_click_id: @click_b_id,
          last_partner_id: @partner_b_id,
          last_referral_link_id: @link_b_id,
          last_referral_click_id: @click_b_id
        })

      assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})

      # First-touch: oldest first_seen_at → partner A
      assert merged.first_partner_id == @partner_a_id
      assert merged.first_referral_link_id == @link_a_id
      assert merged.first_referral_click_id == @click_a_id

      # Last-touch: latest last_seen_at → partner B
      assert merged.last_partner_id == @partner_b_id
      assert merged.last_referral_link_id == @link_b_id
      assert merged.last_referral_click_id == @click_b_id
    end
  end
end
