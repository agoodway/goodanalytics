defmodule GoodAnalytics.Core.Tracking.Router do
  @moduledoc """
  Phoenix router for client-side tracking endpoints.

  Mount in your host application:

      forward "/ga/t", GoodAnalytics.Core.Tracking.Router

  Provides:
  - `POST /event` — beacon receiver for JS-initiated events
  - `POST /click` — client-side click tracking (via= param flow)
  """

  use Phoenix.Router

  pipeline :tracking_api do
    plug(:accepts, ["json"])

    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )
  end

  scope "/" do
    pipe_through(:tracking_api)
    post("/event", GoodAnalytics.Core.Tracking.BeaconController, :event)
    post("/click", GoodAnalytics.Core.Tracking.BeaconController, :click)
  end
end
