defmodule GoodAnalytics.Api.Schemas.ClickResponse do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ClickResponse",
    description: "A link click event.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      visitor_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      url: %OpenApiSpex.Schema{type: :string, nullable: true},
      referrer: %OpenApiSpex.Schema{type: :string, nullable: true},
      ip_address: %OpenApiSpex.Schema{type: :string, nullable: true},
      user_agent: %OpenApiSpex.Schema{type: :string, nullable: true},
      properties: %OpenApiSpex.Schema{type: :object},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  })
end
