defmodule GoodAnalytics.Api.Schemas.BatchEventParams do
  @moduledoc """
  Request body for submitting multiple server-side events.

  Contains an `events` array with 1 to 100 `EventParams` items.
  """
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
