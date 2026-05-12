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
      # Dedicated supervisor for fire-and-forget geo enrichment tasks. Capped
      # at 10,000 in-flight tasks so a thundering herd or upstream slowdown
      # cannot exhaust the BEAM via unbounded task fanout. When the cap is
      # hit, `Task.Supervisor.start_child/2` returns `{:error, :max_children}`
      # and `GoodAnalytics.Geo.enqueue_enrichment/2` drops the enrichment
      # (event ingest itself is unaffected — enrichment is purely advisory).
      {Task.Supervisor, name: GoodAnalytics.GeoTaskSupervisor, max_children: 10_000},
      {GoodAnalytics.Hooks, []},
      {GoodAnalytics.PartitionManager, []},
      GoodAnalytics.Geo.Loader
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
