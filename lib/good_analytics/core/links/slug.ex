defmodule GoodAnalytics.Core.Links.Slug do
  @moduledoc """
  Slug generation for short links.

  Generates random URL-safe slugs or validates custom keys.
  """

  @chars ~c"abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
  @default_length 7

  @doc """
  Generates a random slug of the given length.

  Uses a character set that excludes ambiguous characters
  (0, O, l, I, 1) for readability.
  """
  def generate(length \\ @default_length) do
    for _ <- 1..length, into: "" do
      <<Enum.random(@chars)>>
    end
  end

  @doc """
  Validates a custom key.

  Keys must be 1-255 characters, URL-safe (alphanumeric, hyphens, underscores).
  """
  def valid?(key) when is_binary(key) do
    byte_size(key) >= 1 and
      byte_size(key) <= 255 and
      Regex.match?(~r/^[a-zA-Z0-9_-]+$/, key)
  end

  def valid?(_), do: false
end
