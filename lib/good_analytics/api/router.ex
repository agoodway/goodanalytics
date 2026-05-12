defmodule GoodAnalytics.Api.Router do
  @moduledoc """
  REST API router for server-side event tracking, link management, and visitor queries.

  Mount in your host app router:

      forward "/ga/api", GoodAnalytics.Api.Router

  """

  use Phoenix.Router

  pipeline :api do
    plug :accepts, ["json"]
    plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
    plug GoodAnalytics.Api.AuthPlug
    plug OpenApiSpex.Plug.PutApiSpec, module: GoodAnalytics.ApiSpec
  end

  scope "/" do
    pipe_through :api

    # Events
    post "/events", GoodAnalytics.Api.EventController, :create
    post "/events/batch", GoodAnalytics.Api.EventController, :batch

    # Links
    resources "/links", GoodAnalytics.Api.LinkController, only: [:create, :index, :show, :update, :delete] do
      get "/stats", GoodAnalytics.Api.LinkController, :stats, as: :stats
      get "/clicks", GoodAnalytics.Api.LinkController, :clicks, as: :clicks
    end

    # Visitors
    get "/visitors", GoodAnalytics.Api.VisitorController, :index
    get "/visitors/by-external-id/:external_id", GoodAnalytics.Api.VisitorController, :lookup
    get "/visitors/:id", GoodAnalytics.Api.VisitorController, :show
    get "/visitors/:id/timeline", GoodAnalytics.Api.VisitorController, :timeline
    get "/visitors/:id/attribution", GoodAnalytics.Api.VisitorController, :attribution
  end
end
