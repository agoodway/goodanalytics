defmodule GoodAnalytics.Api.Schemas.LinkUpdateParams do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LinkUpdateParams",
    description: "Request body for updating a tracked link. All fields are optional.",
    type: :object,
    properties: %{
      url: %OpenApiSpex.Schema{type: :string, format: :uri},
      link_type: %OpenApiSpex.Schema{type: :string, enum: ~w(short referral campaign)},
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
