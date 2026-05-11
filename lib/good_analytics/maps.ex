defmodule GoodAnalytics.Maps do
  @moduledoc """
  Small map helpers used across the library.
  """

  @doc """
  Look up `key` in `map` using either the atom or string form, preferring
  the atom. Returns `nil` when neither key is present.

  Convenient for code paths that consume both Elixir-native maps (atom
  keys) and JSON-decoded payloads (string keys) — e.g. webhook ingestion,
  pgflow job inputs, identify attrs.

  ## Examples

      iex> GoodAnalytics.Maps.get_indifferent(%{person_email: "a@b.com"}, :person_email)
      "a@b.com"

      iex> GoodAnalytics.Maps.get_indifferent(%{"person_email" => "a@b.com"}, :person_email)
      "a@b.com"

      iex> GoodAnalytics.Maps.get_indifferent(%{person_email: "atom-wins"}, :person_email)
      "atom-wins"

      iex> GoodAnalytics.Maps.get_indifferent(%{}, :missing)
      nil
  """
  @spec get_indifferent(map(), atom()) :: term() | nil
  def get_indifferent(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
