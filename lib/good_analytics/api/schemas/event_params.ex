defmodule GoodAnalytics.Api.Schemas.EventParams do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EventParams",
    description: "Request body for recording a single server-side event.",
    type: :object,
    required: [:event_type],
    properties: %{
      visitor_id: %OpenApiSpex.Schema{type: :string, format: :uuid, description: "Visitor UUID (takes precedence over person_external_id)"},
      person_external_id: %OpenApiSpex.Schema{type: :string, description: "Host app's external person identifier"},
      event_type: %OpenApiSpex.Schema{type: :string, enum: ~w(link_click pageview session_start identify lead sale share engagement custom)},
      event_name: %OpenApiSpex.Schema{type: :string, description: "Custom event name (used with event_type 'custom')"},
      properties: %OpenApiSpex.Schema{type: :object, description: "Flexible event properties (max 50 keys)", additionalProperties: true},
      amount_cents: %OpenApiSpex.Schema{type: :integer, description: "Revenue amount in cents"},
      currency: %OpenApiSpex.Schema{type: :string, description: "ISO 4217 currency code"},
      url: %OpenApiSpex.Schema{type: :string, description: "Page URL where the event occurred"},
      referrer: %OpenApiSpex.Schema{type: :string, description: "Referrer URL"},
      idempotency_key: %OpenApiSpex.Schema{type: :string, maxLength: 255, description: "Client-supplied idempotency key to prevent duplicate events"}
    }
  })
end
