defmodule GoodAnalytics.Core.Links.RedirectController do
  @moduledoc false

  use Phoenix.Controller, formats: [:html]

  alias GoodAnalytics.Core.Links.Redirect

  @doc "Handles GET /:key — resolves the link and redirects."
  def show(conn, %{"key" => key}) do
    domain = get_domain(conn)
    Redirect.handle_redirect(conn, domain, key)
  end

  defp get_domain(conn) do
    conn.host
  end
end
