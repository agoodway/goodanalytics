defmodule GoodAnalytics.ApiSpec do
  @moduledoc """
  OpenAPI specification for GoodAnalytics.

  Host applications can serve the spec and Swagger UI by forwarding
  to `GoodAnalytics.ApiSpec.Router`:

      forward "/api/docs", GoodAnalytics.ApiSpec.Router
  """

  @behaviour OpenApiSpex.OpenApi

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApiSpex.OpenApi{
      info: %OpenApiSpex.Info{
        title: "GoodAnalytics API",
        version: Mix.Project.config()[:version] || "0.1.0",
        description:
          "Visitor intelligence, link tracking, source attribution, and behavioral analytics."
      },
      paths: OpenApiSpex.Paths.from_router(GoodAnalytics.Api.Router)
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
