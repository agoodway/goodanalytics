defmodule GoodAnalytics.Core.IdentityResolverTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.IdentityResolver

  describe "merge_allowed?/2" do
    test "allows merge with strong signal (person_external_id)" do
      signals = %{person_external_id: "cust_123"}
      assert IdentityResolver.merge_allowed?(signals, [])
    end

    test "allows merge with strong signal (ga_id)" do
      signals = %{ga_id: "ga_abc"}
      assert IdentityResolver.merge_allowed?(signals, [])
    end

    test "allows merge with strong signal (person_email)" do
      signals = %{person_email: "test@example.com"}
      assert IdentityResolver.merge_allowed?(signals, [])
    end

    test "allows merge with two weak signals" do
      signals = %{fingerprint: "fp_abc", anonymous_id: "anon_123"}
      assert IdentityResolver.merge_allowed?(signals, [])
    end

    test "denies merge with fingerprint alone" do
      signals = %{fingerprint: "fp_abc"}
      refute IdentityResolver.merge_allowed?(signals, [])
    end

    test "denies merge with anonymous_id alone" do
      signals = %{anonymous_id: "anon_123"}
      refute IdentityResolver.merge_allowed?(signals, [])
    end

    test "denies merge with no signals" do
      refute IdentityResolver.merge_allowed?(%{}, [])
    end

    test "allows merge with one strong + one weak" do
      signals = %{ga_id: "ga_abc", fingerprint: "fp_abc"}
      assert IdentityResolver.merge_allowed?(signals, [])
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(IdentityResolver)
      assert function_exported?(IdentityResolver, :resolve, 2)
      assert function_exported?(IdentityResolver, :find_candidates, 2)
      assert function_exported?(IdentityResolver, :merge_allowed?, 2)
      assert function_exported?(IdentityResolver, :create_visitor, 2)
      assert function_exported?(IdentityResolver, :update_visitor, 2)
      assert function_exported?(IdentityResolver, :merge_visitors, 3)
      assert function_exported?(IdentityResolver, :identify, 2)
    end
  end
end
