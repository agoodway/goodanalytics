defmodule GoodAnalytics.Api.Schemas.VisitorResponse do
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "VisitorResponse",
    description: "Full visitor resource.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      workspace_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      status: %OpenApiSpex.Schema{type: :string, enum: ~w(anonymous identified lead customer churned)},
      person_external_id: %OpenApiSpex.Schema{type: :string, nullable: true},
      person_email: %OpenApiSpex.Schema{type: :string, nullable: true},
      person_name: %OpenApiSpex.Schema{type: :string, nullable: true},
      person_metadata: %OpenApiSpex.Schema{type: :object},
      first_source: %OpenApiSpex.Schema{type: :object, nullable: true},
      last_source: %OpenApiSpex.Schema{type: :object, nullable: true},
      first_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      last_seen_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      geo: %OpenApiSpex.Schema{type: :object},
      device: %OpenApiSpex.Schema{type: :object},
      total_sessions: %OpenApiSpex.Schema{type: :integer},
      total_pageviews: %OpenApiSpex.Schema{type: :integer},
      total_events: %OpenApiSpex.Schema{type: :integer},
      ltv_cents: %OpenApiSpex.Schema{type: :integer},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  })
end
