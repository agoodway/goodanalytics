defmodule GoodAnalytics.Api.Schemas.EventResponse do
  @moduledoc """
  Success response for a recorded event. Returns the persisted `event_id`.
  """
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
