import Config

config :good_analytics, :schema_prefix, "good_analytics"

config :good_analytics, GoodAnalytics.Cache,
  gc_interval: :timer.hours(1),
  max_size: 10_000

import_config "#{config_env()}.exs"
