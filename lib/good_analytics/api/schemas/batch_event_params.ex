defmodule GoodAnalytics.Api.Schemas.BatchEventParams do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchEventParams",
    description: "Request body for recording multiple server-side events.",
    type: :object,
    required: [:events],
    properties: %{
      events: %OpenApiSpex.Schema{
        type: :array,
        description: "Array of event objects (1-100 events)",
        minItems: 1,
        maxItems: 100,
        items: GoodAnalytics.Api.Schemas.EventParams
      }
    }
  })
end
