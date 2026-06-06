defmodule GoodAnalytics.Api.AnalyticsControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Api.Router
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Sessions.Session

  @workspace_id GoodAnalytics.default_workspace_id()

  setup do
    Application.put_env(:good_analytics, :api_authenticate, fn _token, _type ->
      {:ok, %{workspace_id: @workspace_id}}
    end)

    on_exit(fn -> Application.delete_env(:good_analytics, :api_authenticate) end)
    :ok
  end

  defp api_conn(method, path, auth? \\ true) do
    conn = Plug.Test.conn(method, path)
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")

    conn =
      if auth?,
        do: Plug.Conn.put_req_header(conn, "authorization", "Bearer test-token"),
        else: conn

    Router.call(conn, Router.init([]))
  end

  defp json_body(conn), do: Jason.decode!(conn.resp_body)

  # Direct Event insert so explicit device columns and inserted_at survive
  # (Recorder.record/3 drops device fields and ignores inserted_at). Mirrors
  # audience_test.exs.
  defp seed_event!(visitor, event_type, attrs) do
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at, seed_clock())
    {path, attrs} = Map.pop(attrs, :path, "/p")

    base = %{
      workspace_id: @workspace_id,
      visitor_id: visitor.id,
      event_type: event_type,
      url: "https://x.test#{path}",
      path: path
    }

    %Event{id: Uniq.UUID.uuid7(), inserted_at: inserted_at}
    |> Event.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
  end

  defp seed_clock do
    n = System.unique_integer([:positive, :monotonic])
    DateTime.add(~U[2026-06-15 12:00:00.000000Z], n, :microsecond)
  end

  describe "GET /analytics/breakdown — auth" do
    test "401 without credentials" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z",
          false
        )

      assert conn.status == 401
    end

    test "200 with valid params returns a breakdown envelope" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=events"
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["dimension"] == "device_type"
      assert is_list(body["rows"])
    end
  end

  describe "GET /analytics/breakdown — data" do
    test "buckets events by device_type" do
      d1 = create_visitor!()
      seed_event!(d1, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(d1, "pageview", %{path: "/b", device_type: "desktop"})

      m1 = create_visitor!()
      seed_event!(m1, "pageview", %{path: "/c", device_type: "mobile"})

      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=events,users"
        )

      assert conn.status == 200
      rows = Map.new(json_body(conn)["rows"], &{&1["value"], &1})

      assert rows["desktop"]["events"] == 2
      assert rows["desktop"]["users"] == 1
      assert rows["mobile"]["events"] == 1
    end

    test "422 on an unknown dimension" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=nonsense&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z"
        )

      assert conn.status == 422
    end

    test "422 on an unknown metric" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=bogus"
        )

      assert conn.status == 422
    end

    test "422 on a malformed date" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=not-a-date&to=2026-06-30T00:00:00Z"
        )

      assert conn.status == 422
    end

    test "422 when country is combined with a session metric" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=country&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=sessions"
        )

      assert conn.status == 422
    end

    test "filter drills down to a single dimension value" do
      v = create_visitor!()
      seed_event!(v, "pageview", %{path: "/a", device_type: "desktop", browser: "Chrome"})
      seed_event!(v, "pageview", %{path: "/b", device_type: "mobile", browser: "Safari"})

      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=browser&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=events&filter=device_type:desktop"
        )

      assert conn.status == 200
      rows = Map.new(json_body(conn)["rows"], &{&1["value"], &1})
      assert rows["Chrome"]["events"] == 1
      assert rows["Safari"] == nil
    end
  end

  describe "GET /analytics/timeseries" do
    test "buckets pageviews per hour with zero-fill" do
      v = create_visitor!()
      seed_event!(v, "pageview", %{path: "/a", inserted_at: ~U[2026-06-10 00:15:00.000000Z]})
      seed_event!(v, "pageview", %{path: "/b", inserted_at: ~U[2026-06-10 00:45:00.000000Z]})

      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2026-06-10T00:00:00Z&to=2026-06-10T02:00:00Z&interval=1h"
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["metric"] == "pageviews"
      assert body["interval"] == "1h"
      points = body["points"]
      assert length(points) == 2
      assert Enum.at(points, 0)["value"] == 2
      assert Enum.at(points, 1)["value"] == 0
      assert Enum.at(points, 0)["bucket_start"]
    end

    test "echoes the resolved interval label when none is requested" do
      v = create_visitor!()
      seed_event!(v, "pageview", %{path: "/a", inserted_at: ~U[2026-06-10 00:15:00.000000Z]})

      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2026-06-10T00:00:00Z&to=2026-06-10T02:00:00Z"
        )

      assert conn.status == 200
      assert is_binary(json_body(conn)["interval"])
    end

    test "422 on an unsupported metric" do
      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=bogus&from=2026-06-10T00:00:00Z&to=2026-06-10T02:00:00Z"
        )

      assert conn.status == 422
    end
  end

  describe "GET /analytics/breakdown — validation" do
    # W1 — silent session-filter drop now rejected
    test "422 when a session-less dimension filter is combined with session metrics" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=sessions&filter=country:US"
        )

      assert conn.status == 422
    end
  end

  describe "GET /analytics/timeseries — validation" do
    # W2 — invalid timezone -> 422 (not 500)
    test "422 on an invalid timezone" do
      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2026-06-10T00:00:00Z&to=2026-06-10T02:00:00Z&interval=1h&timezone=Not/AZone"
        )

      assert conn.status == 422
    end

    # W3 — from >= to rejected
    test "422 when from is not before to" do
      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2026-06-10T02:00:00Z&to=2026-06-10T00:00:00Z&interval=1h"
        )

      assert conn.status == 422
    end

    # W3 — bucket cap
    test "422 when interval is too small for the window (bucket cap)" do
      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2020-01-01T00:00:00Z&to=2026-01-01T00:00:00Z&interval=1m"
        )

      assert conn.status == 422
    end

    # W3-interval — unknown interval rejected by the enum
    test "422 on an unknown interval label" do
      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2026-06-10T00:00:00Z&to=2026-06-10T02:00:00Z&interval=bogus"
        )

      assert conn.status == 422
    end
  end

  defp insert_session!(attrs) do
    now = ~U[2026-06-10 12:00:00.000000Z]

    base = %{
      workspace_id: @workspace_id,
      visitor_id: Uniq.UUID.uuid7(),
      started_at: now,
      last_event_at: now
    }

    %Session{id: Uniq.UUID.uuid7()}
    |> Session.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
  end

  describe "GET /analytics/breakdown — session-grain metrics" do
    test "returns float session metrics for a bucket with a session and null for one without" do
      # desktop: an event + a session (so it has both event and session grain)
      d = create_visitor!()
      seed_event!(d, "pageview", %{path: "/a", device_type: "desktop"})

      insert_session!(%{
        device_type: "desktop",
        is_bounce: false,
        is_engaged: true,
        duration_seconds: 30
      })

      # mobile: an event but NO session
      m = create_visitor!()
      seed_event!(m, "pageview", %{path: "/b", device_type: "mobile"})

      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=events,sessions,bounce_rate,avg_duration,engaged_rate"
        )

      assert conn.status == 200
      rows = Map.new(json_body(conn)["rows"], &{&1["value"], &1})

      # desktop bucket has a session → numeric (not stringified/Decimal-object) floats
      assert rows["desktop"]["sessions"] == 1
      assert is_number(rows["desktop"]["bounce_rate"])
      assert is_number(rows["desktop"]["avg_duration"])
      assert is_number(rows["desktop"]["engaged_rate"])

      # mobile bucket has no session → JSON null for session-grain metrics
      assert rows["mobile"]["events"] == 1
      assert rows["mobile"]["bounce_rate"] == nil
      assert rows["mobile"]["sessions"] == nil
    end
  end

  describe "GET /analytics/breakdown — defaults & ordering" do
    test "country with no metrics param defaults to events and succeeds" do
      v = create_visitor!()
      seed_event!(v, "pageview", %{path: "/a"})

      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=country&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z"
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["dimension"] == "country"
      assert body["metrics"] == ["events"]
    end

    test "order=asc with limit returns the smallest bucket first" do
      desk = create_visitor!()
      seed_event!(desk, "pageview", %{path: "/a", device_type: "desktop"})
      seed_event!(desk, "pageview", %{path: "/b", device_type: "desktop"})
      mob = create_visitor!()
      seed_event!(mob, "pageview", %{path: "/c", device_type: "mobile"})

      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&metrics=events&order=asc&limit=1"
        )

      assert conn.status == 200
      rows = json_body(conn)["rows"]
      assert length(rows) == 1
      assert hd(rows)["value"] == "mobile"
    end

    test "empty window still returns the metrics array" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=device_type&from=2099-01-01T00:00:00Z&to=2099-02-01T00:00:00Z"
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["rows"] == []
      assert body["metrics"] == ["events"]
    end
  end

  describe "GET /analytics/breakdown — invalid filter" do
    test "422 on a filter with no colon" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=browser&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&filter=nocolon"
        )

      assert conn.status == 422
    end

    test "422 on a filter with an empty value" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=browser&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&filter=device_type:"
        )

      assert conn.status == 422
    end

    test "422 on a filter with an unknown dimension" do
      conn =
        api_conn(
          :get,
          "/analytics/breakdown?dimension=browser&from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z&filter=unknown:x"
        )

      assert conn.status == 422
    end
  end

  describe "GET /analytics/timeseries — timezone wiring" do
    test "accepts a valid IANA timezone and returns buckets" do
      v = create_visitor!()
      seed_event!(v, "pageview", %{path: "/a", inserted_at: ~U[2026-06-10 00:15:00.000000Z]})

      conn =
        api_conn(
          :get,
          "/analytics/timeseries?metric=pageviews&from=2026-06-10T00:00:00Z&to=2026-06-10T02:00:00Z&interval=1h&timezone=America/New_York"
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["interval"] == "1h"
      assert is_list(body["points"])
      assert length(body["points"]) == 2
    end
  end

  describe "GET /analytics/summary" do
    test "returns KPI counts for the window" do
      v1 = create_visitor!(%{first_seen_at: ~U[2026-06-10 00:00:00.000000Z]})
      seed_event!(v1, "pageview", %{path: "/a"})
      seed_event!(v1, "pageview", %{path: "/b"})
      seed_event!(v1, "sale", %{path: "/buy", amount_cents: 5000})

      conn =
        api_conn(
          :get,
          "/analytics/summary?from=2026-06-01T00:00:00Z&to=2026-06-30T00:00:00Z"
        )

      assert conn.status == 200
      body = json_body(conn)
      assert body["visitors"] == 1
      assert body["pageviews"] == 2
      assert body["revenue"] == 5000
      assert Map.has_key?(body, "identification_rate")
      assert Map.has_key?(body, "sessions")
    end

    test "422 on a missing date range" do
      conn = api_conn(:get, "/analytics/summary?from=2026-06-01T00:00:00Z")
      assert conn.status == 422
    end
  end
end
