defmodule GoodAnalytics.Core.Tracking.Referers.Key do
  @moduledoc """
  Name normalization shared by the referrer database builder and the runtime
  lookups.

  * `slug/1` turns a list name into a platform key (`"Yahoo! Mail"` -> `"yahoo_mail"`).
  * `normalize/1` turns any free-form source name into an alias-index key by
    ignoring case, a leading `www.`, a trailing `.com` and all punctuation
    (`"Duck.ai"` and `"duck.ai"` -> `"duckai"`). A `+` is kept as `plus`, so
    `Google+` never collides with `Google`.
  """

  alias GoodAnalytics.Text

  @doc "Slug of a list name, or `nil` when nothing alphanumeric remains."
  @spec slug(term()) :: String.t() | nil
  def slug(value) do
    value
    |> to_string()
    |> if_valid(fn string ->
      string
      |> String.downcase()
      |> String.replace("+", " plus ")
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "_")
      |> String.trim("_")
      |> Text.blank_to_nil()
    end)
  end

  @doc """
  Alias-index key for a free-form source name, or `nil` when empty or not valid
  UTF-8 (the Unicode regex below raises on invalid bytes).
  """
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) do
    value
    |> to_string()
    |> if_valid(fn string ->
      string
      |> String.trim()
      |> String.downcase()
      |> String.replace_prefix("www.", "")
      |> String.replace_suffix(".com", "")
      |> String.replace("+", "plus")
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "")
      |> Text.blank_to_nil()
    end)
  end

  defp if_valid(string, fun), do: if(String.valid?(string), do: fun.(string))
end
