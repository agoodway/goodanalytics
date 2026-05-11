defmodule GoodAnalytics.Core.Tracking.JsController do
  @moduledoc """
  Serves GoodAnalytics JS snippet files from priv/static/js.
  """

  use Phoenix.Controller, formats: [:html]

  @js_dir :code.priv_dir(:good_analytics) |> Path.join("static/js")
  @allowed_files ~w(good-analytics thumbmark)

  @doc "Serves an allowed JS file from priv/static/js."
  def show(conn, %{"file" => file}) when file in @allowed_files do
    path = Path.join(@js_dir, file <> ".js")

    if File.exists?(path) do
      content = File.read!(path)

      conn
      |> put_resp_content_type("application/javascript")
      |> put_resp_header("cache-control", "public, max-age=86400")
      |> send_resp(200, content)
    else
      conn
      |> put_status(404)
      |> text("Not found")
    end
  end

  def show(conn, _params) do
    conn
    |> put_status(404)
    |> text("Not found")
  end
end
