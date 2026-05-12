defmodule GoodAnalytics.Api.Schemas.BatchEventResponse do
  @moduledoc """
  Per-event results from a batch event submission.

  Each result includes the original event index, status, and either an
  `event_id` or an error message.
  """
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
