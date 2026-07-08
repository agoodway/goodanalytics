defmodule GoodAnalytics.Integration.ReferralEventAttributionTest do
  @moduledoc """
  Integration tests for the full referral attribution pipeline:
  redirect sets cookie token → beacon event reads _ga_ref payload token →
  event is stored with partner attribution fields.

  Also covers the secret vs publishable key distinction in the API event controller.
  """

  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Api.Router
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Partners
  alias GoodAnalytics.Core.Tracking.BeaconController
  alias GoodAnalytics.Core.Tracking.ReferralCookie

  import Ecto.Query
  import Plug.Test

  @workspace_id GoodAnalytics.default_workspace_id()

  # ---------------------------------------------------------------------------
  # Shared helpers
  # ---------------------------------------------------------------------------

  defp build_event_conn do
    conn(:post, "/ga/t/event")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("user-agent", "ReferralAttributionTest/1.0")
    |> Plug.Conn.assign(:ga_source, nil)
    |> Plug.Conn.put_private(:phoenix_format, "json")
  end

  defp create_partner!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          key: "partner-#{System.unique_integer([:positive])}",
          name: "Test Partner #{System.unique_integer([:positive])}",
          status: "active"
        },
        attrs
      )

    {:ok, partner} = Partners.create_partner(attrs)
    partner
  end

  defp create_referral_link!(partner_id, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          domain: "test.link",
          key: "k#{System.unique_integer([:positive])}",
          url: "https://example.com/referral",
          link_type: "referral",
          partner_id: partner_id
        },
        attrs
      )

    {:ok, link} = GoodAnalytics.create_link(attrs)
    link
  end

  defp sign_ref_token(partner, link) do
    click_id = Uniq.UUID.uuid7()

    token =
      ReferralCookie.sign(%{
        partner_id: partner.id,
        referral_link_id: link.id,
        referral_click_id: click_id,
        workspace_id: @workspace_id
      })

    {token, click_id}
  end

  defp latest_event do
    GoodAnalytics.Repo.repo().one!(
      from(e in Event, order_by: [desc: e.inserted_at], limit: 1),
      prefix: "good_analytics"
    )
  end

  # ---------------------------------------------------------------------------
  # Beacon event with _ga_ref payload token
  # ---------------------------------------------------------------------------

  describe "beacon event with _ga_ref payload token" do
    test "records event with partner attribution from the signed token" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)
      {token, click_id} = sign_ref_token(partner, link)

      anon_id = "anon-#{System.unique_integer([:positive])}"

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "anonymous_id" => anon_id,
          "_ga_ref" => token,
          "url" => "https://example.com/landing"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.partner_id == partner.id
      assert event.referral_link_id == link.id
      assert event.referral_click_id == click_id
    end
  end

  # ---------------------------------------------------------------------------
  # Beacon event with invalid _ga_ref token
  # ---------------------------------------------------------------------------

  describe "beacon event with invalid _ga_ref token" do
    test "records event normally but with nil partner fields" do
      anon_id = "anon-#{System.unique_integer([:positive])}"

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "anonymous_id" => anon_id,
          "_ga_ref" => "this-is-not-a-valid-token",
          "url" => "https://example.com/page"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert is_nil(event.partner_id)
      assert is_nil(event.referral_link_id)
      assert is_nil(event.referral_click_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Beacon event uses visitor attribution fallback
  # ---------------------------------------------------------------------------

  describe "beacon event uses visitor attribution fallback" do
    test "inherits last_partner_id from visitor when no _ga_ref present" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)
      click_id = Uniq.UUID.uuid7()

      # Create visitor with pre-existing partner attribution
      visitor =
        create_visitor!(%{
          last_partner_id: partner.id,
          last_referral_link_id: link.id,
          last_referral_click_id: click_id
        })

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "anonymous_id" => "anon-#{visitor.id}",
          "url" => "https://example.com/return-visit"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      # The identity resolver may or may not match on anonymous_id to the existing visitor,
      # so we directly pass the visitor's ga_id if available, or check latest event attribution.
      # The beacon will create/resolve a visitor from anonymous_id; if a new visitor is created
      # it won't have the partner set. Instead, we test via the visitor directly by looking up
      # the identity-resolved visitor for that anonymous_id.
      #
      # Re-run with ga_id set on visitor so IdentityResolver matches it.
      ga_id = "ga-#{System.unique_integer([:positive])}"

      visitor_with_ga =
        create_visitor!(%{
          ga_id: ga_id,
          last_partner_id: partner.id,
          last_referral_link_id: link.id,
          last_referral_click_id: click_id
        })

      conn2 =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "ga_id" => ga_id,
          "url" => "https://example.com/landing-again"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn2.resp_body)

      event = latest_event()
      assert event.visitor_id == visitor_with_ga.id
      assert event.partner_id == partner.id
      assert event.referral_link_id == link.id
      assert event.referral_click_id == click_id
    end
  end

  # ---------------------------------------------------------------------------
  # Beacon event with no referral context
  # ---------------------------------------------------------------------------

  describe "beacon event with no referral context" do
    test "records event with nil partner fields when visitor has no attribution and no token" do
      anon_id = "anon-bare-#{System.unique_integer([:positive])}"

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "anonymous_id" => anon_id,
          "url" => "https://example.com/organic"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert is_nil(event.partner_id)
      assert is_nil(event.referral_link_id)
      assert is_nil(event.referral_click_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Secret-key vs publishable-key event API with explicit partner_id
  # ---------------------------------------------------------------------------

  describe "EventController partner_id attribution gate" do
    setup do
      Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
        {:ok, %{workspace_id: @workspace_id}}
      end)

      on_exit(fn -> Application.delete_env(:good_analytics, :api_authenticate) end)
      :ok
    end

    test "secret key auth: explicit partner_id is persisted on the event" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)
      click_id = Uniq.UUID.uuid7()
      visitor = create_visitor!()

      Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
        {:ok, %{workspace_id: @workspace_id, key_type: "secret"}}
      end)

      conn =
        Plug.Test.conn(
          :post,
          "/events",
          Jason.encode!(%{
            visitor_id: visitor.id,
            event_type: "sale",
            amount_cents: 9900,
            currency: "USD",
            partner_id: partner.id,
            referral_link_id: link.id,
            referral_click_id: click_id
          })
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer secret-key-token")
        |> Router.call(Router.init([]))

      assert conn.status == 201

      event = latest_event()
      assert event.partner_id == partner.id
      assert event.referral_link_id == link.id
      assert event.referral_click_id == click_id
    end

    test "publishable key auth: explicit partner_id is NOT persisted on the event" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)
      click_id = Uniq.UUID.uuid7()
      visitor = create_visitor!()

      Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
        {:ok, %{workspace_id: @workspace_id, key_type: "publishable"}}
      end)

      conn =
        Plug.Test.conn(
          :post,
          "/events",
          Jason.encode!(%{
            visitor_id: visitor.id,
            event_type: "lead",
            partner_id: partner.id,
            referral_link_id: link.id,
            referral_click_id: click_id
          })
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("authorization", "Bearer publishable-key-token")
        |> Router.call(Router.init([]))

      assert conn.status == 201

      event = latest_event()
      assert is_nil(event.partner_id)
      assert is_nil(event.referral_link_id)
      assert is_nil(event.referral_click_id)
    end
  end
end
