defmodule GoodAnalytics.Api.Schemas.BreakdownResponse do
  @moduledoc """
  Audience breakdown response: the echoed dimension plus the metric rows.
  """
  require OpenApiSpex

  alias GoodAnalytics.Api.Schemas.BreakdownRow

  OpenApiSpex.schema(%{
    title: "BreakdownResponse",
    description: "Audience breakdown grouped by a single dimension.",
    type: :object,
    properties: %{
      dimension: %OpenApiSpex.Schema{type: :string},
      metrics: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :string}
      },
      rows: %OpenApiSpex.Schema{type: :array, items: BreakdownRow}
    },
    required: [:dimension, :metrics, :rows]
  })
end
