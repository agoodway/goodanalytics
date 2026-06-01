defmodule GoodAnalytics.Core.Events.RecorderDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.{Event, Recorder}
  alias GoodAnalytics.Core.Visitors

  describe "record/3" do
    test "inserts event with workspace_id and visitor_id from visitor" do
      visitor = create_visitor!()

      assert {:ok, %Event{} = event} =
               Recorder.record(visitor, "pageview", %{url: "https://test.com"})

      assert event.workspace_id == visitor.workspace_id
      assert event.visitor_id == visitor.id
      assert event.event_type == "pageview"
      assert {:ok, _} = Ecto.UUID.cast(event.id)
    end

    test "promotes source classification fields" do
      visitor = create_visitor!()

      assert {:ok, event} =
               Recorder.record(visitor, "pageview", %{
                 source: %{platform: "google", medium: "organic", campaign: "spring"}
               })

      assert event.source_platform == "google"
      assert event.source_medium == "organic"
      assert event.source_campaign == "spring"
    end

    test "broadcasts recorded events on the workspace topic" do
      visitor = create_visitor!()

      Phoenix.PubSub.subscribe(
        GoodAnalytics.PubSub,
        "good_analytics:events:#{visitor.workspace_id}"
      )

      assert {:ok, event} = Recorder.record(visitor, "pageview", %{url: "https://test.com"})

      assert_receive {:event_recorded, ^event}
    end

    test "computes host and path from url" do
      visitor = create_visitor!()

      assert {:ok, event} =
               Recorder.record(visitor, "pageview", %{
                 url: "https://app.acme.com/pricing?utm_source=x#section"
               })

      assert event.host == "app.acme.com"
      assert event.path == "/pricing"
      assert event.url == "https://app.acme.com/pricing?utm_source=x#section"

      # Re-read from DB to verify columns are actually persisted
      db_event = Events.get_by_id(event.id)
      assert db_event.host == "app.acme.com"
      assert db_event.path == "/pricing"
    end

    test "handles trailing slash and duplicate slashes in url" do
      visitor = create_visitor!()

      {:ok, e1} = Recorder.record(visitor, "pageview", %{url: "https://acme.com/pricing/"})
      assert e1.path == "/pricing"

      {:ok, e2} = Recorder.record(visitor, "pageview", %{url: "https://acme.com/"})
      assert e2.path == "/"

      {:ok, e3} = Recorder.record(visitor, "pageview", %{url: "https://acme.com//docs///guide"})
      assert e3.path == "/docs/guide"
    end

    test "strips default ports from host" do
      visitor = create_visitor!()

      {:ok, e1} = Recorder.record(visitor, "pageview", %{url: "http://acme.com:80/x"})
      assert e1.host == "acme.com"

      {:ok, e2} = Recorder.record(visitor, "pageview", %{url: "https://acme.com:443/x"})
      assert e2.host == "acme.com"

      {:ok, e3} = Recorder.record(visitor, "pageview", %{url: "https://acme.com:8443/x"})
      assert e3.host == "acme.com:8443"
    end

    test "host is nil and path is / for explicit nil url" do
      visitor = create_visitor!()
      {:ok, event} = Recorder.record(visitor, "pageview", %{url: nil})
      assert event.host == nil
      assert event.path == "/"
    end

    test "normalizes host and path from string-keyed url attrs" do
      visitor = create_visitor!()

      {:ok, event} =
        Recorder.record(visitor, "pageview", %{"url" => "https://acme.com/pricing?utm=x"})

      assert event.host == "acme.com"
      assert event.path == "/pricing"
    end

    test "returns error changeset for invalid event_type" do
      visitor = create_visitor!()
      assert {:error, changeset} = Recorder.record(visitor, "invalid_type")
      assert errors_on(changeset)[:event_type]
    end

    test "stamps inserted_at on insert (composite PK requirement)" do
      visitor = create_visitor!()
      before_call = DateTime.utc_now()

      assert {:ok, event} = Recorder.record(visitor, "pageview", %{url: "https://test.com"})

      assert %DateTime{} = event.inserted_at
      assert DateTime.compare(event.inserted_at, before_call) in [:gt, :eq]
    end
  end

  describe "composite primary key (id, inserted_at)" do
    test "Events.get_by_id/1 retrieves an event by id alone" do
      visitor = create_visitor!()
      assert {:ok, event} = Recorder.record(visitor, "pageview", %{url: "https://test.com"})

      retrieved = Events.get_by_id(event.id)

      assert retrieved
      assert retrieved.id == event.id
      assert retrieved.inserted_at == event.inserted_at
    end

    test "get_by_id/1 returns nil for unknown id" do
      assert Events.get_by_id(Ecto.UUID.generate()) == nil
    end

    test "Event schema declares (id, inserted_at) as the composite primary key" do
      assert Event.__schema__(:primary_key) == [:id, :inserted_at]
    end
  end

  describe "record_click/3" do
    test "records link_click with link_id and click_id" do
      visitor = create_visitor!()
      link = create_link!()
      click_id = Uniq.UUID.uuid7()

      assert {:ok, event} = Recorder.record_click(visitor, link, %{click_id: click_id})
      assert event.event_type == "link_click"
      assert event.link_id == link.id
      assert event.click_id == click_id
    end

    test "qr=true sets properties.qr to true" do
      visitor = create_visitor!()
      link = create_link!()

      assert {:ok, event} =
               Recorder.record_click(visitor, link, %{click_id: Uniq.UUID.uuid7(), qr: true})

      assert event.properties["qr"] == true
    end

    test "qr=false omits qr from properties" do
      visitor = create_visitor!()
      link = create_link!()

      assert {:ok, event} =
               Recorder.record_click(visitor, link, %{click_id: Uniq.UUID.uuid7(), qr: false})

      refute Map.has_key?(event.properties, "qr")
    end

    test "absent qr omits qr from properties" do
      visitor = create_visitor!()
      link = create_link!()

      assert {:ok, event} =
               Recorder.record_click(visitor, link, %{click_id: Uniq.UUID.uuid7()})

      refute Map.has_key?(event.properties || %{}, "qr")
    end
  end

  describe "record_pageview/2" do
    test "records pageview event" do
      visitor = create_visitor!()
      assert {:ok, event} = Recorder.record_pageview(visitor, %{url: "https://test.com"})
      assert event.event_type == "pageview"
    end
  end

  describe "record_lead/2" do
    test "records lead event" do
      visitor = create_visitor!()
      assert {:ok, event} = Recorder.record_lead(visitor, %{})
      assert event.event_type == "lead"
    end
  end

  describe "record_sale/2" do
    test "records sale event with amount" do
      visitor = create_visitor!()
      assert {:ok, event} = Recorder.record_sale(visitor, %{amount_cents: 4900, currency: "USD"})
      assert event.event_type == "sale"
      assert event.amount_cents == 4900
      assert event.currency == "USD"
    end
  end

  describe "record_custom/3" do
    test "records custom event with event_name" do
      visitor = create_visitor!()
      assert {:ok, event} = Recorder.record_custom(visitor, "signup_completed", %{})
      assert event.event_type == "custom"
      assert event.event_name == "signup_completed"
    end
  end

  describe "backfill_link_click_fingerprint/2" do
    test "backfills fingerprint on link_click event" do
      visitor = create_visitor!()
      link = create_link!()
      click_id = Uniq.UUID.uuid7()
      {:ok, _event} = Recorder.record_click(visitor, link, %{click_id: click_id})

      assert {:ok, 1} = Recorder.backfill_link_click_fingerprint(click_id, "fp_new")

      # Verify it was set
      query =
        from(e in Event,
          where: e.click_id == type(^click_id, Ecto.UUID)
        )

      updated = GoodAnalytics.TestRepo.one(query, prefix: "good_analytics")

      assert updated.fingerprint == "fp_new"
    end

    test "does not overwrite existing fingerprint" do
      visitor = create_visitor!()
      link = create_link!()
      click_id = Uniq.UUID.uuid7()

      {:ok, _} =
        Recorder.record_click(visitor, link, %{click_id: click_id, fingerprint: "fp_original"})

      assert {:ok, 0} = Recorder.backfill_link_click_fingerprint(click_id, "fp_new")
    end

    test "returns {:ok, 0} for invalid click_id" do
      assert {:ok, 0} = Recorder.backfill_link_click_fingerprint("not-a-uuid", "fp_test")
    end
  end

  describe "device enrichment" do
    @desktop_ua "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " <>
                  "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    @iphone_ua "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) " <>
                 "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    test "populates visitor.device from the event user agent" do
      visitor = create_visitor!()

      assert {:ok, _event} =
               Recorder.record(visitor, "pageview", %{
                 url: "https://x.test",
                 user_agent: @desktop_ua
               })

      device = Visitors.get_visitor(visitor.id).device
      assert device["type"] == "desktop"
      assert device["browser"] == "Chrome"
    end

    test "does not overwrite device on a later event (first-event-wins)" do
      visitor = create_visitor!()

      {:ok, _} =
        Recorder.record(visitor, "pageview", %{url: "https://x.test", user_agent: @desktop_ua})

      {:ok, _} =
        Recorder.record(visitor, "pageview", %{url: "https://x.test", user_agent: @iphone_ua})

      assert Visitors.get_visitor(visitor.id).device["type"] == "desktop"
    end

    test "leaves device empty when the event has no user agent" do
      visitor = create_visitor!()
      {:ok, _} = Recorder.record(visitor, "pageview", %{url: "https://x.test"})
      assert Visitors.get_visitor(visitor.id).device == %{}
    end
  end
end
