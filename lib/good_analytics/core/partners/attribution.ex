defmodule GoodAnalytics.Core.Partners.Attribution do
  @moduledoc """
  Shared referral partner attribution logic.

  Provides atomic visitor partner attribution updates and helper
  functions used by the redirect and beacon click flows.
  """

  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Core.Tracking.ReferralCookie
  alias GoodAnalytics.Repo

  import Ecto.Query

  @doc """
  Atomically updates visitor partner attribution.

  Last-touch fields are updated unconditionally. First-touch fields are
  written only when `first_partner_id IS NULL`, using a conditional
  `update_all` with a WHERE guard. This makes first-touch atomic — if two
  concurrent requests both see nil, only one UPDATE will match the IS NULL
  condition in the database, preventing double-write races.
  """
  def set_partner_attribution(visitor_id, context) do
    repo = Repo.repo()

    {count, _} =
      from(v in Visitor, where: v.id == ^visitor_id)
      |> repo.update_all(
        [
          set: [
            last_partner_id: context.partner_id,
            last_referral_link_id: context.referral_link_id,
            last_referral_click_id: context.referral_click_id,
            updated_at: DateTime.utc_now()
          ]
        ],
        prefix: GoodAnalytics.schema_name()
      )

    from(v in Visitor,
      where: v.id == ^visitor_id,
      where: is_nil(v.first_partner_id)
    )
    |> repo.update_all(
      [
        set: [
          first_partner_id: context.partner_id,
          first_referral_link_id: context.referral_link_id,
          first_referral_click_id: context.referral_click_id
        ]
      ],
      prefix: GoodAnalytics.schema_name()
    )

    {:ok, count}
  end

  @doc "Sets the referral cookie on a conn. Returns conn unchanged if context is nil."
  def maybe_set_cookie(conn, nil), do: conn
  def maybe_set_cookie(conn, context), do: ReferralCookie.set_on_conn(conn, context)

  @doc "Merges referral context into event attrs. Returns attrs unchanged if context is nil."
  def merge_into_attrs(attrs, nil), do: attrs
  def merge_into_attrs(attrs, context), do: Map.merge(attrs, context)
end
