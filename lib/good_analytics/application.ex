defmodule GoodAnalytics.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    validate_config!()

    children = [
      {GoodAnalytics.Cache, []},
      {Phoenix.PubSub, name: GoodAnalytics.PubSub},
      {Task.Supervisor, name: GoodAnalytics.TaskSupervisor},
      {GoodAnalytics.Hooks, []},
      {GoodAnalytics.PartitionManager, []}
    ]

    opts = [strategy: :one_for_one, name: GoodAnalytics.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp validate_config! do
    if Application.get_env(:good_analytics, :repo) do
      _ = Application.fetch_env!(:good_analytics, :api_key_secret)
    end
  end
end
