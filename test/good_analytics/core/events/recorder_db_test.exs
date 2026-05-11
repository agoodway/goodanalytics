defmodule GoodAnalytics.Core.Events.RecorderDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.{Event, Recorder}

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
end
