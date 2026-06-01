defmodule GoodAnalytics.Core.Tracking.ReferralCookie do
  @moduledoc """
  Signs, verifies, and manages the `_ga_ref` referral attribution cookie.

  The cookie payload carries partner context as a signed token that
  prevents client-side tampering while remaining readable by the JS
  snippet (the cookie is NOT HttpOnly).

  Tokens are workspace-scoped: the workspace_id is embedded in the signed
  payload so a token minted for workspace A cannot be replayed against
  workspace B's attribution data.
  """

  @cookie_name "_ga_ref"
  @cookie_max_age 90 * 86_400
  @token_salt "ga_ref_v1"

  @doc "Returns the cookie name."
  def cookie_name, do: @cookie_name

  @doc "Returns the default max-age in seconds."
  def max_age, do: @cookie_max_age

  @doc "Returns the cookie options for Plug.Conn.put_resp_cookie/4."
  def cookie_opts do
    [
      max_age: @cookie_max_age,
      http_only: false,
      same_site: "Lax",
      secure: true,
      path: "/"
    ]
  end

  @doc """
  Signs a referral attribution context into a cookie-safe token.

  The context map must include:
  - `:partner_id` — the credited partner UUID
  - `:referral_link_id` — the referral link UUID
  - `:referral_click_id` — the click UUID from this referral touch
  - `:workspace_id` — the workspace this token is scoped to

  An optional `:issued_at` unix timestamp is preserved if present (used
  when re-signing an existing cookie to extend its TTL without resetting
  the original attribution time). When absent, the current time is used.
  """
  def sign(%{partner_id: _, referral_link_id: _, referral_click_id: _, workspace_id: _} = context) do
    payload = %{
      pid: context.partner_id,
      rlid: context.referral_link_id,
      rcid: context.referral_click_id,
      wid: context.workspace_id,
      iat: Map.get(context, :issued_at) || System.system_time(:second)
    }

    Phoenix.Token.sign(signing_secret(), @token_salt, payload)
  end

  @doc """
  Verifies a signed referral cookie token and returns the attribution context.

  Returns `{:ok, context}` with a normalized referral attribution map,
  or `{:error, reason}` for invalid, expired, or tampered tokens.

  Handles tokens signed before workspace_id was added (backward compatibility).
  """
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(signing_secret(), @token_salt, token, max_age: @cookie_max_age) do
      {:ok, %{pid: pid, rlid: rlid, rcid: rcid, wid: wid} = payload} ->
        {:ok, normalize(pid, rlid, rcid, Map.merge(payload, %{workspace_id: wid}))}

      # Handle tokens signed before workspace_id was added (backward compat)
      {:ok, %{pid: pid, rlid: rlid, rcid: rcid} = payload} ->
        {:ok, normalize(pid, rlid, rcid, payload)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify(_), do: {:error, :invalid}

  @doc """
  Verifies a token and validates it belongs to the given workspace.

  Returns `{:error, :workspace_mismatch}` if the token's workspace doesn't match.
  Legacy tokens without a workspace_id (minted before this feature) are treated
  as absent and return `{:ok, %{}}` rather than blocking attribution.
  """
  def verify(token, workspace_id) when is_binary(token) and is_binary(workspace_id) do
    case verify(token) do
      {:ok, %{workspace_id: wid} = context} when wid == workspace_id -> {:ok, context}
      {:ok, %{workspace_id: nil}} -> {:ok, %{}}
      {:ok, _} -> {:error, :workspace_mismatch}
      error -> error
    end
  end

  @doc """
  Reads and verifies the referral cookie from a Plug conn.

  Returns `{:ok, context}` or `{:error, reason}`.
  """
  def read_from_conn(%{cookies: %Plug.Conn.Unfetched{}}), do: {:error, :not_present}

  def read_from_conn(conn) do
    case conn.cookies[@cookie_name] do
      nil -> {:error, :not_present}
      token -> verify(token)
    end
  end

  @doc """
  Sets the referral cookie on a Plug conn with signed referral context.
  """
  def set_on_conn(conn, context) do
    token = sign(context)
    Plug.Conn.put_resp_cookie(conn, @cookie_name, token, cookie_opts())
  end

  @doc """
  Normalizes referral attribution context into the canonical map shape
  used by the redirect flow, beacon, plug, and event recorder.
  """
  def normalize(partner_id, referral_link_id, referral_click_id, opts \\ %{}) do
    %{
      partner_id: partner_id,
      referral_link_id: referral_link_id,
      referral_click_id: referral_click_id,
      workspace_id: Map.get(opts, :workspace_id) || Map.get(opts, :wid),
      issued_at: Map.get(opts, :iat)
    }
  end

  defp signing_secret do
    Application.get_env(:good_analytics, :referral_cookie_secret) ||
      Application.fetch_env!(:good_analytics, :api_key_secret)
  end
end
