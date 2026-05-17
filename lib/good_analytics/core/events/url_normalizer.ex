defmodule GoodAnalytics.Core.Events.UrlNormalizer do
  @moduledoc """
  URL normalization helpers for analytics grouping.

  Single source of truth for `host` and `path` values written to `ga_events`.
  Raw URLs stay on `ga_events.url`; these helpers produce the normalized
  `host` and `path` columns used for indexed analytics queries.
  """

  @doc """
  Returns the normalized host from a URL.

  Lowercase, default ports stripped (80 for http, 443 for https).
  Returns `nil` when no host is present.
  """
  @spec host(String.t() | nil) :: String.t() | nil
  def host(nil), do: nil
  def host(""), do: nil

  def host(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.host do
      nil -> nil
      "" -> nil
      h -> String.downcase(h) <> port_suffix(uri)
    end
  end

  @doc """
  Returns the normalized path from a URL.

  Defaults to `/`, query/fragment stripped, duplicate slashes collapsed,
  trailing slash trimmed except for root.
  """
  @spec path(String.t() | nil) :: String.t()
  def path(nil), do: "/"
  def path(""), do: "/"

  def path(url) when is_binary(url) do
    uri = URI.parse(url)
    normalize_path(uri.path)
  end

  @doc """
  Returns a stable grouping key made from scheme, host, and normalized path.

  Query strings and fragments are removed. Duplicate slashes in the path are
  collapsed, and a trailing slash is stripped except for the root path.
  """
  @spec path_for_grouping(String.t() | nil) :: String.t()
  def path_for_grouping(nil), do: "/"
  def path_for_grouping(""), do: "/"

  def path_for_grouping(url) when is_binary(url) do
    uri = URI.parse(url)
    normalized = normalize_path(uri.path)

    case {uri.scheme, uri.host} do
      {scheme, h} when is_binary(scheme) and is_binary(h) ->
        "#{scheme}://#{String.downcase(h)}#{port_suffix(uri)}#{normalized}"

      _ ->
        normalized
    end
  end

  defp normalize_path(nil), do: "/"
  defp normalize_path(""), do: "/"

  defp normalize_path(p) do
    p
    |> String.replace(~r{/+}, "/")
    |> ensure_leading_slash()
    |> strip_trailing_slash()
  end

  defp ensure_leading_slash("/" <> _ = p), do: p
  defp ensure_leading_slash(p), do: "/" <> p

  defp strip_trailing_slash("/"), do: "/"
  defp strip_trailing_slash(p), do: String.trim_trailing(p, "/")

  defp port_suffix(%URI{port: nil}), do: ""
  defp port_suffix(%URI{scheme: "http", port: 80}), do: ""
  defp port_suffix(%URI{scheme: "https", port: 443}), do: ""
  defp port_suffix(%URI{port: port}), do: ":#{port}"
end
