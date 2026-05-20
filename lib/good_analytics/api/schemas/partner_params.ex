defmodule GoodAnalytics.Api.Schemas.PartnerParams do
  @moduledoc """
  Request body for creating a referral partner.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "PartnerParams",
    description: "Request body for creating a referral partner.",
    type: :object,
    required: [:key, :name],
    properties: %{
      key: %OpenApiSpex.Schema{
        type: :string,
        description: "Unique partner key within the workspace (letters, numbers, hyphens, underscores)"
      },
      name: %OpenApiSpex.Schema{type: :string, description: "Display name for the partner"},
      status: %OpenApiSpex.Schema{
        type: :string,
        enum: ~w(active disabled archived),
        default: "active"
      },
      external_id: %OpenApiSpex.Schema{
        type: :string,
        description: "Optional external system identifier",
        nullable: true
      },
      metadata: %OpenApiSpex.Schema{
        type: :object,
        additionalProperties: true,
        description: "Arbitrary metadata"
      }
    }
  })
end
