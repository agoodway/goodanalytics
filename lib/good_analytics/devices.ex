defmodule GoodAnalytics.Devices do
  @moduledoc """
  User-agent intelligence for GoodAnalytics, wrapping `:ua_inspector`.

  The single owner of UAInspector access in the library. Pure functions — no
  Ecto, no side effects:

    * `parse/1`         — normalize a user agent into a storable device map
    * `label/1`         — humanize a UA string or a stored device map
    * `humanize_type/1` — collapse a raw device type into a coarse bucket
    * `bot?/1`          — crawler predicate

  `parse/1` stores raw `:ua_inspector` field values (names + versions); consumers
  group/humanize via `label/1` and `humanize_type/1`.
  """

  alias UAInspector.Result

  @type device_map :: %{optional(String.t()) => String.t()}

  @doc "Normalize a user agent into a device map. Empty map when blank/unknown."
  @spec parse(String.t() | nil) :: device_map()
  def parse(ua) when is_binary(ua) and ua != "" do
    case UAInspector.parse(ua) do
      %Result.Bot{name: name} ->
        drop_blanks(%{"type" => "bot", "name" => name})

      %Result{} = result ->
        drop_blanks(%{
          "type" => field(result.device, :type),
          "brand" => field(result.device, :brand),
          "model" => field(result.device, :model),
          "os" => field(result.os, :name),
          "os_version" => field(result.os, :version),
          "browser" => field(result.client, :name),
          "browser_version" => field(result.client, :version)
        })

      _other ->
        %{}
    end
  end

  def parse(_ua), do: %{}

  @doc "Humanize a UA string or a stored device map into a short label."
  @spec label(String.t() | map() | nil) :: String.t()
  def label(nil), do: "Unknown"
  def label(ua) when is_binary(ua), do: ua |> parse() |> label()
  def label(%{"type" => "bot", "name" => name}) when is_binary(name), do: "Bot · #{name}"
  def label(%{"type" => "bot"}), do: "Bot"

  def label(%{} = map) do
    label =
      [
        map |> Map.get("type") |> humanize_type_or_nil(),
        version_part(Map.get(map, "os"), Map.get(map, "os_version")),
        version_part(Map.get(map, "browser"), Map.get(map, "browser_version"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    if label == "", do: "Unknown", else: label
  end

  @doc "Collapse a raw `:ua_inspector` device type into a coarse breakdown bucket."
  @spec humanize_type(String.t() | nil) :: String.t()
  def humanize_type(type) when type in [nil, ""], do: "Unknown"
  def humanize_type("desktop"), do: "Desktop"
  def humanize_type("smartphone"), do: "Mobile"
  def humanize_type("phablet"), do: "Mobile"
  def humanize_type("tablet"), do: "Tablet"
  def humanize_type("tv"), do: "TV"
  def humanize_type("console"), do: "Console"
  def humanize_type("car browser"), do: "Car"
  def humanize_type("portable media player"), do: "Media Player"
  def humanize_type("wearable"), do: "Wearable"
  def humanize_type("bot"), do: "Bot"
  def humanize_type(other) when is_binary(other), do: String.capitalize(other)

  @doc "True when the user agent is a known crawler/bot. Tolerates blanks."
  @spec bot?(String.t() | nil) :: boolean()
  def bot?(ua) when is_binary(ua) and ua != "", do: UAInspector.bot?(ua)
  def bot?(_ua), do: false

  # -- private --

  # `:ua_inspector` reports a missing component as the `:unknown` atom (not a
  # struct) and a missing field within a component as `:unknown` too.
  defp field(component, key) when is_map(component) do
    case Map.get(component, key) do
      value when is_binary(value) -> value
      _unknown -> nil
    end
  end

  defp field(_component, _key), do: nil

  defp drop_blanks(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Map.new()
  end

  defp humanize_type_or_nil(nil), do: nil
  defp humanize_type_or_nil(""), do: nil
  defp humanize_type_or_nil(type), do: humanize_type(type)

  defp version_part(nil, _version), do: nil
  defp version_part("", _version), do: nil
  defp version_part(name, version) when version in [nil, ""], do: name
  defp version_part(name, version), do: "#{name} #{major_version(version)}"

  defp major_version(version) when is_binary(version) do
    case String.split(version, ".") do
      [major] -> major
      [major, minor | _rest] -> "#{major}.#{minor}"
    end
  end

  defp major_version(version), do: to_string(version)
end
