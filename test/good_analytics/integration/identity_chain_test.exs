defmodule GoodAnalytics.Integration.IdentityChainTest do
  @moduledoc """
  OpenSpec 12.2: Identity resolution chain integration test.

  Tests: anonymous visit -> return with fingerprint -> identify with
  person_external_id -> verify single merged visitor with all signals.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors

  @workspace_id GoodAnalytics.default_workspace_id()

  describe "identity resolution chain" do
    test "anonymous -> fingerprint -> identify produces single visitor with all signals" do
      anon_id = "chain_anon_#{System.unique_integer([:positive])}"
      fp = "chain_fp_#{System.unique_integer([:positive])}"
      cust_id = "chain_cust_#{System.unique_integer([:positive])}"

      # Step 1: Anonymous visit with just anonymous_id
      {:ok, v1} = IdentityResolver.resolve(%{anonymous_id: anon_id}, workspace_id: @workspace_id)
      assert v1.status == "anonymous"

      # Step 2: Return visit with same anonymous_id + fingerprint
      {:ok, v2} =
        IdentityResolver.resolve(
          %{anonymous_id: anon_id, fingerprint: fp},
          workspace_id: @workspace_id
        )

      # Same visitor, now updated with fingerprint
      assert v2.id == v1.id
      assert fp in v2.fingerprints
      assert anon_id in v2.anonymous_ids

      # Step 3: Identify with person_external_id
      {:ok, v3} =
        IdentityResolver.identify(v2, %{
          person_external_id: cust_id,
          person_email: "chain@example.com",
          person_name: "Chain Test"
        })

      assert v3.id == v1.id
      assert v3.status == "identified"
      assert v3.person_external_id == cust_id

      # Verify single visitor through lookup
      found = Visitors.get_by_external_id(@workspace_id, cust_id)
      assert found.id == v1.id
      assert fp in found.fingerprints
    end

    test "two anonymous visitors merge when identified with same person_external_id" do
      cid = "merge_cust_#{System.unique_integer([:positive])}"

      # Create two independent visitors
      {:ok, v_a} =
        IdentityResolver.resolve(
          %{ga_id: "merge_ga_a_#{System.unique_integer([:positive])}"},
          workspace_id: @workspace_id
        )

      {:ok, v_b} =
        IdentityResolver.resolve(
          %{ga_id: "merge_ga_b_#{System.unique_integer([:positive])}"},
          workspace_id: @workspace_id
        )

      assert v_a.id != v_b.id

      # Record events on both
      record_event!(v_a, "pageview", %{url: "https://a.com"})
      record_event!(v_b, "pageview", %{url: "https://b.com"})

      # Identify A first
      {:ok, _} = IdentityResolver.identify(v_a, %{person_external_id: cid})

      # Identify B with same cid triggers merge
      {:ok, _result} = IdentityResolver.identify(v_b, %{person_external_id: cid})

      # Only one non-merged visitor with this cid
      found = Visitors.get_by_external_id(@workspace_id, cid)
      assert found != nil
      assert found.person_external_id == cid

      # Both events should belong to the primary
      timeline = Visitors.timeline(found.id)
      assert length(timeline) >= 2
    end
  end
end
