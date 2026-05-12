defmodule GoodAnalytics.ApiSpec.Router do
  @moduledoc """
  Router that serves OpenAPI spec JSON and Swagger UI.

  Mount in your host application:

      forward "/api/docs", GoodAnalytics.ApiSpec.Router

  Provides:
  - `GET /openapi` — OpenAPI 3.0 spec as JSON
  - `GET /swaggerui` — interactive Swagger UI
  """

  use Phoenix.Router

  pipeline :api_spec do
    plug :accepts, ["json", "html"]
  end

  scope "/" do
    pipe_through :api_spec

    get "/openapi", OpenApiSpex.Plug.RenderSpec, spec: GoodAnalytics.ApiSpec
  end

  scope "/swaggerui" do
    pipe_through :api_spec

    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/docs/openapi"
  end
end
