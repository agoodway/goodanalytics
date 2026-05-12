defmodule GoodAnalytics.Api.Schemas.ErrorResponse do
  @moduledoc """
  Standard API error response body.

  Includes a top-level error message and optional field-level validation
  errors.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "ErrorResponse",
    description: "Error response body.",
    type: :object,
    required: [:error],
    properties: %{
      error: %OpenApiSpex.Schema{type: :string, description: "Human-readable error message"},
      errors: %OpenApiSpex.Schema{
        type: :object,
        description: "Field-level validation errors",
        additionalProperties: %OpenApiSpex.Schema{
          type: :array,
          items: %OpenApiSpex.Schema{type: :string}
        }
      }
    }
  })
end
