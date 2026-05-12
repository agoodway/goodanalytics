defmodule GoodAnalytics.Api.Schemas.LinkResponse do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LinkResponse",
    description: "Full link resource.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      domain: %OpenApiSpex.Schema{type: :string},
      key: %OpenApiSpex.Schema{type: :string},
      url: %OpenApiSpex.Schema{type: :string},
      link_type: %OpenApiSpex.Schema{type: :string},
      utm_source: %OpenApiSpex.Schema{type: :string},
      utm_medium: %OpenApiSpex.Schema{type: :string},
      utm_campaign: %OpenApiSpex.Schema{type: :string},
      utm_content: %OpenApiSpex.Schema{type: :string},
      utm_term: %OpenApiSpex.Schema{type: :string},
      expires_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      ios_url: %OpenApiSpex.Schema{type: :string, nullable: true},
      android_url: %OpenApiSpex.Schema{type: :string, nullable: true},
      geo_targeting: %OpenApiSpex.Schema{type: :object},
      og_title: %OpenApiSpex.Schema{type: :string, nullable: true},
      og_description: %OpenApiSpex.Schema{type: :string, nullable: true},
      og_image: %OpenApiSpex.Schema{type: :string, nullable: true},
      total_clicks: %OpenApiSpex.Schema{type: :integer},
      unique_clicks: %OpenApiSpex.Schema{type: :integer},
      total_leads: %OpenApiSpex.Schema{type: :integer},
      total_sales: %OpenApiSpex.Schema{type: :integer},
      total_revenue_cents: %OpenApiSpex.Schema{type: :integer},
      tags: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
      external_id: %OpenApiSpex.Schema{type: :string, nullable: true},
      metadata: %OpenApiSpex.Schema{type: :object},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  })
end
