defmodule GoodAnalytics.Api.Schemas.EventResponse do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EventResponse",
    description: "Response for a successfully recorded event.",
    type: :object,
    required: [:event_id],
    properties: %{
      event_id: %OpenApiSpex.Schema{type: :string, format: :uuid}
    }
  })
end
