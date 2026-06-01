defmodule GoodAnalytics.Integration.ReferralClickTest do
  @moduledoc """
  Integration tests for the client-side click tracking flow (`POST /ga/t/click`)
  with referral partner attribution.

  Covers referral cookie setting, partner attribution on events, visitor
  partner fields, inactive/disabled partner handling, non-referral links,
  and multi-touch first-touch preservation.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Partners
  alias GoodAnalytics.Core.Tracking.BeaconController
  alias GoodAnalytics.Core.Visitors

  import Plug.Test

  @workspace_id GoodAnalytics.default_workspace_id()

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_click_conn do
    conn(:post, "/ga/t/click", %{})
    |> Plug.Conn.fetch_cookies()
    |> Plug.Conn.put_req_header("user-agent", "ReferralClickTest/1.0")
    |> Plug.Conn.assign(:ga_source, %{})
    |> Plug.Conn.put_private(:workspace_id, @workspace_id)
    |> Plug.Conn.put_private(:phoenix_format, "json")
    |> Map.put(:host, "test.link")
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

  defp decode_response(conn) do
    Jason.decode!(conn.resp_body)
  end

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "client click with referral link and active partner" do
    test "response has ga_id, _ga_ref cookie is set, event has partner attribution, visitor has partner attribution" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)

      conn = build_click_conn()

      result =
        BeaconController.click(conn, %{
          "key" => link.key,
          "url" => "https://example.com/referral?via=#{link.key}",
          "referrer" => "https://twitter.com",
          "fingerprint" => "fp_referral_active_#{System.unique_integer([:positive])}"
        })

      # Response body contains ga_id and visitor_id
      body = decode_response(result)
      assert body["status"] == "ok"
      assert is_binary(body["ga_id"])
      assert is_binary(body["visitor_id"])

      # _ga_ref cookie is set on the response
      assert %{value: cookie_value} = result.resp_cookies["_ga_ref"]
      assert is_binary(cookie_value)
      assert byte_size(cookie_value) > 0

      # Click event has partner attribution
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert click.partner_id == partner.id
      assert click.referral_link_id == link.id
      assert is_binary(click.referral_click_id)

      # Visitor updated with first and last partner attribution
      visitor = Visitors.get_visitor(body["visitor_id"])
      assert visitor.first_partner_id == partner.id
      assert visitor.last_partner_id == partner.id
    end
  end

  describe "client click with referral link and inactive partner" do
    test "no _ga_ref cookie is set, no partner attribution on event when partner is disabled" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)

      # Disable the partner after link creation
      {:ok, _} = Partners.update_partner(partner.id, %{status: "disabled"})

      conn = build_click_conn()

      result =
        BeaconController.click(conn, %{
          "key" => link.key,
          "url" => "https://example.com/referral?via=#{link.key}",
          "referrer" => "https://twitter.com",
          "fingerprint" => "fp_referral_disabled_#{System.unique_integer([:positive])}"
        })

      # Request succeeds (200 ok — the link itself is still live)
      body = decode_response(result)
      assert body["status"] == "ok"

      # No _ga_ref cookie — build_referral_context returns nil for inactive partners
      refute Map.has_key?(result.resp_cookies, "_ga_ref")

      # Click event has nil partner attribution
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert is_nil(click.partner_id)
      assert is_nil(click.referral_link_id)
      assert is_nil(click.referral_click_id)
    end
  end

  describe "client click with non-referral link" do
    test "no _ga_ref cookie, no partner attribution on event" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/short"})

      conn = build_click_conn()

      result =
        BeaconController.click(conn, %{
          "key" => link.key,
          "url" => "https://destination.com/short?via=#{link.key}",
          "referrer" => "https://example.com",
          "fingerprint" => "fp_nonreferral_#{System.unique_integer([:positive])}"
        })

      body = decode_response(result)
      assert body["status"] == "ok"

      # No referral cookie for a plain short link
      refute Map.has_key?(result.resp_cookies, "_ga_ref")

      # Click event has nil referral attribution fields
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert is_nil(click.partner_id)
      assert is_nil(click.referral_link_id)
      assert is_nil(click.referral_click_id)
    end
  end

  describe "client click preserves first partner on second touch" do
    test "first_partner_id stays set to partner A; last_partner_id updated to partner B" do
      partner_a = create_partner!()
      partner_b = create_partner!()
      link_a = create_referral_link!(partner_a.id, %{url: "https://example.com/a"})
      link_b = create_referral_link!(partner_b.id, %{url: "https://example.com/b"})

      # Shared fingerprint ties both clicks to the same visitor
      fingerprint = "fp_multitouch_#{System.unique_integer([:positive])}"

      # First click — through partner A's link
      conn_a = build_click_conn()

      result_a =
        BeaconController.click(conn_a, %{
          "key" => link_a.key,
          "url" => "https://example.com/a?via=#{link_a.key}",
          "referrer" => "https://twitter.com",
          "fingerprint" => fingerprint
        })

      body_a = decode_response(result_a)
      assert body_a["status"] == "ok"
      visitor_id = body_a["visitor_id"]

      visitor_after_first = Visitors.get_visitor(visitor_id)
      assert visitor_after_first.first_partner_id == partner_a.id
      assert visitor_after_first.last_partner_id == partner_a.id

      # Second click — through partner B's link, same visitor resolved via fingerprint
      conn_b = build_click_conn()

      result_b =
        BeaconController.click(conn_b, %{
          "key" => link_b.key,
          "url" => "https://example.com/b?via=#{link_b.key}",
          "referrer" => "https://twitter.com",
          "fingerprint" => fingerprint
        })

      body_b = decode_response(result_b)
      assert body_b["status"] == "ok"

      visitor_after_second = Visitors.get_visitor(visitor_id)

      # first_partner_id must remain unchanged
      assert visitor_after_second.first_partner_id == partner_a.id

      # last_partner_id must reflect the newer touch
      assert visitor_after_second.last_partner_id == partner_b.id
    end
  end
end
