defmodule GoodAnalytics.Core.Tracking.BeaconControllerTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Sessions
  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Core.Tracking.BeaconController
  alias GoodAnalytics.Core.Tracking.Router, as: TrackingRouter
  alias GoodAnalytics.Core.Visitors.Visitor

  import Ecto.Query
  import Plug.Test

  defp build_event_conn do
    conn(:post, "/ga/t/event")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("user-agent", "BeaconControllerTest/1.0")
    |> Plug.Conn.assign(:ga_source, nil)
    |> Plug.Conn.put_private(:phoenix_format, "json")
  end

  defp build_event_conn_with_cookie(cookie_value) do
    build_event_conn()
    |> put_req_cookie("_ga_anon", cookie_value)
    |> Plug.Conn.fetch_cookies()
  end

  defp build_click_conn(cookie_value) do
    conn =
      conn(:post, "/ga/t/click")
      |> Map.put(:host, "test.link")
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("user-agent", "BeaconControllerTest/1.0")
      |> Plug.Conn.assign(:ga_source, nil)
      |> Plug.Conn.put_private(:phoenix_format, "json")

    if cookie_value do
      conn
      |> put_req_cookie("_ga_anon", cookie_value)
      |> Plug.Conn.fetch_cookies()
    else
      conn
    end
  end

  defp routed_event_conn(payload, cookie_value) do
    payload
    |> routed_conn("/event", cookie_value)
    |> then(&TrackingRouter.call(&1, TrackingRouter.init([])))
  end

  defp routed_click_conn(payload, cookie_value) do
    payload
    |> routed_conn("/click", cookie_value)
    |> Map.put(:host, "test.link")
    |> then(&TrackingRouter.call(&1, TrackingRouter.init([])))
  end

  defp routed_conn(payload, path, cookie_value) do
    conn =
      conn(:post, path, Jason.encode!(payload))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("user-agent", "BeaconControllerTest/1.0")

    if cookie_value, do: put_req_cookie(conn, "_ga_anon", cookie_value), else: conn
  end

  defp visitor_with_anon_id?(anon_id) do
    GoodAnalytics.Repo.repo().exists?(
      from(v in Visitor,
        where: fragment("? @> ARRAY[?]::text[]", v.anonymous_ids, ^anon_id)
      ),
      prefix: "good_analytics"
    )
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

    test "forwards engagement metrics from top-level SDK payload" do
      visitor = create_visitor!(%{anonymous_ids: ["anon-engagement-controller"]})

      {:ok, pageview_session} =
        Sessions.sessionize(
          %{workspace_id: GoodAnalytics.default_workspace_id(), visitor_id: visitor.id},
          "pageview",
          %{path: "/pricing", __ts__: utc_now()}
        )

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "engagement",
          "anonymous_id" => "anon-engagement-controller",
          "url" => "https://example.com/pricing",
          "engaged_ms" => 12_000,
          "scroll_depth" => 80
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.event_type == "engagement"
      assert event.session_id == pageview_session.id
      assert event.properties["engaged_ms"] == 12_000
      assert event.properties["scroll_depth"] == 80

      session =
        GoodAnalytics.TestRepo.get!(Session, pageview_session.id, prefix: "good_analytics")

      assert session.engaged_seconds == 12
    end

    test "drops engagement for unknown visitors without creating identity or event rows" do
      before_visitors =
        GoodAnalytics.TestRepo.aggregate(Visitor, :count, :id, prefix: "good_analytics")

      before_events =
        GoodAnalytics.TestRepo.aggregate(Event, :count, :id, prefix: "good_analytics")

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "engagement",
          "anonymous_id" => "unknown-engagement-controller",
          "url" => "https://example.com/pricing",
          "engaged_ms" => 12_000,
          "scroll_depth" => 80
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      assert GoodAnalytics.TestRepo.aggregate(Visitor, :count, :id, prefix: "good_analytics") ==
               before_visitors

      assert GoodAnalytics.TestRepo.aggregate(Event, :count, :id, prefix: "good_analytics") ==
               before_events
    end

    test "drops ambiguous engagement when existing signals resolve to multiple visitors" do
      ga_visitor = create_visitor!(%{ga_id: "ga-ambiguous-engagement"})
      anon_visitor = create_visitor!(%{anonymous_ids: ["anon-ambiguous-engagement"]})

      {:ok, anon_session} =
        Sessions.sessionize(
          %{workspace_id: GoodAnalytics.default_workspace_id(), visitor_id: anon_visitor.id},
          "pageview",
          %{path: "/pricing", __ts__: utc_now()}
        )

      assert [_candidate_1, _candidate_2] =
               IdentityResolver.find_candidates(
                 %{
                   ga_id: ga_visitor.ga_id,
                   anonymous_id: "anon-ambiguous-engagement"
                 },
                 GoodAnalytics.default_workspace_id()
               )

      before_events =
        GoodAnalytics.TestRepo.aggregate(Event, :count, :id, prefix: "good_analytics")

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "engagement",
          "ga_id" => ga_visitor.ga_id,
          "anonymous_id" => "anon-ambiguous-engagement",
          "url" => "https://example.com/pricing",
          "engaged_ms" => 12_000,
          "scroll_depth" => 80
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      assert GoodAnalytics.TestRepo.aggregate(Event, :count, :id, prefix: "good_analytics") ==
               before_events

      session = GoodAnalytics.TestRepo.get!(Session, anon_session.id, prefix: "good_analytics")
      assert session.engaged_seconds == 0
    end

    test "caps oversized engagement duration before recording" do
      visitor = create_visitor!(%{anonymous_ids: ["anon-engagement-cap"]})

      {:ok, pageview_session} =
        Sessions.sessionize(
          %{workspace_id: GoodAnalytics.default_workspace_id(), visitor_id: visitor.id},
          "pageview",
          %{path: "/pricing", __ts__: utc_now()}
        )

      conn =
        BeaconController.event(build_event_conn(), %{
          "event_type" => "engagement",
          "anonymous_id" => "anon-engagement-cap",
          "url" => "https://example.com/pricing",
          "engaged_ms" => 9_999_999_999,
          "scroll_depth" => 80
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.properties["engaged_ms"] == 30 * 60 * 1000

      session =
        GoodAnalytics.TestRepo.get!(Session, pageview_session.id, prefix: "good_analytics")

      assert session.engaged_seconds == 30 * 60
    end
  end

  describe "source self-classification (no upstream ga_source)" do
    # A beacon is a fetch FROM the page, so the request Referer header is always
    # the current page (a self-referral) and the request query string is empty.
    # The real attribution signals live in the JS body (url + document.referrer),
    # which is the one view that is identical across any host (Astro, PHP,
    # core-direct) and survives a CDN/edge rewrite. These tests pin the header to
    # the page itself to prove classification reads the body, not the envelope.
    test "classifies from the JS body referrer, not the request Referer header" do
      conn =
        build_event_conn()
        |> Plug.Conn.put_req_header("referer", "https://site.test/jobs")
        |> BeaconController.event(%{
          "event_type" => "pageview",
          "anonymous_id" => "anon-ai-#{System.unique_integer([:positive])}",
          "url" => "https://site.test/jobs",
          "referrer" => "https://chatgpt.com/"
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.source_medium == "ai"
      assert event.source_platform == "chatgpt"
    end

    test "an empty body referrer is direct, even when the header referer is the page" do
      conn =
        build_event_conn()
        |> Plug.Conn.put_req_header("referer", "https://www.jobsinappraisal.com/jobs/x")
        |> BeaconController.event(%{
          "event_type" => "pageview",
          "anonymous_id" => "anon-direct-#{System.unique_integer([:positive])}",
          "url" => "https://www.jobsinappraisal.com/jobs/x",
          "referrer" => ""
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert latest_event().source_medium == "direct"
    end

    test "classifies UTM params from the JS body url query string" do
      conn =
        build_event_conn()
        |> Plug.Conn.put_req_header("referer", "https://site.test/landing")
        |> BeaconController.event(%{
          "event_type" => "pageview",
          "anonymous_id" => "anon-utm-#{System.unique_integer([:positive])}",
          "url" => "https://site.test/landing?utm_source=newsletter&utm_medium=email",
          "referrer" => ""
        })

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.source_medium == "email"
      assert event.source_platform == "newsletter"
    end
  end

  describe "anonymous_id cookie fallback" do
    test "routed pageview resolves anonymous_id from _ga_anon cookie when body omits it" do
      anon_id = "anon-cookie-only-#{System.unique_integer([:positive])}"

      conn =
        routed_event_conn(
          %{
            "event_type" => "pageview",
            "url" => "https://example.com/pricing"
          },
          anon_id
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert visitor_with_anon_id?(anon_id)

      event = latest_event()
      assert event.event_type == "pageview"
      assert event.url == "https://example.com/pricing"
    end

    test "body anonymous_id takes precedence over _ga_anon cookie" do
      body_anon = "anon-body-#{System.unique_integer([:positive])}"
      cookie_anon = "anon-cookie-#{System.unique_integer([:positive])}"

      conn =
        BeaconController.event(
          build_event_conn_with_cookie(cookie_anon),
          %{
            "event_type" => "pageview",
            "anonymous_id" => body_anon,
            "url" => "https://example.com/pricing"
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert visitor_with_anon_id?(body_anon)
      refute visitor_with_anon_id?(cookie_anon)
    end

    test "overlong _ga_anon cookie is ignored without error" do
      long = String.duplicate("a", 200)

      conn =
        BeaconController.event(
          build_event_conn_with_cookie(long),
          %{
            "event_type" => "pageview",
            "url" => "https://example.com/pricing"
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      refute visitor_with_anon_id?(long)
    end

    test "invalid body anonymous_id falls back to valid _ga_anon cookie" do
      cookie_anon = "anon-cookie-fallback-#{System.unique_integer([:positive])}"
      long = String.duplicate("a", 200)

      conn =
        BeaconController.event(
          build_event_conn_with_cookie(cookie_anon),
          %{
            "event_type" => "pageview",
            "anonymous_id" => long,
            "url" => "https://example.com/pricing"
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert visitor_with_anon_id?(cookie_anon)
      refute visitor_with_anon_id?(long)
    end

    test "empty-string body anonymous_id falls back to valid _ga_anon cookie" do
      cookie_anon = "anon-empty-body-#{System.unique_integer([:positive])}"

      conn =
        BeaconController.event(
          build_event_conn_with_cookie(cookie_anon),
          %{
            "event_type" => "pageview",
            "anonymous_id" => "",
            "url" => "https://example.com/pricing"
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert visitor_with_anon_id?(cookie_anon)
    end

    test "whitespace-only body anonymous_id falls back to valid _ga_anon cookie" do
      cookie_anon = "anon-ws-body-#{System.unique_integer([:positive])}"

      conn =
        BeaconController.event(
          build_event_conn_with_cookie(cookie_anon),
          %{
            "event_type" => "pageview",
            "anonymous_id" => "   ",
            "url" => "https://example.com/pricing"
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      assert visitor_with_anon_id?(cookie_anon)
    end

    test "empty _ga_anon cookie value is treated as absent" do
      conn =
        BeaconController.event(
          build_event_conn_with_cookie(""),
          %{
            "event_type" => "pageview",
            "url" => "https://example.com/pricing"
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)
      refute visitor_with_anon_id?("")
    end

    test "engagement beacon resolves visitor via cookie when body omits anonymous_id" do
      anon_id = "anon-engagement-cookie-#{System.unique_integer([:positive])}"
      visitor = create_visitor!(%{anonymous_ids: [anon_id]})

      {:ok, pageview_session} =
        Sessions.sessionize(
          %{workspace_id: GoodAnalytics.default_workspace_id(), visitor_id: visitor.id},
          "pageview",
          %{path: "/pricing", __ts__: DateTime.utc_now()}
        )

      conn =
        BeaconController.event(
          build_event_conn_with_cookie(anon_id),
          %{
            "event_type" => "engagement",
            "url" => "https://example.com/pricing",
            "engaged_ms" => 5_000,
            "scroll_depth" => 50
          }
        )

      assert %{"status" => "ok"} = Jason.decode!(conn.resp_body)

      event = latest_event()
      assert event.event_type == "engagement"
      # The event has no anonymous_id column; the cookie fallback is proven by the
      # engagement attaching to the pageview's session, which is only reachable by
      # resolving the cookie-sourced anonymous_id back to `visitor`.
      assert event.session_id == pageview_session.id
    end

    test "click beacon resolves visitor via cookie when body omits anonymous_id" do
      anon_id = "anon-click-cookie-#{System.unique_integer([:positive])}"

      link =
        create_link!(%{
          domain: "test.link",
          key: "cookie_click_#{System.unique_integer([:positive])}"
        })

      conn =
        BeaconController.click(
          build_click_conn(anon_id),
          %{"key" => link.key, "fingerprint" => "fp_cookie_click"}
        )

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["visitor_id"]

      visitor =
        GoodAnalytics.TestRepo.get!(Visitor, body["visitor_id"], prefix: "good_analytics")

      assert anon_id in visitor.anonymous_ids
    end

    test "click body anonymous_id takes precedence over _ga_anon cookie" do
      body_anon = "anon-click-body-#{System.unique_integer([:positive])}"
      cookie_anon = "anon-click-cookie-#{System.unique_integer([:positive])}"

      link =
        create_link!(%{
          domain: "test.link",
          key: "click_precedence_#{System.unique_integer([:positive])}"
        })

      conn =
        BeaconController.click(
          build_click_conn(cookie_anon),
          %{
            "key" => link.key,
            "anonymous_id" => body_anon,
            "fingerprint" => "fp_click_precedence"
          }
        )

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert visitor_with_anon_id?(body_anon)
      refute visitor_with_anon_id?(cookie_anon)
    end

    test "routed click resolves anonymous_id from _ga_anon cookie through the router pipeline" do
      anon_id = "anon-routed-click-#{System.unique_integer([:positive])}"

      link =
        create_link!(%{
          domain: "test.link",
          key: "routed_click_#{System.unique_integer([:positive])}"
        })

      conn =
        routed_click_conn(
          %{"key" => link.key, "fingerprint" => "fp_routed_click"},
          anon_id
        )

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert body["visitor_id"]
      assert visitor_with_anon_id?(anon_id)
    end
  end

  describe "anonymous_id validation" do
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
