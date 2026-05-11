defmodule GoodAnalytics.Core.Tracking.PlugTest do
  use ExUnit.Case, async: true
  import Plug.Test

  alias GoodAnalytics.Core.Tracking.Plug, as: TrackingPlug

  describe "call/2" do
    test "skips non-trackable requests (static assets)" do
      conn = conn(:get, "/assets/app.js")
      result = TrackingPlug.call(conn, TrackingPlug.init([]))
      refute Map.has_key?(result.assigns, :ga_signals)
    end

    test "skips non-GET requests" do
      conn = conn(:post, "/api/data")
      result = TrackingPlug.call(conn, TrackingPlug.init([]))
      refute Map.has_key?(result.assigns, :ga_signals)
    end

    test "sets referrer-policy header on trackable requests" do
      conn =
        conn(:get, "/pricing")
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.fetch_query_params()

      result = TrackingPlug.call(conn, TrackingPlug.init([]))

      assert Plug.Conn.get_resp_header(result, "referrer-policy") == [
               "no-referrer-when-downgrade"
             ]
    end

    test "assigns ga_signals on trackable requests" do
      conn =
        conn(:get, "/pricing")
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.fetch_query_params()

      result = TrackingPlug.call(conn, TrackingPlug.init([]))
      assert Map.has_key?(result.assigns, :ga_signals)
      assert Map.has_key?(result.assigns, :ga_source)
    end

    test "generates anonymous ID when no cookie present" do
      conn =
        conn(:get, "/pricing")
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.fetch_query_params()

      result = TrackingPlug.call(conn, TrackingPlug.init([]))
      assert is_binary(result.assigns[:ga_anon_id])
    end

    test "reads ga_id from query params" do
      valid_uuid = Uniq.UUID.uuid7()

      conn =
        conn(:get, "/pricing?ga_id=#{valid_uuid}")
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.fetch_query_params()

      result = TrackingPlug.call(conn, TrackingPlug.init([]))
      assert result.assigns[:ga_id] == valid_uuid
    end

    test "rejects invalid ga_id from query params" do
      conn =
        conn(:get, "/pricing?ga_id=not-a-uuid")
        |> Plug.Conn.fetch_cookies()
        |> Plug.Conn.fetch_query_params()

      result = TrackingPlug.call(conn, TrackingPlug.init([]))
      assert is_nil(result.assigns[:ga_id])
    end
  end

  describe "init/1" do
    test "passes through opts" do
      assert TrackingPlug.init(foo: :bar) == [foo: :bar]
    end
  end
end
