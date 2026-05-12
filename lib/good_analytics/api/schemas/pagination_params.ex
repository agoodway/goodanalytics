defmodule GoodAnalytics.Api.Schemas.PaginationParams do
  @moduledoc """
  Shared pagination query parameters.

  Defines `limit` and `offset` bounds used by list endpoints.
  """
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
