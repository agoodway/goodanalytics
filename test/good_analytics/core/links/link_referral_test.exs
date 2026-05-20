defmodule GoodAnalytics.Core.Links.LinkReferralTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Links.Link
  alias GoodAnalytics.Core.Partners

  @workspace_id "11111111-1111-1111-1111-111111111111"
  @other_workspace_id "22222222-2222-2222-2222-222222222222"

  # ── Changeset-level tests ──────────────────────────────────────────────────

  describe "Link.changeset/2 — referral partner validation" do
    test "new referral link without partner_id is invalid" do
      changeset =
        Link.changeset(%Link{}, %{
          workspace_id: @workspace_id,
          domain: "mybrand.link",
          key: "promo",
          url: "https://example.com",
          link_type: "referral"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:partner_id] == ["is required for referral links"]
    end

    test "new referral link with partner_id is valid" do
      partner_id = Uniq.UUID.uuid7()

      changeset =
        Link.changeset(%Link{}, %{
          workspace_id: @workspace_id,
          domain: "mybrand.link",
          key: "promo",
          url: "https://example.com",
          link_type: "referral",
          partner_id: partner_id
        })

      assert changeset.valid?
    end

    test "new short link without partner_id is valid" do
      changeset =
        Link.changeset(%Link{}, %{
          workspace_id: @workspace_id,
          domain: "mybrand.link",
          key: "short",
          url: "https://example.com",
          link_type: "short"
        })

      assert changeset.valid?
    end

    test "new short link with partner_id is invalid" do
      changeset =
        Link.changeset(%Link{}, %{
          workspace_id: @workspace_id,
          domain: "mybrand.link",
          key: "short",
          url: "https://example.com",
          link_type: "short",
          partner_id: Uniq.UUID.uuid7()
        })

      refute changeset.valid?
      assert errors_on(changeset)[:partner_id] == ["can only be set on referral links"]
    end

    test "existing referral link without partner_id is valid (backward compat)" do
      # Simulates a pre-existing referral link that was saved before partner_id
      # was required. The changeset checks data.id to determine new vs existing.
      existing_link = %Link{
        id: Uniq.UUID.uuid7(),
        link_type: "referral",
        partner_id: nil
      }

      changeset =
        Link.changeset(existing_link, %{
          workspace_id: @workspace_id,
          domain: "mybrand.link",
          key: "legacy",
          url: "https://example.com"
        })

      assert changeset.valid?
    end

    test "existing link being changed to referral type without partner_id is invalid" do
      # An existing short link is being updated to link_type "referral" but
      # no partner_id is provided. This is a type migration and must supply
      # a partner.
      existing_link = %Link{
        id: Uniq.UUID.uuid7(),
        link_type: "short",
        partner_id: nil
      }

      changeset =
        Link.changeset(existing_link, %{
          workspace_id: @workspace_id,
          domain: "mybrand.link",
          key: "migrated",
          url: "https://example.com",
          link_type: "referral"
        })

      refute changeset.valid?
      assert errors_on(changeset)[:partner_id] == ["is required for referral links"]
    end
  end

  # ── Context-level tests ────────────────────────────────────────────────────

  describe "Links.create_link/1 — partner DB validation" do
    test "creates referral link when partner is active" do
      {:ok, partner} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "alice",
          name: "Alice Nguyen"
        })

      assert {:ok, link} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "mybrand.link",
                 key: "ref-alice",
                 url: "https://example.com",
                 link_type: "referral",
                 partner_id: partner.id
               })

      assert link.link_type == "referral"
      assert link.partner_id == partner.id
    end

    test "rejects referral link when partner is disabled" do
      {:ok, partner} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "bob",
          name: "Bob Chen",
          status: "disabled"
        })

      assert {:error, changeset} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "mybrand.link",
                 key: "ref-bob",
                 url: "https://example.com",
                 link_type: "referral",
                 partner_id: partner.id
               })

      assert errors_on(changeset)[:partner_id] == [
               "must reference an active partner in the same workspace"
             ]
    end

    test "rejects referral link when partner is archived" do
      {:ok, partner} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "carol",
          name: "Carol Davis"
        })

      {:ok, _} = Partners.archive_partner(partner.id)

      assert {:error, changeset} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "mybrand.link",
                 key: "ref-carol",
                 url: "https://example.com",
                 link_type: "referral",
                 partner_id: partner.id
               })

      assert errors_on(changeset)[:partner_id] == [
               "must reference an active partner in the same workspace"
             ]
    end

    test "rejects referral link when partner belongs to a different workspace" do
      {:ok, partner} =
        Partners.create_partner(%{
          workspace_id: @other_workspace_id,
          key: "dave",
          name: "Dave Park"
        })

      assert {:error, changeset} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "mybrand.link",
                 key: "ref-dave",
                 url: "https://example.com",
                 link_type: "referral",
                 partner_id: partner.id
               })

      assert errors_on(changeset)[:partner_id] == [
               "must reference an active partner in the same workspace"
             ]
    end

    test "rejects referral link with nonexistent partner_id" do
      assert {:error, changeset} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "mybrand.link",
                 key: "ref-ghost",
                 url: "https://example.com",
                 link_type: "referral",
                 partner_id: Uniq.UUID.uuid7()
               })

      assert errors_on(changeset)[:partner_id] == [
               "must reference an active partner in the same workspace"
             ]
    end

    test "creates short link without a partner" do
      assert {:ok, link} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "mybrand.link",
                 key: "short-one",
                 url: "https://example.com",
                 link_type: "short"
               })

      assert link.link_type == "short"
      assert link.partner_id == nil
    end
  end
end
