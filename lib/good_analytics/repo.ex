defmodule GoodAnalytics.Repo do
  @moduledoc """
  Provides access to the host application's Ecto repo.

  GoodAnalytics doesn't define its own Ecto.Repo — it borrows the host
  application's repo at runtime. Context modules call `repo()` directly:

      GoodAnalytics.Repo.repo().all(query)
      GoodAnalytics.Repo.repo().insert(changeset)

  Configure via:

      config :good_analytics, repo: MyApp.Repo

  """

  @doc """
  Returns the configured Ecto repo module.

  Raises if no repo has been configured.
  """
  def repo do
    Application.get_env(:good_analytics, :repo) ||
      raise """
      GoodAnalytics requires a repo to be configured:

          config :good_analytics, repo: MyApp.Repo

      """
  end
end
