defmodule GoodAnalytics.Api.Schemas.BatchEventResponse do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "BatchEventResponse",
    description: "Response for batch event submission.",
    type: :object,
    required: [:results],
    properties: %{
      results: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{
          type: :object,
          properties: %{
            index: %OpenApiSpex.Schema{type: :integer},
            status: %OpenApiSpex.Schema{type: :string, enum: ["ok", "error"]},
            event_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
            error: %OpenApiSpex.Schema{type: :string}
          }
        }
      }
    }
  })
end
