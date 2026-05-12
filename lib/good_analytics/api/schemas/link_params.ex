defmodule GoodAnalytics.Api.Schemas.LinkParams do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LinkParams",
    description: "Request body for creating or updating a tracked link.",
    type: :object,
    required: [:domain, :key, :url],
    properties: %{
      domain: %OpenApiSpex.Schema{type: :string},
      key: %OpenApiSpex.Schema{type: :string},
      url: %OpenApiSpex.Schema{type: :string, format: :uri},
      link_type: %OpenApiSpex.Schema{type: :string, enum: ~w(short referral campaign), default: "short"},
      utm_source: %OpenApiSpex.Schema{type: :string},
      utm_medium: %OpenApiSpex.Schema{type: :string},
      utm_campaign: %OpenApiSpex.Schema{type: :string},
      utm_content: %OpenApiSpex.Schema{type: :string},
      utm_term: %OpenApiSpex.Schema{type: :string},
      expires_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      ios_url: %OpenApiSpex.Schema{type: :string, format: :uri},
      android_url: %OpenApiSpex.Schema{type: :string, format: :uri},
      geo_targeting: %OpenApiSpex.Schema{type: :object, additionalProperties: true},
      og_title: %OpenApiSpex.Schema{type: :string},
      og_description: %OpenApiSpex.Schema{type: :string},
      og_image: %OpenApiSpex.Schema{type: :string, format: :uri},
      tags: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
      external_id: %OpenApiSpex.Schema{type: :string},
      metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
    }
  })
end
