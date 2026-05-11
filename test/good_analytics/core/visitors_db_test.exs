defmodule GoodAnalytics.Core.VisitorsDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Visitors

  @workspace_id GoodAnalytics.default_workspace_id()

  describe "get_visitor/1" do
    test "returns visitor by ID" do
      visitor = create_visitor!()
      assert found = Visitors.get_visitor(visitor.id)
      assert found.id == visitor.id
    end

    test "returns nil for nonexistent ID" do
      assert Visitors.get_visitor(Uniq.UUID.uuid7()) == nil
    end
  end

  describe "get_by_external_id/2" do
    test "returns visitor by workspace_id and person_external_id" do
      visitor = create_visitor!(%{person_external_id: "cust_1", status: "identified"})
      assert found = Visitors.get_by_external_id(@workspace_id, "cust_1")
      assert found.id == visitor.id
    end

    test "excludes merged visitors" do
      create_visitor!(%{
        person_external_id: "cust_merged",
        status: "merged",
        merged_into_id: Uniq.UUID.uuid7()
      })

      assert Visitors.get_by_external_id(@workspace_id, "cust_merged") == nil
    end

    test "returns nil when no match" do
      assert Visitors.get_by_external_id(@workspace_id, "nonexistent") == nil
    end
  end

  describe "timeline/1" do
    test "returns events ordered by inserted_at DESC" do
      visitor = create_visitor!()
      e1 = record_event!(visitor, "pageview", %{url: "https://a.com"})
      _e2 = record_event!(visitor, "pageview", %{url: "https://b.com"})
      e3 = record_event!(visitor, "lead")

      events = Visitors.timeline(visitor.id)
      ids = Enum.map(events, & &1.id)

      assert length(ids) == 3
      assert List.first(ids) == e3.id
      assert List.last(ids) == e1.id
    end

    test "returns empty list for visitor with no events" do
      visitor = create_visitor!()
      assert Visitors.timeline(visitor.id) == []
    end
  end

  describe "attribution/1" do
    test "returns attribution_path array" do
      path = [%{"platform" => "google", "medium" => "organic"}]
      visitor = create_visitor!(%{attribution_path: path})
      assert Visitors.attribution(visitor.id) == path
    end

    test "returns empty list for nonexistent visitor" do
      assert Visitors.attribution(Uniq.UUID.uuid7()) == []
    end
  end

  describe "update_status/2" do
    test "updates lifecycle status" do
      visitor = create_visitor!()
      assert {:ok, updated} = Visitors.update_status(visitor.id, "identified")
      assert updated.status == "identified"
    end

    test "rejects invalid status" do
      visitor = create_visitor!()
      assert {:error, changeset} = Visitors.update_status(visitor.id, "bogus")
      assert errors_on(changeset)[:status]
    end

    test "returns {:error, :not_found} for nonexistent visitor" do
      assert {:error, :not_found} = Visitors.update_status(Uniq.UUID.uuid7(), "identified")
    end
  end

  describe "update_attribution/2" do
    test "updates attribution fields" do
      visitor = create_visitor!()
      path = [%{"platform" => "meta", "medium" => "social"}]

      assert {:ok, updated} =
               Visitors.update_attribution(visitor.id, %{
                 last_source: %{"platform" => "meta"},
                 attribution_path: path
               })

      assert updated.last_source == %{"platform" => "meta"}
      assert updated.attribution_path == path
    end

    test "returns {:error, :not_found} for nonexistent visitor" do
      assert {:error, :not_found} = Visitors.update_attribution(Uniq.UUID.uuid7(), %{})
    end
  end

  describe "forget/1" do
    test "deletes all events and clears PII" do
      visitor =
        create_visitor!(%{
          person_external_id: "gdpr_user",
          person_email: "user@example.com",
          person_name: "Test User",
          fingerprints: ["fp_1"],
          anonymous_ids: ["anon_1"],
          ga_id: "ga_123",
          status: "customer"
        })

      record_event!(visitor, "pageview", %{url: "https://a.com"})
      record_event!(visitor, "lead")

      assert :ok = Visitors.forget(visitor.id)

      # Events deleted
      assert Visitors.timeline(visitor.id) == []

      # PII cleared
      cleared = Visitors.get_visitor(visitor.id)
      assert cleared.fingerprints == []
      assert cleared.anonymous_ids == []
      assert cleared.click_ids == []
      assert cleared.ga_id == nil
      assert cleared.person_external_id == nil
      assert cleared.person_email == nil
      assert cleared.person_name == nil
      assert cleared.person_metadata == %{}
      assert cleared.attribution_path == []
      assert cleared.status == "anonymous"
    end

    test "returns {:error, :not_found} for nonexistent visitor" do
      assert {:error, :not_found} = Visitors.forget(Uniq.UUID.uuid7())
    end
  end
end
