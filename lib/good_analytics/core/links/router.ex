defmodule GoodAnalytics.Core.Links.Router do
  @moduledoc """
  Phoenix router for short link domain redirects.

  Mount this router in your host application for your short link domains.
  It serves `GET /:key/qr` for QR images and catches `GET /:key` requests
  for redirect handling.

  ## Usage

      # In your router
      scope "/", GoodAnalytics.Core.Links do
        get "/:key/qr", QRController, :show
        get "/:key", RedirectController, :show
      end

  Or forward the entire domain:

      forward "/", GoodAnalytics.Core.Links.Router

  """

  use Phoenix.Router

  pipeline :short_link do
    plug(:accepts, ["html"])
    plug(:fetch_query_params)
  end

  pipeline :short_link_qr do
    plug(:fetch_query_params)
  end

  scope "/" do
    pipe_through(:short_link_qr)
    get("/:key/qr", GoodAnalytics.Core.Links.QRController, :show)
  end

  scope "/" do
    pipe_through(:short_link)
    get("/:key", GoodAnalytics.Core.Links.RedirectController, :show)
  end
end
