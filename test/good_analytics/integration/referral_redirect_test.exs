defmodule GoodAnalytics.Integration.ReferralRedirectTest do
  @moduledoc """
  Integration tests for the redirect flow with referral partner attribution.

  Covers partner validation, cookie attribution, visitor partner fields,
  event referral fields, and multi-touch attribution sequencing.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Links.Redirect
  alias GoodAnalytics.Core.Partners
  alias GoodAnalytics.Core.Visitors

  import Plug.Test

  @workspace_id GoodAnalytics.default_workspace_id()

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp build_redirect_conn(path, opts \\ []) do
    conn(:get, path)
    |> Map.put(:host, Keyword.get(opts, :host, "test.link"))
    |> Map.put(:query_params, URI.decode_query(URI.parse(path).query || ""))
    |> Plug.Conn.fetch_query_params()
    |> Plug.Conn.put_req_header("user-agent", Keyword.get(opts, :user_agent, "TestBot/1.0"))
    |> Plug.Conn.put_private(:phoenix_format, "html")
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

  # ---------------------------------------------------------------------------
  # Tests
  # ---------------------------------------------------------------------------

  describe "referral redirect with active partner" do
    test "returns 302, sets _ga_ref cookie, records event with referral fields, updates visitor attribution" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      # 302 redirect
      assert result.status == 302

      # _ga_ref cookie is set on the response
      assert %{value: cookie_value} = result.resp_cookies["_ga_ref"]
      assert is_binary(cookie_value)
      assert byte_size(cookie_value) > 0

      # Click event recorded with referral fields populated
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert click.partner_id == partner.id
      assert click.referral_link_id == link.id
      assert is_binary(click.referral_click_id)

      # Visitor updated with first and last partner attribution
      visitor = Visitors.get_visitor(click.visitor_id)
      assert visitor.first_partner_id == partner.id
      assert visitor.last_partner_id == partner.id
    end
  end

  describe "referral redirect with inactive (disabled) partner" do
    test "returns 404 'Link not found' when partner status is disabled" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)

      # Disable the partner after link creation
      {:ok, _} = Partners.update_partner(partner.id, %{status: "disabled"})

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      assert result.status == 404
      assert result.resp_body =~ "Link not found"
    end
  end

  describe "referral redirect with archived partner" do
    test "returns 404 'Link not found' when partner is archived" do
      partner = create_partner!()
      link = create_referral_link!(partner.id)

      # Archive the partner after link creation
      {:ok, _} = Partners.archive_partner(partner.id)

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      assert result.status == 404
      assert result.resp_body =~ "Link not found"
    end
  end

  describe "non-referral redirect" do
    test "returns 302, no _ga_ref cookie, event has nil partner fields" do
      link = create_link!(%{domain: "test.link", url: "https://destination.com/short"})

      conn = build_redirect_conn("/#{link.key}")
      result = Redirect.handle_redirect(conn, "test.link", link.key)

      assert result.status == 302

      # No referral cookie on a plain short link
      refute Map.has_key?(result.resp_cookies, "_ga_ref")

      # Click event has nil referral attribution fields
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert is_nil(click.partner_id)
      assert is_nil(click.referral_link_id)
      assert is_nil(click.referral_click_id)
    end
  end

  describe "second referral touch preserves first_partner_id" do
    test "first_partner_id stays set to first partner; last_partner_id updated to second partner" do
      partner_a = create_partner!()
      partner_b = create_partner!()
      link_a = create_referral_link!(partner_a.id, %{url: "https://example.com/a"})
      link_b = create_referral_link!(partner_b.id, %{url: "https://example.com/b"})

      # First redirect — through partner A
      conn_a = build_redirect_conn("/#{link_a.key}")
      result_a = Redirect.handle_redirect(conn_a, "test.link", link_a.key)
      assert result_a.status == 302

      clicks_a = Links.link_clicks(link_a.id)
      assert [click_a | _] = clicks_a
      visitor_id = click_a.visitor_id

      visitor_after_first = Visitors.get_visitor(visitor_id)
      assert visitor_after_first.first_partner_id == partner_a.id
      assert visitor_after_first.last_partner_id == partner_a.id

      # Second redirect — through partner B, same visitor identity not established
      # via cookie in this integration test, so the second redirect creates a new
      # visitor. We verify the single-touch behaviour for each visitor is correct
      # and then directly verify multi-touch by calling update_attribution manually
      # to mirror what the redirect does when the same visitor is resolved.
      #
      # To test true multi-touch we simulate the visitor being resolved to the
      # same record by updating attribution directly with the existing visitor.
      alias GoodAnalytics.Core.Visitors

      # Simulate: same visitor clicks link B (as would happen with cookie resolution)
      referral_context_b = %{
        partner_id: partner_b.id,
        referral_link_id: link_b.id,
        referral_click_id: Uniq.UUID.uuid7()
      }

      Visitors.update_attribution(visitor_id, %{
        last_partner_id: referral_context_b.partner_id,
        last_referral_link_id: referral_context_b.referral_link_id,
        last_referral_click_id: referral_context_b.referral_click_id
      })

      visitor_after_second = Visitors.get_visitor(visitor_id)

      # first_partner_id must remain unchanged
      assert visitor_after_second.first_partner_id == partner_a.id

      # last_partner_id must reflect the newer touch
      assert visitor_after_second.last_partner_id == partner_b.id
    end
  end

  describe "pre-existing referral link without partner_id" do
    test "redirect works normally, no _ga_ref cookie, no partner attribution" do
      # The link changeset rejects referral links without a partner_id, so we
      # bypass the changeset via raw SQL to simulate a pre-existing record
      # (e.g. data migrated before partner support was added).
      key = "k#{System.unique_integer([:positive])}"
      link_id = Uniq.UUID.uuid7()
      schema = GoodAnalytics.schema_name()

      GoodAnalytics.Repo.repo().query!(
        """
        INSERT INTO #{schema}.ga_links
          (id, workspace_id, domain, key, url, link_type, partner_id,
           total_clicks, unique_clicks, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, NULL, 0, 0, NOW(), NOW())
        """,
        [
          Ecto.UUID.dump!(link_id),
          Ecto.UUID.dump!(@workspace_id),
          "test.link",
          key,
          "https://example.com/legacy-referral",
          "referral"
        ]
      )

      conn = build_redirect_conn("/#{key}")
      result = Redirect.handle_redirect(conn, "test.link", key)

      assert result.status == 302

      # No referral cookie — no partner_id means no referral context
      refute Map.has_key?(result.resp_cookies, "_ga_ref")

      # No partner attribution on the click event
      link = Links.get_link(link_id)
      clicks = Links.link_clicks(link.id)
      assert [click | _] = clicks
      assert is_nil(click.partner_id)
    end
  end
end
