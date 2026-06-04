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

  describe "source self-classification (no upstream ga_source)" do
    test "an event from an AI referrer is recorded with source_medium=ai" do
      conn =
        build_event_conn()
        |> Plug.Conn.put_req_header("referer", "https://chatgpt.com/")
        |> BeaconController.event(%{
          "event_type" => "pageview",
          "anonymous_id" => "anon-ai-#{System.unique_integer([:positive])}",
          "url" => "https://site.test/jobs"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.source_medium == "ai"
      assert event.source_platform == "chatgpt"
    end
  end

  describe "beacon debug logging (opt-in)" do
    import ExUnit.CaptureLog

    setup do
      prev = Application.get_env(:good_analytics, :debug_beacon)
      prev_level = Logger.level()
      # Core's test env filters to :warning; the diagnostic logs at :info.
      Logger.configure(level: :info)

      on_exit(fn ->
        Logger.configure(level: prev_level)
        restore_env(:debug_beacon, prev)
      end)

      :ok
    end

    defp restore_env(key, nil), do: Application.delete_env(:good_analytics, key)
    defp restore_env(key, value), do: Application.put_env(:good_analytics, key, value)

    test "stays silent by default" do
      Application.delete_env(:good_analytics, :debug_beacon)

      log =
        capture_log(fn ->
          BeaconController.event(build_event_conn(), %{
            "event_type" => "pageview",
            "anonymous_id" => "anon-quiet-#{System.unique_integer([:positive])}",
            "url" => "https://site.test/jobs"
          })
        end)

      refute log =~ "ga_beacon"
    end

    test "logs header/body/source views when enabled" do
      Application.put_env(:good_analytics, :debug_beacon, true)

      log =
        capture_log([level: :info], fn ->
          build_event_conn()
          |> Plug.Conn.put_req_header("referer", "https://www.google.com/")
          |> BeaconController.event(%{
            "event_type" => "custom",
            "event_name" => "apply_click",
            "anonymous_id" => "anon-debug-#{System.unique_integer([:positive])}",
            "url" => "https://site.test/jobs/123?utm_source=newsletter",
            "referrer" => "https://www.google.com/",
            "properties" => %{"job_id" => "abc"}
          })
        end)

      assert log =~ "ga_beacon endpoint=event"
      # JS-body view is captured intact (this is the data a CDN rewrite can't strip).
      assert log =~ ~s(body_event_name="apply_click")
      assert log =~ "utm_source=newsletter"
      # body_keys distinguishes "body did not parse" from "headers stripped".
      assert log =~ "body_keys="
      # Header view and computed source are present for comparison.
      assert log =~ "hdr_ua="
      assert log =~ "source_assigned=false"
      assert log =~ "source="
    end
  end

  describe "anonymous_id validation" do
    alias GoodAnalytics.Core.Visitors.Visitor

    test "an over-long anonymous_id is dropped while a normal one is stored" do
      long = String.duplicate("a", 200)
      ok = "anon_" <> Integer.to_string(System.unique_integer([:positive]))

      build_event_conn()
      |> BeaconController.event(%{
        "event_type" => "pageview",
        "anonymous_id" => long,
        "url" => "https://site.test/jobs"
      })

      build_event_conn()
      |> BeaconController.event(%{
        "event_type" => "pageview",
        "anonymous_id" => ok,
        "url" => "https://site.test/jobs"
      })

      repo = GoodAnalytics.Repo.repo()

      assert repo.exists?(
               from(v in Visitor,
                 where: fragment("? @> ARRAY[?]::text[]", v.anonymous_ids, ^ok)
               ),
               prefix: "good_analytics"
             )

      refute repo.exists?(
               from(v in Visitor,
                 where: fragment("? @> ARRAY[?]::text[]", v.anonymous_ids, ^long)
               ),
               prefix: "good_analytics"
             )
    end
  end

  describe "event_name persistence" do
    test "persists the JS-supplied event_name for a custom beacon event" do
      build_event_conn()
      |> BeaconController.event(%{
        "event_type" => "custom",
        "event_name" => "apply_click",
        "anonymous_id" => "anon-en-#{System.unique_integer([:positive])}",
        "url" => "https://site.test/jobs/x",
        "properties" => %{"job_id" => "job-123"}
      })

      event = latest_event()
      assert event.event_type == "custom"
      assert event.event_name == "apply_click"
      assert event.properties["job_id"] == "job-123"
    end

    test "drops an over-long event_name" do
      build_event_conn()
      |> BeaconController.event(%{
        "event_type" => "custom",
        "event_name" => String.duplicate("x", 200),
        "anonymous_id" => "anon-en2-#{System.unique_integer([:positive])}",
        "url" => "https://site.test/jobs/x"
      })

      assert latest_event().event_name == nil
    end
  end
end
