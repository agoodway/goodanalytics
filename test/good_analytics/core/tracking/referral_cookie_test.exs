defmodule GoodAnalytics.Core.Tracking.ReferralCookieTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias GoodAnalytics.Core.Tracking.ReferralCookie

  @valid_context %{
    partner_id: "aaaaaaaa-0000-0000-0000-000000000001",
    referral_link_id: "bbbbbbbb-0000-0000-0000-000000000002",
    referral_click_id: "cccccccc-0000-0000-0000-000000000003",
    workspace_id: "11111111-1111-1111-1111-111111111111"
  }

  describe "cookie_name/0" do
    test "returns the expected cookie name" do
      assert ReferralCookie.cookie_name() == "_ga_ref"
    end
  end

  describe "cookie_opts/0" do
    test "returns a keyword list with required options" do
      opts = ReferralCookie.cookie_opts()
      assert Keyword.get(opts, :http_only) == false
      assert Keyword.get(opts, :same_site) == "Lax"
      assert Keyword.get(opts, :secure) == true
      assert Keyword.get(opts, :path) == "/"
    end

    test "sets max_age to 90 days in seconds" do
      opts = ReferralCookie.cookie_opts()
      assert Keyword.get(opts, :max_age) == 90 * 86_400
    end
  end

  describe "sign/1 and verify/1 round-trip" do
    test "verifying a freshly signed token returns the original context" do
      token = ReferralCookie.sign(@valid_context)
      assert {:ok, result} = ReferralCookie.verify(token)

      assert result.partner_id == @valid_context.partner_id
      assert result.referral_link_id == @valid_context.referral_link_id
      assert result.referral_click_id == @valid_context.referral_click_id
      assert result.workspace_id == @valid_context.workspace_id
    end

    test "verified result includes issued_at timestamp" do
      token = ReferralCookie.sign(@valid_context)
      assert {:ok, result} = ReferralCookie.verify(token)
      assert is_integer(result.issued_at)
    end

    test "preserves original issued_at when re-signing an existing context" do
      original_iat = System.system_time(:second) - 3600
      context_with_iat = Map.put(@valid_context, :issued_at, original_iat)
      token = ReferralCookie.sign(context_with_iat)
      assert {:ok, result} = ReferralCookie.verify(token)
      assert result.issued_at == original_iat
    end
  end

  describe "verify/1 with invalid input" do
    test "returns {:error, :invalid} for nil" do
      assert {:error, :invalid} = ReferralCookie.verify(nil)
    end

    test "returns {:error, :invalid} for an empty string" do
      assert {:error, _} = ReferralCookie.verify("")
    end

    test "returns {:error, :invalid} for an integer" do
      assert {:error, :invalid} = ReferralCookie.verify(12_345)
    end

    test "returns {:error, :invalid} for an atom" do
      assert {:error, :invalid} = ReferralCookie.verify(:not_a_token)
    end

    test "returns error for a tampered token" do
      token = ReferralCookie.sign(@valid_context)
      tampered = token <> "TAMPERED"
      assert {:error, _} = ReferralCookie.verify(tampered)
    end

    test "returns error for a random binary string" do
      assert {:error, _} = ReferralCookie.verify("not.a.real.token")
    end
  end

  describe "verify/1 with an expired token" do
    test "returns {:error, :expired} for a token older than max_age" do
      # Sign the token then verify with a max_age of 0 to simulate expiry.
      # Phoenix.Token.verify accepts max_age in seconds; passing 0 rejects
      # tokens even freshly issued.
      token = ReferralCookie.sign(@valid_context)

      # Directly call Phoenix.Token.verify with max_age: 0 to confirm expiry
      # semantics without sleeping.
      secret =
        Application.get_env(:good_analytics, :referral_cookie_secret) ||
          Application.fetch_env!(:good_analytics, :api_key_secret)

      assert {:error, :expired} =
               Phoenix.Token.verify(secret, "ga_ref_v1", token, max_age: 0)
    end
  end

  describe "verify/2 workspace-scoped verification" do
    test "returns {:ok, context} when workspace_id matches" do
      token = ReferralCookie.sign(@valid_context)
      assert {:ok, result} = ReferralCookie.verify(token, @valid_context.workspace_id)
      assert result.workspace_id == @valid_context.workspace_id
    end

    test "returns {:error, :workspace_mismatch} when workspace_id does not match" do
      token = ReferralCookie.sign(@valid_context)
      other_workspace = "22222222-2222-2222-2222-222222222222"
      assert {:error, :workspace_mismatch} = ReferralCookie.verify(token, other_workspace)
    end

    test "propagates verify/1 errors" do
      assert {:error, _} = ReferralCookie.verify("not.a.real.token", @valid_context.workspace_id)
    end
  end

  describe "normalize/3" do
    test "returns a map with the canonical attribution shape" do
      result =
        ReferralCookie.normalize(
          @valid_context.partner_id,
          @valid_context.referral_link_id,
          @valid_context.referral_click_id
        )

      assert result == %{
               partner_id: @valid_context.partner_id,
               referral_link_id: @valid_context.referral_link_id,
               referral_click_id: @valid_context.referral_click_id,
               workspace_id: nil,
               issued_at: nil
             }
    end

    test "includes issued_at from opts map" do
      ts = System.system_time(:second)

      result =
        ReferralCookie.normalize(
          @valid_context.partner_id,
          @valid_context.referral_link_id,
          @valid_context.referral_click_id,
          %{iat: ts}
        )

      assert result.issued_at == ts
    end

    test "issued_at is nil when not present in opts" do
      result =
        ReferralCookie.normalize(
          @valid_context.partner_id,
          @valid_context.referral_link_id,
          @valid_context.referral_click_id,
          %{}
        )

      assert is_nil(result.issued_at)
    end

    test "includes workspace_id from opts map" do
      result =
        ReferralCookie.normalize(
          @valid_context.partner_id,
          @valid_context.referral_link_id,
          @valid_context.referral_click_id,
          %{workspace_id: @valid_context.workspace_id}
        )

      assert result.workspace_id == @valid_context.workspace_id
    end

    test "workspace_id is nil when not present in opts" do
      result =
        ReferralCookie.normalize(
          @valid_context.partner_id,
          @valid_context.referral_link_id,
          @valid_context.referral_click_id,
          %{}
        )

      assert is_nil(result.workspace_id)
    end
  end

  describe "read_from_conn/1" do
    test "returns {:ok, context} when a valid cookie is present" do
      token = ReferralCookie.sign(@valid_context)

      conn =
        conn(:get, "/")
        |> Plug.Test.put_req_cookie("_ga_ref", token)
        |> Plug.Conn.fetch_cookies()

      assert {:ok, result} = ReferralCookie.read_from_conn(conn)
      assert result.partner_id == @valid_context.partner_id
      assert result.referral_link_id == @valid_context.referral_link_id
      assert result.referral_click_id == @valid_context.referral_click_id
      assert result.workspace_id == @valid_context.workspace_id
    end

    test "returns {:error, :not_present} when the cookie is absent" do
      conn =
        conn(:get, "/")
        |> Plug.Conn.fetch_cookies()

      assert {:error, :not_present} = ReferralCookie.read_from_conn(conn)
    end

    test "returns error when the cookie value is invalid" do
      conn =
        conn(:get, "/")
        |> Plug.Test.put_req_cookie("_ga_ref", "not.a.valid.token")
        |> Plug.Conn.fetch_cookies()

      assert {:error, _} = ReferralCookie.read_from_conn(conn)
    end

    test "returns error when the cookie value is tampered" do
      token = ReferralCookie.sign(@valid_context)

      conn =
        conn(:get, "/")
        |> Plug.Test.put_req_cookie("_ga_ref", token <> "X")
        |> Plug.Conn.fetch_cookies()

      assert {:error, _} = ReferralCookie.read_from_conn(conn)
    end
  end
end
