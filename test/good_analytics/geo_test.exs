defmodule GoodAnalytics.GeoTest do
  use ExUnit.Case, async: false

  alias GoodAnalytics.Geo

  describe "parse_ip/1" do
    test "accepts valid IPv4 tuples" do
      assert {:ok, {8, 8, 8, 8}} = Geo.parse_ip({8, 8, 8, 8})
      assert {:ok, {0, 0, 0, 0}} = Geo.parse_ip({0, 0, 0, 0})
      assert {:ok, {255, 255, 255, 255}} = Geo.parse_ip({255, 255, 255, 255})
    end

    test "rejects IPv4 tuples with out-of-range octets" do
      assert {:error, {:invalid_ip, _}} = Geo.parse_ip({256, 0, 0, 1})
      assert {:error, {:invalid_ip, _}} = Geo.parse_ip({-1, 0, 0, 1})
    end

    test "accepts valid IPv6 tuples" do
      assert {:ok, ip} = Geo.parse_ip({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert tuple_size(ip) == 8
    end

    test "rejects IPv6 tuples with out-of-range elements" do
      assert {:error, {:invalid_ip, _}} = Geo.parse_ip({0x10000, 0, 0, 0, 0, 0, 0, 1})
    end

    test "parses IPv4 strings" do
      assert {:ok, {8, 8, 8, 8}} = Geo.parse_ip("8.8.8.8")
    end

    test "parses IPv6 strings" do
      assert {:ok, ip} = Geo.parse_ip("2001:db8::1")
      assert tuple_size(ip) == 8
    end

    test "rejects garbage strings" do
      assert {:error, {:invalid_ip, "not an ip"}} = Geo.parse_ip("not an ip")
      assert {:error, {:invalid_ip, ""}} = Geo.parse_ip("")
    end

    test "rejects strings longer than the max IPv6 textual length" do
      # 45 bytes is the longest valid form (IPv4-mapped IPv6). Anything
      # longer is rejected via guard, without invoking `:inet`.
      long = String.duplicate("a", 100)
      assert {:error, {:invalid_ip, ^long}} = Geo.parse_ip(long)
    end

    test "unwraps Postgrex.INET" do
      inet = %Postgrex.INET{address: {1, 2, 3, 4}, netmask: 32}
      assert {:ok, {1, 2, 3, 4}} = Geo.parse_ip(inet)
    end

    test "rejects non-IP terms" do
      assert {:error, {:invalid_ip, :foo}} = Geo.parse_ip(:foo)
      assert {:error, {:invalid_ip, 42}} = Geo.parse_ip(42)
      assert {:error, {:invalid_ip, nil}} = Geo.parse_ip(nil)
    end
  end

  describe "lookup/1 when geo disabled" do
    # Ensure no provider is configured for these tests.
    setup do
      previous = Application.get_env(:good_analytics, :geo)
      Application.delete_env(:good_analytics, :geo)
      on_exit(fn -> if previous, do: Application.put_env(:good_analytics, :geo, previous) end)
      :ok
    end

    test "enabled?/0 returns false" do
      refute Geo.enabled?()
    end

    test "returns {:error, :geo_disabled} regardless of input shape" do
      # When no provider is configured, `lookup/1` short-circuits before
      # parsing the IP. This is intentional — the disabled path is a hot
      # no-op for event ingestion when geo is turned off.
      for input <- [nil, "", "garbage", "8.8.8.8", {8, 8, 8, 8}, :foo] do
        assert {:error, :geo_disabled} = Geo.lookup(input),
               "expected :geo_disabled for input #{inspect(input)}"
      end
    end
  end

  describe "lookup/1 with a stub provider" do
    defmodule StubProvider do
      @behaviour GoodAnalytics.Geo.Provider

      @impl true
      def lookup({0, 0, 0, 0}), do: {:error, :not_found}
      def lookup({1, 1, 1, 1}), do: {:error, :loader_not_ready}

      def lookup(_ip) do
        {:ok,
         %{
           "country" => %{"iso_code" => "US", "names" => %{"en" => "United States"}},
           "city" => %{"names" => %{"en" => "Mountain View"}},
           "continent" => %{"names" => %{"en" => "North America"}},
           "location" => %{
             "latitude" => 37.4,
             "longitude" => -122.1,
             "time_zone" => "America/Los_Angeles"
           },
           "subdivisions" => [%{"names" => %{"en" => "California"}}]
         }}
      end
    end

    setup do
      previous = Application.get_env(:good_analytics, :geo)

      Application.put_env(:good_analytics, :geo,
        provider: StubProvider,
        normalizer: GoodAnalytics.Geo.Normalizer.MaxMind
      )

      on_exit(fn ->
        if previous,
          do: Application.put_env(:good_analytics, :geo, previous),
          else: Application.delete_env(:good_analytics, :geo)
      end)

      :ok
    end

    test "returns normalized map on success" do
      assert {:ok, geo} = Geo.lookup("8.8.8.8")
      assert geo.country == "United States"
      assert geo.country_code == "US"
      assert geo.region == "California"
      assert geo.city == "Mountain View"
      assert geo.continent == "North America"
      assert geo.timezone == "America/Los_Angeles"
      assert geo.latitude == 37.4
      assert geo.longitude == -122.1
    end

    test "propagates :not_found from provider" do
      assert {:error, :not_found} = Geo.lookup("0.0.0.0")
    end

    test "propagates :loader_not_ready from provider" do
      assert {:error, :loader_not_ready} = Geo.lookup("1.1.1.1")
    end

    test "still validates IP before calling provider" do
      assert {:error, {:invalid_ip, "garbage"}} = Geo.lookup("garbage")
    end
  end

  describe "enqueue_enrichment/2" do
    setup do
      previous = Application.get_env(:good_analytics, :geo)
      on_exit(fn -> if previous, do: Application.put_env(:good_analytics, :geo, previous) end)
      :ok
    end

    test "returns :ok and does not spawn a task when geo is disabled" do
      Application.delete_env(:good_analytics, :geo)
      refute Geo.enabled?()

      before = task_count()
      assert :ok = Geo.enqueue_enrichment(Uniq.UUID.uuid7(), "8.8.8.8")
      assert task_count() == before
    end
  end

  defp task_count do
    case Process.whereis(GoodAnalytics.GeoTaskSupervisor) do
      nil -> 0
      _pid -> length(Task.Supervisor.children(GoodAnalytics.GeoTaskSupervisor))
    end
  end
end
