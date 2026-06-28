defmodule GoodAnalytics.Api.Schemas.AnalyticsSummaryResponse do
  @moduledoc """
  Headline KPIs for a window: visitor/pageview/revenue counts, identification
  rate, and session-grain rates. Backed by `GoodAnalytics.Core.Analytics.kpis/2`.
  """
  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AnalyticsSummaryResponse",
    description: "Headline KPIs for a window.",
    type: :object,
    properties: %{
      visitors: %OpenApiSpex.Schema{type: :integer},
      new_visitors: %OpenApiSpex.Schema{type: :integer},
      pageviews: %OpenApiSpex.Schema{type: :integer},
      revenue: %OpenApiSpex.Schema{type: :integer, description: "Revenue in cents"},
      identification_rate: %OpenApiSpex.Schema{type: :number, format: :float},
      sessions: %OpenApiSpex.Schema{type: :integer},
      bounce_rate: %OpenApiSpex.Schema{type: :number, format: :float},
      avg_duration: %OpenApiSpex.Schema{type: :number, format: :float},
      engaged_rate: %OpenApiSpex.Schema{type: :number, format: :float}
    },
    required: [
      :visitors,
      :new_visitors,
      :pageviews,
      :revenue,
      :identification_rate,
      :sessions,
      :bounce_rate,
      :avg_duration,
      :engaged_rate
    ]
  })
end
