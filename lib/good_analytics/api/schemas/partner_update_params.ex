defmodule GoodAnalytics.Api.Schemas.PartnerUpdateParams do
  @moduledoc """
  Request body for updating a referral partner. All fields optional.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PartnerUpdateParams",
    description: "Request body for updating a referral partner.",
    type: :object,
    properties: %{
      name: %OpenApiSpex.Schema{type: :string},
      status: %OpenApiSpex.Schema{type: :string, enum: ~w(active disabled archived)},
      external_id: %OpenApiSpex.Schema{type: :string, nullable: true},
      metadata: %OpenApiSpex.Schema{type: :object, additionalProperties: true}
    }
  })
end
