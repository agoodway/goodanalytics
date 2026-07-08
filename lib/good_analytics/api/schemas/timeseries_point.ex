defmodule GoodAnalytics.Api.Schemas.TimeseriesPoint do
  @moduledoc "One zero-filled, timezone-aligned bucket."
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TimeseriesPoint",
    description: "A single timeseries bucket.",
    type: :object,
    properties: %{
      bucket_start: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      bucket_end: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      value: %OpenApiSpex.Schema{type: :number}
    },
    required: [:bucket_start, :bucket_end, :value]
  })
end
