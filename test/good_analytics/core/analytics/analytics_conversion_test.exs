defmodule GoodAnalytics.Core.AnalyticsConversionTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Analytics
  alias GoodAnalytics.Core.Events.Event

  @ws GoodAnalytics.default_workspace_id()

  defp window do
    %{start_at: ~U[2026-06-01 00:00:00.000000Z], end_at: ~U[2026-06-30 00:00:00.000000Z]}
  end

  defp fetch(rows, value), do: Enum.find(rows, &(&1.value == value))

  # Monotonic clock inside the window so each seeded row has a distinct inserted_at.
  defp seed_clock do
    n = System.unique_integer([:positive, :monotonic])
    DateTime.add(~U[2026-06-10 12:00:00.000000Z], n, :microsecond)
  end

  # Direct Event.changeset insert — preserves explicit device_type (Recorder
  # drops and re-derives it from user_agent, so it cannot be used here).
  defp seed_event!(visitor, event_type, attrs) do
    base = %{
      workspace_id: @ws,
      visitor_id: visitor.id,
      event_type: event_type,
      url: "https://x.test/buy",
      path: "/buy"
    }

    %Event{id: Uniq.UUID.uuid7(), inserted_at: seed_clock()}
    |> Event.changeset(Map.merge(base, attrs))
    |> GoodAnalytics.TestRepo.insert!(prefix: "good_analytics")
  end

  describe "conversion_breakdown/3" do
    test "buckets sale events by an event-grain dimension with sales/visitors/revenue" do
      buyer = create_visitor!()
      seed_event!(buyer, "sale", %{device_type: "desktop", amount_cents: 3000})
      seed_event!(buyer, "sale", %{device_type: "desktop", amount_cents: 1000})

      mobile_buyer = create_visitor!()
      seed_event!(mobile_buyer, "sale", %{device_type: "mobile", amount_cents: 2000})

      rows = Analytics.conversion_breakdown(@ws, :device_type, window: window())

      desktop = fetch(rows, "desktop")
      assert desktop.sales == 2
      assert desktop.visitors == 1
      assert desktop.revenue_cents == 4000

      mobile = fetch(rows, "mobile")
      assert mobile.sales == 1
      assert mobile.revenue_cents == 2000
    end

    test "conversion_rate is conversions over visitors when no sessions are present" do
      buyer = create_visitor!()
      # one converting visitor; one sale event
      seed_event!(buyer, "pageview", %{device_type: "desktop"})
      seed_event!(buyer, "sale", %{device_type: "desktop", amount_cents: 1000})

      rows = Analytics.conversion_breakdown(@ws, :device_type, window: window())
      desktop = fetch(rows, "desktop")

      # 1 conversion / 1 converting visitor = 1.0
      assert_in_delta desktop.conversion_rate, 1.0, 0.0001
    end

    test "raises ArgumentError on an unknown dimension" do
      assert_raise ArgumentError, fn ->
        Analytics.conversion_breakdown(@ws, :nonsense, window: window())
      end
    end
  end

  describe "conversion_breakdown/3 — filters" do
    test "an :eq filter narrows the breakdown to the matching source_platform" do
      google_buyer = create_visitor!()

      seed_event!(google_buyer, "sale", %{
        device_type: "desktop",
        source_platform: "google",
        amount_cents: 1000
      })

      seed_event!(google_buyer, "sale", %{
        device_type: "mobile",
        source_platform: "google",
        amount_cents: 2000
      })

      bing_buyer = create_visitor!()

      seed_event!(bing_buyer, "sale", %{
        device_type: "desktop",
        source_platform: "bing",
        amount_cents: 4000
      })

      rows =
        Analytics.conversion_breakdown(@ws, :device_type,
          window: window(),
          filters: [{:source_platform, :eq, "google"}]
        )

      desktop = fetch(rows, "desktop")
      assert desktop.sales == 1
      assert desktop.revenue_cents == 1000

      mobile = fetch(rows, "mobile")
      assert mobile.sales == 1
      assert mobile.revenue_cents == 2000
    end

    test "an :ilike filter escapes % as a literal" do
      literal_buyer = create_visitor!()

      seed_event!(literal_buyer, "sale", %{
        device_type: "desktop",
        source_campaign: "50%off",
        amount_cents: 1000
      })

      wildcard_buyer = create_visitor!()

      seed_event!(wildcard_buyer, "sale", %{
        device_type: "mobile",
        source_campaign: "50something",
        amount_cents: 2000
      })

      rows =
        Analytics.conversion_breakdown(@ws, :device_type,
          window: window(),
          filters: [{:source_campaign, :ilike, "50%"}]
        )

      # Only the literal "50%off" row matches; "50something" must NOT match
      # because the % is escaped to a literal rather than a wildcard.
      assert fetch(rows, "desktop").sales == 1
      assert fetch(rows, "mobile") == nil
    end

    test "an :in filter narrows to the given set" do
      g = create_visitor!()

      seed_event!(g, "sale", %{
        device_type: "desktop",
        source_platform: "google",
        amount_cents: 100
      })

      b = create_visitor!()
      seed_event!(b, "sale", %{device_type: "mobile", source_platform: "bing", amount_cents: 200})

      y = create_visitor!()

      seed_event!(y, "sale", %{device_type: "tablet", source_platform: "yahoo", amount_cents: 400})

      rows =
        Analytics.conversion_breakdown(@ws, :device_type,
          window: window(),
          filters: [{:source_platform, :in, ["google", "bing"]}]
        )

      assert fetch(rows, "desktop").sales == 1
      assert fetch(rows, "mobile").sales == 1
      assert fetch(rows, "tablet") == nil
    end

    test "a :neq filter excludes the matching source_platform" do
      google_buyer = create_visitor!()

      seed_event!(google_buyer, "sale", %{
        device_type: "desktop",
        source_platform: "google",
        amount_cents: 1000
      })

      bing_buyer = create_visitor!()

      seed_event!(bing_buyer, "sale", %{
        device_type: "mobile",
        source_platform: "bing",
        amount_cents: 4000
      })

      rows =
        Analytics.conversion_breakdown(@ws, :device_type,
          window: window(),
          filters: [{:source_platform, :neq, "google"}]
        )

      mobile = fetch(rows, "mobile")
      assert mobile.sales == 1
      assert mobile.revenue_cents == 4000
      assert fetch(rows, "desktop") == nil
    end

    test "a :not_in filter excludes the given set" do
      g = create_visitor!()

      seed_event!(g, "sale", %{
        device_type: "desktop",
        source_platform: "google",
        amount_cents: 100
      })

      b = create_visitor!()
      seed_event!(b, "sale", %{device_type: "mobile", source_platform: "bing", amount_cents: 200})

      y = create_visitor!()

      seed_event!(y, "sale", %{device_type: "tablet", source_platform: "yahoo", amount_cents: 400})

      rows =
        Analytics.conversion_breakdown(@ws, :device_type,
          window: window(),
          filters: [{:source_platform, :not_in, ["google", "bing"]}]
        )

      tablet = fetch(rows, "tablet")
      assert tablet.sales == 1
      assert tablet.revenue_cents == 400
      assert fetch(rows, "desktop") == nil
      assert fetch(rows, "mobile") == nil
    end

    test "a link_id :eq filter narrows on the uuid column" do
      link_id = Ecto.UUID.generate()
      other_link_id = Ecto.UUID.generate()

      buyer = create_visitor!()

      seed_event!(buyer, "sale", %{
        device_type: "desktop",
        link_id: link_id,
        amount_cents: 1000
      })

      seed_event!(buyer, "sale", %{
        device_type: "mobile",
        link_id: other_link_id,
        amount_cents: 2000
      })

      rows =
        Analytics.conversion_breakdown(@ws, :device_type,
          window: window(),
          filters: [{:link_id, :eq, link_id}]
        )

      assert fetch(rows, "desktop").sales == 1
      assert fetch(rows, "mobile") == nil
    end
  end
end
