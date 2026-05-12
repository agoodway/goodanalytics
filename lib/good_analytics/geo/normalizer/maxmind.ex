defmodule GoodAnalytics.Geo.Normalizer.MaxMind do
  @moduledoc """
  Normalizes MaxMind GeoLite2-City / GeoIP2-City result maps into the canonical
  `GoodAnalytics.Geo.Normalizer.normalized` shape.

  Locus emits binary keys in MMDB results. We tolerate atom keys as well (for
  hand-built test fixtures), but only via the explicit `@known_keys` set —
  never via `String.to_atom/1`, to avoid atom-table exhaustion on adversarial
  input.
  """

  @behaviour GoodAnalytics.Geo.Normalizer

  @lang "en"

  # The complete set of MMDB section/field keys we read. Each entry maps the
  # canonical binary key (as emitted by locus) to its atom counterpart, so we
  # can match either shape without ever calling `String.to_atom/1` at runtime.
  @known_keys %{
    "country" => :country,
    "city" => :city,
    "continent" => :continent,
    "location" => :location,
    "subdivisions" => :subdivisions,
    "names" => :names,
    "iso_code" => :iso_code,
    "latitude" => :latitude,
    "longitude" => :longitude,
    "time_zone" => :time_zone,
    @lang => String.to_atom(@lang)
  }

  @impl true
  def normalize(result) when is_map(result) do
    %{
      country: name(result, "country"),
      country_code: code(result, "country"),
      region: first_subdivision_name(result),
      city: name(result, "city"),
      timezone: location(result, "time_zone"),
      continent: name(result, "continent"),
      latitude: location(result, "latitude"),
      longitude: location(result, "longitude")
    }
  end

  def normalize(_), do: empty()

  defp empty do
    %{
      country: nil,
      country_code: nil,
      region: nil,
      city: nil,
      timezone: nil,
      continent: nil,
      latitude: nil,
      longitude: nil
    }
  end

  defp name(result, key) do
    case get(result, key) do
      %{} = section ->
        section
        |> get("names")
        |> case do
          %{} = names -> get(names, @lang)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp code(result, key) do
    case get(result, key) do
      %{} = section -> get(section, "iso_code")
      _ -> nil
    end
  end

  defp first_subdivision_name(result) do
    case get(result, "subdivisions") do
      [first | _] when is_map(first) ->
        case get(first, "names") do
          %{} = names -> get(names, @lang)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp location(result, key) do
    case get(result, "location") do
      %{} = section -> get(section, key)
      _ -> nil
    end
  end

  # Lookup against a known key set only. Tries the binary form (locus emits
  # binaries) then the atom alias (hand-built fixtures). Returns nil for any
  # unknown key — adversarial MMDB additions cannot create atoms.
  defp get(map, key) when is_map(map) and is_map_key(@known_keys, key) do
    Map.get(map, key, Map.get(map, Map.fetch!(@known_keys, key)))
  end

  defp get(_other, _key), do: nil
end
