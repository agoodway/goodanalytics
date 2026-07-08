defmodule GoodAnalytics.Api.Schemas.BreakdownRow do
  @moduledoc """
  One dimension bucket with its metric values.

  Only the requested metrics are populated; session-grain rates
  (`bounce_rate`/`avg_duration`/`engaged_rate`) are floats and may be `null`.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BreakdownRow",
    description: "A single dimension bucket with metric values.",
    type: :object,
    properties: %{
      value: %OpenApiSpex.Schema{
        type: :string,
        description: "Dimension value ('(not set)' for nulls)"
      },
      events: %OpenApiSpex.Schema{type: :integer, nullable: true},
      pageviews: %OpenApiSpex.Schema{type: :integer, nullable: true},
      users: %OpenApiSpex.Schema{type: :integer, nullable: true},
      sessions: %OpenApiSpex.Schema{type: :integer, nullable: true},
      bounce_rate: %OpenApiSpex.Schema{type: :number, format: :float, nullable: true},
      avg_duration: %OpenApiSpex.Schema{type: :number, format: :float, nullable: true},
      engaged_rate: %OpenApiSpex.Schema{type: :number, format: :float, nullable: true}
    },
    required: [:value]
  })
end
