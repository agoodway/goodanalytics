defmodule GoodAnalytics.Api.Schemas.PaginationParams do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PaginationParams",
    description: "Shared pagination query parameters.",
    type: :object,
    properties: %{
      limit: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
      offset: %OpenApiSpex.Schema{type: :integer, minimum: 0, default: 0}
    }
  })
end
