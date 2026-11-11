defmodule GoodAnalytics.Text do
  @moduledoc """
  Small string helpers used across the library.
  """

  @doc """
  Coerces a blank (empty or whitespace-only) string to `nil`. Anything else,
  including non-strings, is returned unchanged.

  ## Examples

      iex> GoodAnalytics.Text.blank_to_nil("  ")
      nil

      iex> GoodAnalytics.Text.blank_to_nil(" a ")
      " a "

      iex> GoodAnalytics.Text.blank_to_nil(:atom)
      :atom
  """
  @spec blank_to_nil(term()) :: term()
  def blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  def blank_to_nil(value), do: value
end
