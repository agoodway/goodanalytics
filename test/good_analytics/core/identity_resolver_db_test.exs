defmodule GoodAnalytics.Core.IdentityResolverDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors

  @workspace_id GoodAnalytics.default_workspace_id()

  describe "resolve/2" do
    test "creates new visitor when no candidates found" do
      assert {:ok, visitor} =
               IdentityResolver.resolve(
                 %{ga_id: "new_ga_#{System.unique_integer([:positive])}"},
                 workspace_id: @workspace_id
               )

      assert visitor.id
      assert visitor.workspace_id == @workspace_id
    end

    test "updates existing visitor when single candidate matches" do
      ga_id = "resolve_update_#{System.unique_integer([:positive])}"
      {:ok, v1} = IdentityResolver.resolve(%{ga_id: ga_id}, workspace_id: @workspace_id)

      {:ok, v2} =
        IdentityResolver.resolve(
          %{ga_id: ga_id, fingerprint: "fp_new"},
          workspace_id: @workspace_id
        )

      assert v2.id == v1.id
      assert "fp_new" in v2.fingerprints
    end

    test "merges visitors when multiple candidates match with strong signal" do
      ga_id = "merge_ga_#{System.unique_integer([:positive])}"
      fp = "merge_fp_#{System.unique_integer([:positive])}"

      # Create two separate visitors
      {:ok, v1} = IdentityResolver.resolve(%{ga_id: ga_id}, workspace_id: @workspace_id)
      {:ok, v2} = IdentityResolver.resolve(%{fingerprint: fp}, workspace_id: @workspace_id)
      assert v1.id != v2.id

      # Resolve with both signals triggers merge
      {:ok, merged} =
        IdentityResolver.resolve(%{ga_id: ga_id, fingerprint: fp}, workspace_id: @workspace_id)

      # Primary should be the older one
      assert merged.ga_id == ga_id
      assert fp in merged.fingerprints

      # Duplicate should be marked merged
      dup = Visitors.get_visitor(v2.id)
      assert dup.status == "merged"
    end

    test "does not merge with fingerprint alone" do
      fp = "nomerge_fp_#{System.unique_integer([:positive])}"

      {:ok, v1} =
        IdentityResolver.resolve(
          %{fingerprint: fp, ga_id: "ga1_#{System.unique_integer([:positive])}"},
          workspace_id: @workspace_id
        )

      {:ok, v2} =
        IdentityResolver.resolve(%{anonymous_id: "anon_#{System.unique_integer([:positive])}"},
          workspace_id: @workspace_id
        )

      # Resolving with just the fingerprint won't merge with v2 since
      # fingerprint alone is a weak signal
      {:ok, v3} = IdentityResolver.resolve(%{fingerprint: fp}, workspace_id: @workspace_id)
      assert v3.id == v1.id

      # v2 should still exist independently
      assert Visitors.get_visitor(v2.id).status != "merged"
    end
  end

  describe "find_candidates/2" do
    test "finds by ga_id" do
      ga_id = "fc_ga_#{System.unique_integer([:positive])}"
      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: ga_id}, @workspace_id)

      candidates = IdentityResolver.find_candidates(%{ga_id: ga_id}, @workspace_id)
      assert length(candidates) == 1
      assert hd(candidates).id == visitor.id
    end

    test "finds by fingerprint" do
      fp = "fc_fp_#{System.unique_integer([:positive])}"
      {:ok, visitor} = IdentityResolver.create_visitor(%{fingerprint: fp}, @workspace_id)

      candidates = IdentityResolver.find_candidates(%{fingerprint: fp}, @workspace_id)
      assert length(candidates) == 1
      assert hd(candidates).id == visitor.id
    end

    test "finds by anonymous_id" do
      anon = "fc_anon_#{System.unique_integer([:positive])}"
      {:ok, visitor} = IdentityResolver.create_visitor(%{anonymous_id: anon}, @workspace_id)

      candidates = IdentityResolver.find_candidates(%{anonymous_id: anon}, @workspace_id)
      assert length(candidates) == 1
      assert hd(candidates).id == visitor.id
    end

    test "finds by person_external_id" do
      cid = "fc_cust_#{System.unique_integer([:positive])}"
      v = create_visitor!(%{person_external_id: cid, status: "identified"})

      candidates = IdentityResolver.find_candidates(%{person_external_id: cid}, @workspace_id)
      assert length(candidates) == 1
      assert hd(candidates).id == v.id
    end

    test "excludes merged visitors" do
      ga_id = "fc_merged_#{System.unique_integer([:positive])}"

      create_visitor!(%{
        ga_id: ga_id,
        status: "merged",
        merged_into_id: Uniq.UUID.uuid7()
      })

      candidates = IdentityResolver.find_candidates(%{ga_id: ga_id}, @workspace_id)
      assert candidates == []
    end

    test "returns empty list with no signals" do
      assert IdentityResolver.find_candidates(%{}, @workspace_id) == []
    end

    test "orders by first_seen_at ascending" do
      ga_id = "fc_order_#{System.unique_integer([:positive])}"
      fp = "fc_order_fp_#{System.unique_integer([:positive])}"

      v_old = create_visitor!(%{ga_id: ga_id, first_seen_at: ~U[2025-01-01 00:00:00Z]})
      _v_new = create_visitor!(%{fingerprints: [fp], first_seen_at: ~U[2026-01-01 00:00:00Z]})

      candidates =
        IdentityResolver.find_candidates(%{ga_id: ga_id, fingerprint: fp}, @workspace_id)

      assert length(candidates) == 2
      assert hd(candidates).id == v_old.id
    end
  end

  describe "create_visitor/2" do
    test "creates visitor with all signal fields" do
      signals = %{
        ga_id: "cv_ga",
        fingerprint: "cv_fp",
        anonymous_id: "cv_anon",
        click_id: Uniq.UUID.uuid7(),
        source: %{platform: "google", medium: "organic"},
        click_id_params: %{"gclid" => "abc123"}
      }

      assert {:ok, visitor} = IdentityResolver.create_visitor(signals, @workspace_id)
      assert visitor.ga_id == "cv_ga"
      assert "cv_fp" in visitor.fingerprints
      assert "cv_anon" in visitor.anonymous_ids
      assert signals.click_id in visitor.click_ids
      assert visitor.click_id_params == %{"gclid" => "abc123"}
    end

    test "sets first_seen_at and last_seen_at" do
      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: "cv_ts"}, @workspace_id)
      assert visitor.first_seen_at
      assert visitor.last_seen_at
    end

    test "initializes attribution_path from source" do
      source = %{platform: "google", medium: "organic"}
      {:ok, visitor} = IdentityResolver.create_visitor(%{source: source}, @workspace_id)
      assert length(visitor.attribution_path) == 1
    end
  end

  describe "update_visitor/2" do
    test "appends new fingerprint to array" do
      {:ok, visitor} = IdentityResolver.create_visitor(%{fingerprint: "fp_a"}, @workspace_id)
      {:ok, updated} = IdentityResolver.update_visitor(visitor, %{fingerprint: "fp_b"})
      assert "fp_a" in updated.fingerprints
      assert "fp_b" in updated.fingerprints
    end

    test "does not duplicate existing values in arrays" do
      {:ok, visitor} = IdentityResolver.create_visitor(%{fingerprint: "fp_dup"}, @workspace_id)
      {:ok, updated} = IdentityResolver.update_visitor(visitor, %{fingerprint: "fp_dup"})
      assert Enum.count(updated.fingerprints, &(&1 == "fp_dup")) == 1
    end

    test "updates last_seen_at" do
      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: "uv_ts"}, @workspace_id)
      Process.sleep(10)
      {:ok, updated} = IdentityResolver.update_visitor(visitor, %{})
      assert DateTime.compare(updated.last_seen_at, visitor.last_seen_at) in [:gt, :eq]
    end

    test "appends touchpoint to attribution_path" do
      source = %{platform: "google", medium: "organic"}
      {:ok, visitor} = IdentityResolver.create_visitor(%{source: source}, @workspace_id)

      new_source = %{platform: "meta", medium: "social"}
      {:ok, updated} = IdentityResolver.update_visitor(visitor, %{source: new_source})
      assert length(updated.attribution_path) == 2
    end
  end

  describe "merge_visitors/3" do
    test "consolidates signals from all visitors into primary" do
      {:ok, v1} =
        IdentityResolver.create_visitor(%{fingerprint: "m_fp1", ga_id: "m_ga1"}, @workspace_id)

      {:ok, v2} = IdentityResolver.create_visitor(%{fingerprint: "m_fp2"}, @workspace_id)
      {:ok, v3} = IdentityResolver.create_visitor(%{fingerprint: "m_fp3"}, @workspace_id)

      {:ok, merged} = IdentityResolver.merge_visitors(v1, [v2, v3], %{ga_id: "m_ga1"})
      assert "m_fp1" in merged.fingerprints
      assert "m_fp2" in merged.fingerprints
      assert "m_fp3" in merged.fingerprints
    end

    test "reassigns events from duplicates to primary" do
      {:ok, v1} = IdentityResolver.create_visitor(%{ga_id: "m_ev1"}, @workspace_id)
      {:ok, v2} = IdentityResolver.create_visitor(%{ga_id: "m_ev2"}, @workspace_id)

      event = record_event!(v2, "pageview", %{url: "https://test.com"})

      {:ok, _merged} = IdentityResolver.merge_visitors(v1, [v2], %{ga_id: "m_ev1"})

      # Event should now belong to primary. Use get_by_id/1 because the
      # composite (id, inserted_at) PK makes Repo.get/2 unsafe.
      updated_event = Events.get_by_id(event.id)

      assert updated_event.visitor_id == v1.id
    end

    test "marks duplicates as merged" do
      {:ok, v1} = IdentityResolver.create_visitor(%{ga_id: "m_mk1"}, @workspace_id)
      {:ok, v2} = IdentityResolver.create_visitor(%{ga_id: "m_mk2"}, @workspace_id)

      {:ok, _} = IdentityResolver.merge_visitors(v1, [v2], %{ga_id: "m_mk1"})

      dup = Visitors.get_visitor(v2.id)
      assert dup.status == "merged"
      assert dup.merged_into_id == v1.id
    end
  end

  describe "identify/2" do
    test "sets customer fields and status to identified" do
      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: "id_ga"}, @workspace_id)

      assert {:ok, identified} =
               IdentityResolver.identify(visitor, %{
                 person_external_id: "cust_123",
                 person_email: "test@example.com",
                 person_name: "Test User"
               })

      assert identified.person_external_id == "cust_123"
      assert identified.person_email == "test@example.com"
      assert identified.status == "identified"
      assert identified.identified_at
    end

    test "merges when person_external_id already exists on different visitor" do
      cid = "id_merge_#{System.unique_integer([:positive])}"

      # Create visitor A with the person_external_id
      {:ok, v_a} = IdentityResolver.create_visitor(%{ga_id: "id_a"}, @workspace_id)
      {:ok, _} = IdentityResolver.identify(v_a, %{person_external_id: cid})

      # Create visitor B (anonymous)
      {:ok, v_b} = IdentityResolver.create_visitor(%{ga_id: "id_b"}, @workspace_id)

      # Identify B with same cid triggers merge
      {:ok, result} = IdentityResolver.identify(v_b, %{person_external_id: cid})

      # One of them should be merged, the other should be the result
      assert result.person_external_id == cid
    end

    test "updates in place when no conflict" do
      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: "id_noconf"}, @workspace_id)

      {:ok, identified} =
        IdentityResolver.identify(visitor, %{person_external_id: "unique_cust"})

      assert identified.id == visitor.id
      assert identified.status == "identified"
    end

    test "merges when person_email already exists on different visitor" do
      email = "merge_#{System.unique_integer([:positive])}@example.com"

      # Visitor A holds the email.
      {:ok, v_a} = IdentityResolver.create_visitor(%{ga_id: "email_a"}, @workspace_id)
      {:ok, _} = IdentityResolver.identify(v_a, %{person_email: email})

      # Visitor B is anonymous; identifying with the same email triggers a merge.
      {:ok, v_b} = IdentityResolver.create_visitor(%{ga_id: "email_b"}, @workspace_id)

      {:ok, result} = IdentityResolver.identify(v_b, %{person_email: email})

      # One survives with the email; the other is marked merged.
      assert result.person_email == email
      assert result.status == "identified"

      # Older visitor wins as primary by first_seen_at.
      assert result.id == v_a.id

      assert Visitors.get_visitor(v_b.id).status == "merged"
    end

    test "applies remaining customer attrs to survivor after email merge" do
      email = "after_#{System.unique_integer([:positive])}@example.com"

      {:ok, v_a} = IdentityResolver.create_visitor(%{ga_id: "after_a"}, @workspace_id)
      {:ok, _} = IdentityResolver.identify(v_a, %{person_email: email})

      {:ok, v_b} = IdentityResolver.create_visitor(%{ga_id: "after_b"}, @workspace_id)

      {:ok, result} =
        IdentityResolver.identify(v_b, %{
          person_email: email,
          person_name: "Alex Doe",
          person_external_id: "ext_after_#{System.unique_integer([:positive])}"
        })

      # Survivor gets the full set of identify attrs, not just the merge signal.
      assert result.person_email == email
      assert result.person_name == "Alex Doe"
      assert String.starts_with?(result.person_external_id, "ext_after_")
    end

    test "single merge when both person_external_id and email collide on same visitor" do
      cid = "both_#{System.unique_integer([:positive])}"
      email = "both_#{System.unique_integer([:positive])}@example.com"

      # B already holds both identifiers.
      {:ok, v_b} = IdentityResolver.create_visitor(%{ga_id: "both_b"}, @workspace_id)

      {:ok, _} =
        IdentityResolver.identify(v_b, %{person_external_id: cid, person_email: email})

      {:ok, v_a} = IdentityResolver.create_visitor(%{ga_id: "both_a"}, @workspace_id)

      {:ok, result} =
        IdentityResolver.identify(v_a, %{person_external_id: cid, person_email: email})

      # external_id collides first → single merge into B; email check then sees survivor and skips.
      assert result.person_external_id == cid
      assert result.person_email == email
      assert Visitors.get_visitor(v_a.id).status == "merged"
    end

    test "no merge when no other visitor holds the email" do
      email = "fresh_#{System.unique_integer([:positive])}@example.com"

      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: "fresh_ga"}, @workspace_id)

      {:ok, identified} = IdentityResolver.identify(visitor, %{person_email: email})

      assert identified.id == visitor.id
      assert identified.person_email == email
    end

    test "repeat identify with same email on already-identified visitor is idempotent" do
      email = "idem_#{System.unique_integer([:positive])}@example.com"

      {:ok, visitor} = IdentityResolver.create_visitor(%{ga_id: "idem_ga"}, @workspace_id)
      {:ok, first} = IdentityResolver.identify(visitor, %{person_email: email})

      {:ok, second} = IdentityResolver.identify(first, %{person_email: email})

      # Same row, no merge fired.
      assert second.id == visitor.id
      assert second.person_email == email
      assert Visitors.get_visitor(visitor.id).status == "identified"
    end
  end
end
