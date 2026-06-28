defmodule GoodAnalytics.Api.Schemas.TimeseriesResponse do
  @moduledoc "Timeseries response: echoed metric + interval label + points."
  require OpenApiSpex

  alias GoodAnalytics.Api.Schemas.TimeseriesPoint

  OpenApiSpex.schema(%{
    title: "TimeseriesResponse",
    description: "Bucketed timeseries for a single metric.",
    type: :object,
    properties: %{
      metric: %OpenApiSpex.Schema{type: :string},
      interval: %OpenApiSpex.Schema{type: :string},
      points: %OpenApiSpex.Schema{type: :array, items: TimeseriesPoint}
    },
    required: [:metric, :interval, :points]
  })
end
