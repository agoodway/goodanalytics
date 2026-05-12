defmodule GoodAnalytics.Api.Schemas.AttributionResponse do
  @moduledoc """
  Attribution details for a visitor.

  Includes first-touch, last-touch, and full attribution path data with
  first/last-seen timestamps.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AttributionResponse",
    description: "Attribution data for a visitor.",
    type: :object,
    properties: %{
      attribution_path: %OpenApiSpex.Schema{
        type: :array,
        items: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
      },
      first_source: %OpenApiSpex.Schema{type: :object, nullable: true},
      last_source: %OpenApiSpex.Schema{type: :object, nullable: true},
      first_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      last_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true}
    }
  })
end
