defmodule GoodAnalytics.Api.Schemas.EventParams do
  @moduledoc """
  Request body for recording a single server-side event.

  `event_type` is required, and `visitor_id` takes precedence over
  `person_external_id` when both are provided.
  """
  alias GoodAnalytics.Core.Events.Event

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EventParams",
    description: "Request body for recording a single server-side event.",
    type: :object,
    required: [:event_type],
    properties: %{
      visitor_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "Internal visitor UUID (highest precedence)"
      },
      person_external_id: %OpenApiSpex.Schema{
        type: :string,
        description: "Host app's external person identifier"
      },
      person_email: %OpenApiSpex.Schema{
        type: :string,
        description:
          "Person's email address. Used for identification when visitor is resolved via signals."
      },
      person_phone: %OpenApiSpex.Schema{
        type: :string,
        description:
          "Person's phone number. Used for identification when visitor is resolved via signals."
      },
      ga_id: %OpenApiSpex.Schema{
        type: :string,
        description:
          "Attribution cookie value (_ga_good). Resolved via identity signals when visitor_id and person_external_id are absent."
      },
      anonymous_id: %OpenApiSpex.Schema{
        type: :string,
        description:
          "Anonymous cookie value (_ga_anon). Resolved via identity signals when visitor_id, person_external_id, and ga_id are absent."
      },
      event_type: %OpenApiSpex.Schema{
        type: :string,
        enum: Event.ingest_types()
      },
      event_name: %OpenApiSpex.Schema{
        type: :string,
        description: "Custom event name (used with event_type 'custom')"
      },
      properties: %OpenApiSpex.Schema{
        type: :object,
        description: "Flexible event properties (max 50 keys)",
        additionalProperties: true
      },
      amount_cents: %OpenApiSpex.Schema{type: :integer, description: "Revenue amount in cents"},
      currency: %OpenApiSpex.Schema{type: :string, description: "ISO 4217 currency code"},
      url: %OpenApiSpex.Schema{type: :string, description: "Page URL where the event occurred"},
      referrer: %OpenApiSpex.Schema{type: :string, description: "Referrer URL"},
      partner_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description:
          "Explicit partner attribution (secret key auth only). Ignored for publishable key requests.",
        nullable: true
      },
      referral_link_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "Referral link ID for partner attribution (secret key auth only)",
        nullable: true
      },
      referral_click_id: %OpenApiSpex.Schema{
        type: :string,
        format: :uuid,
        description: "Referral click ID for partner attribution (secret key auth only)",
        nullable: true
      },
      idempotency_key: %OpenApiSpex.Schema{
        type: :string,
        maxLength: 255,
        description: "Client-supplied idempotency key to prevent duplicate events"
      }
    }
  })
end
