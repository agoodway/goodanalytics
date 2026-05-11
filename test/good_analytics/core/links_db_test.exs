defmodule GoodAnalytics.Core.LinksDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Links.Link

  @workspace_id GoodAnalytics.default_workspace_id()

  describe "create_link/1" do
    test "creates a link with valid attrs" do
      assert {:ok, %Link{} = link} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "test.link",
                 key: "abc",
                 url: "https://example.com"
               })

      assert link.domain == "test.link"
      assert link.key == "abc"
      assert link.url == "https://example.com"
      assert {:ok, _} = Ecto.UUID.cast(link.id)
    end

    test "defaults link_type to short and counters to zero" do
      {:ok, link} =
        Links.create_link(%{
          workspace_id: @workspace_id,
          domain: "test.link",
          key: "defaults",
          url: "https://example.com"
        })

      assert link.link_type == "short"
      assert link.total_clicks == 0
      assert link.unique_clicks == 0
      assert link.total_leads == 0
      assert link.total_sales == 0
      assert link.total_revenue_cents == 0
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = Links.create_link(%{})
      errors = errors_on(changeset)
      assert errors[:domain]
      assert errors[:key]
      assert errors[:url]
    end

    test "enforces unique domain+key constraint" do
      {:ok, _} =
        Links.create_link(%{
          workspace_id: @workspace_id,
          domain: "dup.link",
          key: "same",
          url: "https://example.com"
        })

      assert {:error, changeset} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "dup.link",
                 key: "same",
                 url: "https://other.com"
               })

      assert errors_on(changeset)[:domain] || errors_on(changeset)[:key]
    end

    test "allows the same key on different domains" do
      {:ok, link} =
        Links.create_link(%{
          workspace_id: @workspace_id,
          domain: "primary.link",
          key: "same-workspace-key",
          url: "https://example.com"
        })

      assert {:ok, other_link} =
               Links.create_link(%{
                 workspace_id: link.workspace_id,
                 domain: "custom.link",
                 key: link.key,
                 url: "https://other.com"
               })

      assert other_link.domain == "custom.link"
      assert other_link.key == link.key
    end
  end

  describe "get_link/1" do
    test "returns link by ID" do
      link = create_link!()
      assert found = Links.get_link(link.id)
      assert found.id == link.id
    end

    test "returns nil for nonexistent ID" do
      assert Links.get_link(Uniq.UUID.uuid7()) == nil
    end
  end

  describe "get_link_by_key/2" do
    test "returns link by domain and key" do
      link = create_link!(%{domain: "find.link", key: "findme"})
      assert found = Links.get_link_by_key("find.link", "findme")
      assert found.id == link.id
    end

    test "returns nil for nonexistent key" do
      assert Links.get_link_by_key("nope.link", "nope") == nil
    end

    test "excludes archived links" do
      link = create_link!(%{domain: "arch.link", key: "archived"})
      {:ok, _} = Links.archive_link(link.id)
      assert Links.get_link_by_key("arch.link", "archived") == nil
    end
  end

  describe "resolve_live_link/2" do
    test "resolves a live link by domain and key" do
      link = create_link!(%{domain: "legacy.link", key: "promo"})

      assert {:ok, found} = Links.resolve_live_link("legacy.link", "promo")
      assert found.id == link.id
    end

    test "returns expired for expired link" do
      past = DateTime.add(DateTime.utc_now(:second), -60, :second)

      create_link!(%{
        domain: "legacy.link",
        key: "expired",
        expires_at: past
      })

      assert {:error, :expired} = Links.resolve_live_link("legacy.link", "expired")
    end
  end

  describe "list_links/2" do
    test "returns links for workspace ordered by inserted_at DESC" do
      l1 = create_link!()
      l2 = create_link!()
      l3 = create_link!()

      result = Links.list_links(@workspace_id)
      ids = Enum.map(result, & &1.id)

      assert l3.id in ids
      assert l2.id in ids
      assert l1.id in ids
    end

    test "excludes archived links" do
      l1 = create_link!()
      l2 = create_link!()
      {:ok, _} = Links.archive_link(l1.id)

      result = Links.list_links(@workspace_id)
      ids = Enum.map(result, & &1.id)

      assert l2.id in ids
      refute l1.id in ids
    end

    test "respects limit and offset" do
      for _ <- 1..5, do: create_link!()

      result = Links.list_links(@workspace_id, limit: 2, offset: 1)
      assert length(result) == 2
    end

    test "returns empty list for workspace with no links" do
      assert Links.list_links(Uniq.UUID.uuid7()) == []
    end
  end

  describe "archive_link/1" do
    test "soft-deletes by setting archived_at" do
      link = create_link!()
      assert {:ok, archived} = Links.archive_link(link.id)
      assert archived.archived_at != nil
    end

    test "returns {:error, :not_found} for nonexistent ID" do
      assert {:error, :not_found} = Links.archive_link(Uniq.UUID.uuid7())
    end

    test "archived link frees domain+key for reuse" do
      link = create_link!(%{domain: "reuse.link", key: "reused"})
      {:ok, _} = Links.archive_link(link.id)

      assert {:ok, _} =
               Links.create_link(%{
                 workspace_id: @workspace_id,
                 domain: "reuse.link",
                 key: "reused",
                 url: "https://example.com/new"
               })
    end
  end

  describe "update_link/2" do
    test "updates mutable fields" do
      link = create_link!()

      assert {:ok, updated} =
               Links.update_link(link.id, %{url: "https://updated.com", utm_source: "test"})

      assert updated.url == "https://updated.com"
      assert updated.utm_source == "test"
    end

    test "returns {:error, :not_found} for nonexistent ID" do
      assert {:error, :not_found} = Links.update_link(Uniq.UUID.uuid7(), %{url: "https://x.com"})
    end
  end

  describe "link_stats/2" do
    test "returns counter map for existing link" do
      link = create_link!()
      assert {:ok, stats} = Links.link_stats(link.id)
      assert stats.total_clicks == 0
      assert stats.unique_clicks == 0
      assert stats.total_leads == 0
      assert stats.total_sales == 0
      assert stats.total_revenue_cents == 0
    end

    test "returns {:error, :not_found} for nonexistent link" do
      assert {:error, :not_found} = Links.link_stats(Uniq.UUID.uuid7())
    end
  end

  describe "increment_clicks/2" do
    test "increments total_clicks and unique_clicks when unique" do
      link = create_link!()
      Links.increment_clicks(link.id, true)
      updated = Links.get_link(link.id)
      assert updated.total_clicks == 1
      assert updated.unique_clicks == 1
    end

    test "increments only total_clicks when not unique" do
      link = create_link!()
      Links.increment_clicks(link.id, false)
      updated = Links.get_link(link.id)
      assert updated.total_clicks == 1
      assert updated.unique_clicks == 0
    end

    test "broadcasts PubSub event on global and workspace-scoped topics" do
      link = create_link!()
      Phoenix.PubSub.subscribe(GoodAnalytics.PubSub, "good_analytics:link_clicks")

      Phoenix.PubSub.subscribe(
        GoodAnalytics.PubSub,
        "good_analytics:link_clicks:#{link.workspace_id}"
      )

      Links.increment_clicks(link.id, true)

      assert_receive {:link_click, link_id, true}
      assert link_id == link.id

      assert_receive {:link_click, link_id, true}
      assert link_id == link.id
    end
  end

  describe "link_clicks/2" do
    test "returns click events for a link" do
      link = create_link!()
      visitor = create_visitor!()

      event =
        record_event!(visitor, "link_click", %{link_id: link.id, click_id: Uniq.UUID.uuid7()})

      clicks = Links.link_clicks(link.id)
      assert length(clicks) == 1
      assert hd(clicks).id == event.id
    end

    test "returns empty list when no clicks" do
      link = create_link!()
      assert Links.link_clicks(link.id) == []
    end
  end
end
