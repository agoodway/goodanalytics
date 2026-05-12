defmodule GoodAnalytics.Api.Schemas.LinkStatsResponse do
  @moduledoc """
  Aggregated performance metrics for a link.

  Includes click, lead, sale, and revenue totals.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "LinkStatsResponse",
    description: "Aggregated statistics for a link.",
    type: :object,
    properties: %{
      total_clicks: %OpenApiSpex.Schema{type: :integer},
      unique_clicks: %OpenApiSpex.Schema{type: :integer},
      total_leads: %OpenApiSpex.Schema{type: :integer},
      total_sales: %OpenApiSpex.Schema{type: :integer},
      total_revenue_cents: %OpenApiSpex.Schema{type: :integer}
    }
  })
end
