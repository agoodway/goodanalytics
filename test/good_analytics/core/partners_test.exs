defmodule GoodAnalytics.Core.PartnersTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Partners
  alias GoodAnalytics.Core.Partners.Partner

  @workspace_id GoodAnalytics.default_workspace_id()
  @other_workspace_id "11111111-1111-1111-1111-111111111111"

  defp create_partner!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          key: "partner#{System.unique_integer([:positive])}",
          name: "Test Partner"
        },
        attrs
      )

    {:ok, partner} = Partners.create_partner(attrs)
    partner
  end

  describe "create_partner/1" do
    test "creates a partner with valid attrs" do
      assert {:ok, %Partner{} = partner} =
               Partners.create_partner(%{
                 workspace_id: @workspace_id,
                 key: "acme-corp",
                 name: "Acme Corp"
               })

      assert partner.key == "acme-corp"
      assert partner.name == "Acme Corp"
      assert partner.workspace_id == @workspace_id
      assert partner.status == "active"
      assert is_nil(partner.archived_at)
      assert {:ok, _} = Ecto.UUID.cast(partner.id)
    end

    test "sets default status to active" do
      {:ok, partner} =
        Partners.create_partner(%{workspace_id: @workspace_id, key: "defaults", name: "Defaults"})

      assert partner.status == "active"
    end

    test "creates partner with explicit status" do
      {:ok, partner} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "disabled-partner",
          name: "Disabled",
          status: "disabled"
        })

      assert partner.status == "disabled"
    end

    test "creates partner with external_id and metadata" do
      {:ok, partner} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "ext-partner",
          name: "External",
          external_id: "ext_123",
          metadata: %{"tier" => "gold"}
        })

      assert partner.external_id == "ext_123"
      assert partner.metadata == %{"tier" => "gold"}
    end

    test "rejects duplicate key in the same workspace" do
      {:ok, _} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "dup-key",
          name: "First"
        })

      assert {:error, changeset} =
               Partners.create_partner(%{
                 workspace_id: @workspace_id,
                 key: "dup-key",
                 name: "Second"
               })

      errors = errors_on(changeset)
      assert errors[:workspace_id] || errors[:key]
    end

    test "allows the same key in a different workspace" do
      {:ok, _} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "shared-key",
          name: "First Workspace Partner"
        })

      assert {:ok, partner} =
               Partners.create_partner(%{
                 workspace_id: @other_workspace_id,
                 key: "shared-key",
                 name: "Second Workspace Partner"
               })

      assert partner.workspace_id == @other_workspace_id
    end

    test "allows reuse of a key after the original partner is archived" do
      {:ok, original} =
        Partners.create_partner(%{
          workspace_id: @workspace_id,
          key: "reusable-key",
          name: "Original"
        })

      {:ok, _} = Partners.archive_partner(original.id)

      assert {:ok, new_partner} =
               Partners.create_partner(%{
                 workspace_id: @workspace_id,
                 key: "reusable-key",
                 name: "New"
               })

      assert new_partner.key == "reusable-key"
    end

    test "rejects missing required field: key" do
      assert {:error, changeset} =
               Partners.create_partner(%{workspace_id: @workspace_id, name: "No Key"})

      assert errors_on(changeset)[:key]
    end

    test "rejects missing required field: name" do
      assert {:error, changeset} =
               Partners.create_partner(%{workspace_id: @workspace_id, key: "no-name"})

      assert errors_on(changeset)[:name]
    end

    test "rejects missing required field: workspace_id" do
      assert {:error, changeset} =
               Partners.create_partner(%{key: "no-workspace", name: "No Workspace"})

      assert errors_on(changeset)[:workspace_id]
    end

    test "rejects key with invalid format (spaces)" do
      assert {:error, changeset} =
               Partners.create_partner(%{
                 workspace_id: @workspace_id,
                 key: "invalid key",
                 name: "Bad Key"
               })

      assert errors_on(changeset)[:key]
    end

    test "rejects key with invalid format (special characters)" do
      assert {:error, changeset} =
               Partners.create_partner(%{
                 workspace_id: @workspace_id,
                 key: "invalid!@#",
                 name: "Bad Key"
               })

      assert errors_on(changeset)[:key]
    end

    test "accepts key with letters, numbers, hyphens, and underscores" do
      assert {:ok, partner} =
               Partners.create_partner(%{
                 workspace_id: @workspace_id,
                 key: "valid_Key-123",
                 name: "Valid Key"
               })

      assert partner.key == "valid_Key-123"
    end
  end

  describe "get_partner/1" do
    test "returns a partner by ID" do
      partner = create_partner!()
      assert found = Partners.get_partner(partner.id)
      assert found.id == partner.id
    end

    test "returns nil for a nonexistent ID" do
      assert Partners.get_partner(Uniq.UUID.uuid7()) == nil
    end
  end

  describe "get_partner/2 (workspace-scoped)" do
    test "returns a partner by workspace_id and ID" do
      partner = create_partner!()
      assert found = Partners.get_partner(@workspace_id, partner.id)
      assert found.id == partner.id
    end

    test "returns nil when ID belongs to a different workspace" do
      partner = create_partner!()
      assert Partners.get_partner(@other_workspace_id, partner.id) == nil
    end

    test "returns nil for a nonexistent ID" do
      assert Partners.get_partner(@workspace_id, Uniq.UUID.uuid7()) == nil
    end
  end

  describe "get_active_partner/2" do
    test "returns an active partner by workspace_id and ID" do
      partner = create_partner!(%{status: "active"})
      assert found = Partners.get_active_partner(@workspace_id, partner.id)
      assert found.id == partner.id
    end

    test "returns nil for a disabled partner" do
      partner = create_partner!(%{status: "disabled"})
      assert Partners.get_active_partner(@workspace_id, partner.id) == nil
    end

    test "returns nil for an archived partner" do
      partner = create_partner!()
      {:ok, _} = Partners.archive_partner(partner.id)
      assert Partners.get_active_partner(@workspace_id, partner.id) == nil
    end

    test "returns nil for a partner in a different workspace" do
      partner = create_partner!(%{status: "active"})
      assert Partners.get_active_partner(@other_workspace_id, partner.id) == nil
    end
  end

  describe "get_active_partner_by_key/2" do
    test "returns an active partner matching the given key" do
      partner = create_partner!(%{key: "find-by-key"})
      assert found = Partners.get_active_partner_by_key(@workspace_id, "find-by-key")
      assert found.id == partner.id
    end

    test "returns nil when no partner matches the key" do
      assert Partners.get_active_partner_by_key(@workspace_id, "no-such-key") == nil
    end

    test "returns nil for a disabled partner matching the key" do
      create_partner!(%{key: "disabled-key", status: "disabled"})
      assert Partners.get_active_partner_by_key(@workspace_id, "disabled-key") == nil
    end

    test "returns nil for an archived partner matching the key" do
      partner = create_partner!(%{key: "archived-key"})
      {:ok, _} = Partners.archive_partner(partner.id)
      assert Partners.get_active_partner_by_key(@workspace_id, "archived-key") == nil
    end
  end

  describe "list_partners/2" do
    test "returns partners scoped to the given workspace" do
      p1 = create_partner!(%{workspace_id: @workspace_id})
      p2 = create_partner!(%{workspace_id: @workspace_id})
      _other = create_partner!(%{workspace_id: @other_workspace_id})

      result = Partners.list_partners(@workspace_id)
      ids = Enum.map(result, & &1.id)

      assert p1.id in ids
      assert p2.id in ids
      refute Enum.any?(result, &(&1.workspace_id == @other_workspace_id))
    end

    test "excludes archived partners by default" do
      active = create_partner!()
      archived = create_partner!()
      {:ok, _} = Partners.archive_partner(archived.id)

      result = Partners.list_partners(@workspace_id)
      ids = Enum.map(result, & &1.id)

      assert active.id in ids
      refute archived.id in ids
    end

    test "includes archived partners when include_archived: true" do
      active = create_partner!()
      archived = create_partner!()
      {:ok, _} = Partners.archive_partner(archived.id)

      result = Partners.list_partners(@workspace_id, include_archived: true)
      ids = Enum.map(result, & &1.id)

      assert active.id in ids
      assert archived.id in ids
    end

    test "respects limit and offset" do
      for _ <- 1..5, do: create_partner!()

      result = Partners.list_partners(@workspace_id, limit: 2, offset: 1)
      assert length(result) == 2
    end

    test "returns empty list for a workspace with no partners" do
      assert Partners.list_partners(Uniq.UUID.uuid7()) == []
    end
  end

  describe "update_partner/2" do
    test "updates partner fields" do
      partner = create_partner!()

      assert {:ok, updated} =
               Partners.update_partner(partner.id, %{name: "Updated Name", status: "disabled"})

      assert updated.name == "Updated Name"
      assert updated.status == "disabled"
    end

    test "updates metadata and external_id" do
      partner = create_partner!()

      assert {:ok, updated} =
               Partners.update_partner(partner.id, %{
                 external_id: "ext_abc",
                 metadata: %{"ref" => "promo"}
               })

      assert updated.external_id == "ext_abc"
      assert updated.metadata == %{"ref" => "promo"}
    end

    test "returns {:error, :not_found} for a nonexistent ID" do
      assert {:error, :not_found} = Partners.update_partner(Uniq.UUID.uuid7(), %{name: "Ghost"})
    end

    test "returns changeset error for invalid status" do
      partner = create_partner!()

      assert {:error, changeset} = Partners.update_partner(partner.id, %{status: "banned"})
      assert errors_on(changeset)[:status]
    end
  end

  describe "update_partner/3 (workspace-scoped)" do
    test "updates partner scoped to the correct workspace" do
      partner = create_partner!()

      assert {:ok, updated} =
               Partners.update_partner(@workspace_id, partner.id, %{name: "Scoped Update"})

      assert updated.name == "Scoped Update"
    end

    test "returns {:error, :not_found} when ID belongs to a different workspace" do
      partner = create_partner!()

      assert {:error, :not_found} =
               Partners.update_partner(@other_workspace_id, partner.id, %{name: "Hijack"})
    end

    test "returns {:error, :not_found} for a nonexistent ID" do
      assert {:error, :not_found} =
               Partners.update_partner(@workspace_id, Uniq.UUID.uuid7(), %{name: "Ghost"})
    end
  end

  describe "archive_partner/1" do
    test "sets status to archived and records archived_at timestamp" do
      partner = create_partner!()
      assert {:ok, archived} = Partners.archive_partner(partner.id)
      assert archived.status == "archived"
      assert %DateTime{} = archived.archived_at
    end

    test "returns {:error, :not_found} for a nonexistent ID" do
      assert {:error, :not_found} = Partners.archive_partner(Uniq.UUID.uuid7())
    end

    test "archived partner is excluded from get_active_partner_by_key" do
      partner = create_partner!(%{key: "soon-archived"})
      {:ok, _} = Partners.archive_partner(partner.id)
      assert Partners.get_active_partner_by_key(@workspace_id, "soon-archived") == nil
    end
  end

  describe "archive_partner/2 (workspace-scoped)" do
    test "archives a partner scoped to the correct workspace" do
      partner = create_partner!()
      assert {:ok, archived} = Partners.archive_partner(@workspace_id, partner.id)
      assert archived.status == "archived"
      assert %DateTime{} = archived.archived_at
    end

    test "returns {:error, :not_found} when ID belongs to a different workspace" do
      partner = create_partner!()

      assert {:error, :not_found} =
               Partners.archive_partner(@other_workspace_id, partner.id)
    end

    test "returns {:error, :not_found} for a nonexistent ID" do
      assert {:error, :not_found} =
               Partners.archive_partner(@workspace_id, Uniq.UUID.uuid7())
    end
  end
end
