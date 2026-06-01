defmodule GoodAnalytics.Api.Schemas.PartnerResponse do
  @moduledoc """
  Full referral partner resource returned by the API.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PartnerResponse",
    description: "Full partner resource.",
    type: :object,
    properties: %{
      id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      workspace_id: %OpenApiSpex.Schema{type: :string, format: :uuid},
      key: %OpenApiSpex.Schema{type: :string},
      name: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{type: :string},
      external_id: %OpenApiSpex.Schema{type: :string, nullable: true},
      metadata: %OpenApiSpex.Schema{type: :object},
      archived_at: %OpenApiSpex.Schema{type: :string, format: :"date-time", nullable: true},
      inserted_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"},
      updated_at: %OpenApiSpex.Schema{type: :string, format: :"date-time"}
    }
  })
end
