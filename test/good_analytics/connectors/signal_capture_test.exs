defmodule GoodAnalytics.Connectors.SignalCaptureTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.Signals

  describe "extract_from_conn/1 — request path signal capture" do
    test "extracts click IDs from query params" do
      conn =
        Plug.Test.conn(:get, "/?fbclid=abc123&gclid=def456")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:cookies, %{})

      signals = Signals.extract_from_conn(conn)
      assert signals["fbclid"] == "abc123"
      assert signals["gclid"] == "def456"
    end

    test "extracts browser identifiers from cookies" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:cookies, %{
          "_fbp" => "fb.1.1234567890.1234567890",
          "_fbc" => "fb.1.1234567890.abc123"
        })

      signals = Signals.extract_from_conn(conn)
      assert signals["_fbp"] == "fb.1.1234567890.1234567890"
      assert signals["_fbc"] == "fb.1.1234567890.abc123"
    end

    test "captures both click IDs and browser identifiers" do
      conn =
        Plug.Test.conn(:get, "/?fbclid=click1&li_fat_id=li123")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:cookies, %{"_fbp" => "fb.1.123"})

      signals = Signals.extract_from_conn(conn)
      assert signals["fbclid"] == "click1"
      assert signals["li_fat_id"] == "li123"
      assert signals["_fbp"] == "fb.1.123"
    end

    test "returns empty map when no signals present" do
      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:cookies, %{})

      assert Signals.extract_from_conn(conn) == %{}
    end

    test "captures all recognized click ID params" do
      params = "?gbraid=gb1&wbraid=wb1&li_fat_id=li1&ttclid=tt1"

      conn =
        Plug.Test.conn(:get, "/" <> params)
        |> Plug.Conn.fetch_query_params()
        |> Map.put(:cookies, %{})

      signals = Signals.extract_from_conn(conn)
      assert signals["gbraid"] == "gb1"
      assert signals["wbraid"] == "wb1"
      assert signals["li_fat_id"] == "li1"
      assert signals["ttclid"] == "tt1"
    end
  end

  describe "extract_from_payload/1 — JavaScript path signal capture" do
    test "extracts browser identifiers from beacon payload" do
      payload = %{
        "_fbp" => "fb.1.1234567890.1234567890",
        "_fbc" => "fb.1.1234567890.abc123",
        "event_type" => "pageview",
        "url" => "https://example.com"
      }

      signals = Signals.extract_from_payload(payload)
      assert signals["_fbp"] == "fb.1.1234567890.1234567890"
      assert signals["_fbc"] == "fb.1.1234567890.abc123"
      refute Map.has_key?(signals, "event_type")
    end

    test "extracts click IDs from beacon payload" do
      payload = %{"fbclid" => "abc123", "gclid" => "def456"}
      signals = Signals.extract_from_payload(payload)
      assert signals["fbclid"] == "abc123"
      assert signals["gclid"] == "def456"
    end
  end

  describe "merge/1 — signal merging" do
    test "JS-supplied values override server-captured values" do
      server = %{"_fbp" => "fb.1.old", "fbclid" => "click1"}
      js = %{"_fbp" => "fb.1.new", "_fbc" => "fb.1.abc"}

      merged = Signals.merge([server, js])
      assert merged["_fbp"] == "fb.1.new"
      assert merged["fbclid"] == "click1"
      assert merged["_fbc"] == "fb.1.abc"
    end
  end
end
