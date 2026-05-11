defmodule GoodAnalytics.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :good_analytics, adapter: Ecto.Adapters.Postgres
end
