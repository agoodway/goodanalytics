defmodule GoodAnalytics.Core.IdentityMergePersistenceTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Core.Visitors.Visitor

  for key <- [:person_email, :person_external_id] do
    @identity_key key
    test "#{key} collision preserves identifiers after a database reload" do
      workspace_id = Uniq.UUID.uuid7()
      identity = %{@identity_key => "identity-#{Uniq.UUID.uuid7()}@example.test"}
      primary = visitor(workspace_id, %{anonymous_ids: ["first-cookie"]})
      {:ok, primary} = IdentityResolver.identify(primary, identity)
      click_id = Uniq.UUID.uuid7()

      duplicate =
        visitor(workspace_id, %{
          anonymous_ids: ["returning-cookie"],
          fingerprints: ["device-fingerprint"],
          click_ids: [click_id]
        })

      {:ok, merged} = IdentityResolver.identify(duplicate, identity)
      assert merged.id == primary.id
      persisted = Visitors.get_visitor(primary.id)
      assert "returning-cookie" in persisted.anonymous_ids
      assert "device-fingerprint" in persisted.fingerprints
      assert click_id in persisted.click_ids

      for signal <- [
            %{anonymous_id: "returning-cookie"},
            %{fingerprint: "device-fingerprint"},
            %{click_id: click_id},
            %{anonymous_id: "returning-cookie"}
          ] do
        assert {:ok, %{id: id}} = IdentityResolver.resolve(signal, workspace_id: workspace_id)
        assert id == primary.id
      end

      assert Visitors.get_visitor(duplicate.id).status == "merged"

      assert {:ok, other} =
               IdentityResolver.resolve(%{anonymous_id: "returning-cookie"},
                 workspace_id: Uniq.UUID.uuid7()
               )

      refute other.id == primary.id
    end
  end

  test "persists merged attribution and geo, including fields absent from incoming signals" do
    workspace_id = Uniq.UUID.uuid7()
    first_partner = Uniq.UUID.uuid7()
    last_partner = Uniq.UUID.uuid7()
    first_link = Uniq.UUID.uuid7()
    last_link = Uniq.UUID.uuid7()
    first_click = Uniq.UUID.uuid7()
    last_click = Uniq.UUID.uuid7()
    older = DateTime.add(DateTime.utc_now(), -120, :second)
    newer = DateTime.add(older, 60, :second)
    touch1 = %{"timestamp" => DateTime.to_iso8601(older), "platform" => "first"}
    touch2 = %{"timestamp" => DateTime.to_iso8601(newer), "platform" => "second"}

    primary =
      visitor(workspace_id, %{
        first_seen_at: older,
        last_seen_at: older,
        click_id_params: %{"first" => "a"},
        attribution_path: [touch1]
      })

    duplicate =
      visitor(workspace_id, %{
        first_seen_at: newer,
        last_seen_at: newer,
        click_id_params: %{"second" => "b"},
        attribution_path: [touch2],
        geo: %{"country_code" => "GB"},
        first_partner_id: first_partner,
        first_referral_link_id: first_link,
        first_referral_click_id: first_click,
        last_partner_id: last_partner,
        last_referral_link_id: last_link,
        last_referral_click_id: last_click
      })

    assert {:ok, _} = IdentityResolver.merge_visitors(primary, [duplicate], %{})
    persisted = Visitors.get_visitor(primary.id)
    assert persisted.click_id_params == %{"first" => "a", "second" => "b"}
    assert persisted.attribution_path == [touch1, touch2]
    assert persisted.geo == %{"country_code" => "GB"}
    assert persisted.first_partner_id == first_partner
    assert persisted.first_referral_link_id == first_link
    assert persisted.first_referral_click_id == first_click
    assert persisted.last_partner_id == last_partner
    assert persisted.last_referral_link_id == last_link
    assert persisted.last_referral_click_id == last_click
  end

  test "merges current persisted signals and preserves geo enriched after candidate loading" do
    workspace_id = Uniq.UUID.uuid7()
    primary = visitor(workspace_id, %{anonymous_ids: ["first-cookie"]})
    duplicate = visitor(workspace_id, %{geo: %{"country_code" => "GB"}})

    assert {:ok, 1} = Visitors.maybe_set_geo(primary.id, %{"country_code" => "US"})
    assert {:ok, _} = IdentityResolver.update_visitor(primary, %{anonymous_id: "later-cookie"})
    assert {:ok, _} = IdentityResolver.update_visitor(duplicate, %{fingerprint: "later-device"})

    assert {:ok, merged} = IdentityResolver.merge_visitors(primary, [duplicate], %{})
    persisted = Visitors.get_visitor(primary.id)
    assert persisted.geo == %{"country_code" => "US"}
    assert merged.geo == persisted.geo
    assert "later-cookie" in persisted.anonymous_ids
    assert "later-device" in persisted.fingerprints
  end

  test "rejects candidates already merged by another request without redirecting their merge" do
    workspace_id = Uniq.UUID.uuid7()
    primary = visitor(workspace_id, %{})
    duplicate = visitor(workspace_id, %{})
    other = visitor(workspace_id, %{})
    assert {:ok, _} = IdentityResolver.merge_visitors(other, [duplicate], %{})

    assert {:error, :stale_merge_candidates} =
             IdentityResolver.merge_visitors(primary, [duplicate], %{})

    assert Visitors.get_visitor(duplicate.id).merged_into_id == other.id
  end

  test "rejects candidates from another workspace" do
    primary = visitor(Uniq.UUID.uuid7(), %{})
    duplicate = visitor(Uniq.UUID.uuid7(), %{anonymous_ids: ["other-workspace"]})

    assert {:error, :stale_merge_candidates} =
             IdentityResolver.merge_visitors(primary, [duplicate], %{})

    assert Visitors.get_visitor(duplicate.id).status != "merged"
    assert Visitors.get_visitor(primary.id).anonymous_ids == []
  end

  defp visitor(workspace_id, attrs) do
    now = DateTime.utc_now()

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(
      Map.merge(%{workspace_id: workspace_id, first_seen_at: now, last_seen_at: now}, attrs)
    )
    |> TestRepo.insert!(prefix: GoodAnalytics.schema_name())
  end
end
