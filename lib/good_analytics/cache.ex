defmodule GoodAnalytics.Cache do
  @moduledoc """
  Nebulex cache for click deduplication and settings caching.

  Default adapter is `Nebulex.Adapters.Local` (ETS-backed).
  For multi-node deployments, configure `Nebulex.Adapters.Replicated`.

      config :good_analytics, GoodAnalytics.Cache,
        adapter: Nebulex.Adapters.Replicated
  """

  use Nebulex.Cache,
    otp_app: :good_analytics,
    adapter: Nebulex.Adapters.Local
end
