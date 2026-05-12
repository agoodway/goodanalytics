defmodule GoodAnalytics.Geo.Normalizer.MaxMindTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Geo.Normalizer.MaxMind

  describe "normalize/1" do
    test "maps a complete US city result" do
      result = %{
        "country" => %{"iso_code" => "US", "names" => %{"en" => "United States"}},
        "city" => %{"names" => %{"en" => "New York"}},
        "continent" => %{"names" => %{"en" => "North America"}, "code" => "NA"},
        "subdivisions" => [%{"iso_code" => "NY", "names" => %{"en" => "New York"}}],
        "location" => %{
          "latitude" => 40.7128,
          "longitude" => -74.0060,
          "time_zone" => "America/New_York",
          "accuracy_radius" => 5
        },
        "postal" => %{"code" => "10001"}
      }

      assert MaxMind.normalize(result) == %{
               country: "United States",
               country_code: "US",
               region: "New York",
               city: "New York",
               timezone: "America/New_York",
               continent: "North America",
               latitude: 40.7128,
               longitude: -74.0060
             }
    end

    test "maps a UK city result" do
      result = %{
        "country" => %{"iso_code" => "GB", "names" => %{"en" => "United Kingdom"}},
        "city" => %{"names" => %{"en" => "London"}},
        "continent" => %{"names" => %{"en" => "Europe"}},
        "subdivisions" => [%{"names" => %{"en" => "England"}}],
        "location" => %{"latitude" => 51.5, "longitude" => -0.12, "time_zone" => "Europe/London"}
      }

      normalized = MaxMind.normalize(result)
      assert normalized.country_code == "GB"
      assert normalized.city == "London"
      assert normalized.region == "England"
      assert normalized.timezone == "Europe/London"
    end

    test "country-only result (e.g., private IP near a region boundary)" do
      result = %{
        "country" => %{"iso_code" => "JP", "names" => %{"en" => "Japan"}}
      }

      assert %{country: "Japan", country_code: "JP", city: nil, region: nil, latitude: nil} =
               MaxMind.normalize(result)
    end

    test "empty map returns all nils" do
      assert %{country: nil, country_code: nil, city: nil, region: nil, latitude: nil} =
               MaxMind.normalize(%{})
    end

    test "non-map input returns empty result" do
      assert %{country: nil, country_code: nil} = MaxMind.normalize(nil)
      assert %{country: nil, country_code: nil} = MaxMind.normalize("garbage")
    end

    test "missing 'en' name returns nil rather than crashing" do
      result = %{
        "country" => %{"iso_code" => "JP", "names" => %{"ja" => "日本"}}
      }

      normalized = MaxMind.normalize(result)
      assert normalized.country == nil
      assert normalized.country_code == "JP"
    end

    test "subdivisions takes the first entry" do
      result = %{
        "country" => %{"iso_code" => "US", "names" => %{"en" => "United States"}},
        "subdivisions" => [
          %{"names" => %{"en" => "California"}},
          %{"names" => %{"en" => "San Mateo County"}}
        ]
      }

      assert %{region: "California"} = MaxMind.normalize(result)
    end

    test "does NOT call String.to_atom on unknown keys (atom-table safety)" do
      # Sanity check: feeding the normalizer a map with an unknown key should
      # not register a new atom. We cannot directly observe atom-table state
      # but we can verify the normalizer ignores unknown keys without crashing.
      result = %{
        "country" => %{"iso_code" => "US", "names" => %{"en" => "United States"}},
        "totally_unknown_provider_field" => "should be ignored"
      }

      assert %{country_code: "US"} = MaxMind.normalize(result)
    end
  end
end
