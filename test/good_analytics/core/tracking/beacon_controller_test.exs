defmodule GoodAnalytics.Core.Tracking.BeaconControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Tracking.BeaconController

  import Plug.Test

  defp build_event_conn do
    conn(:post, "/ga/t/event")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("user-agent", "BeaconControllerTest/1.0")
    |> Plug.Conn.assign(:ga_source, nil)
    |> Plug.Conn.put_private(:phoenix_format, "json")
  end

  defp latest_event do
    GoodAnalytics.Repo.repo().one!(
      from(e in Event, order_by: [desc: e.inserted_at], limit: 1),
      prefix: "good_analytics"
    )
  end

  describe "event/2" do
    test "accepts event_id without using it as ga_events.id" do
      event_id = Ecto.UUID.generate()

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "event_id" => event_id,
          "anonymous_id" => "anon-event-id",
          "url" => "https://example.com/pricing"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.event_type == "pageview"
      assert event.url == "https://example.com/pricing"
      refute event.id == event_id
    end

    test "accepts payloads without event_id" do
      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "pageview",
          "anonymous_id" => "anon-without-event-id",
          "url" => "https://example.com/docs"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.event_type == "pageview"
      assert event.url == "https://example.com/docs"
      assert {:ok, _} = Ecto.UUID.cast(event.id)
    end
  end
end
