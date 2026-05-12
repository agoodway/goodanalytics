defmodule GoodAnalytics.Api.Schemas.TimelineResponse do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "TimelineResponse",
    description: "An event in a visitor's timeline.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      event_type: %OpenApiSpex.Schema{type: :string},
      event_name: %OpenApiSpex.Schema{type: :string, nullable: true},
      url: %OpenApiSpex.Schema{type: :string, nullable: true},
      referrer: %OpenApiSpex.Schema{type: :string, nullable: true},
      source_platform: %OpenApiSpex.Schema{type: :string, nullable: true},
      source_medium: %OpenApiSpex.Schema{type: :string, nullable: true},
      source_campaign: %OpenApiSpex.Schema{type: :string, nullable: true},
      amount_cents: %OpenApiSpex.Schema{type: :integer, nullable: true},
      currency: %OpenApiSpex.Schema{type: :string, nullable: true},
      properties: %OpenApiSpex.Schema{type: :object},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  })
end
