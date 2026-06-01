defmodule GoodAnalytics.SQL do
  @moduledoc """
  Generic SQL helpers shared across the library (and host apps that build their
  own queries against the GoodAnalytics tables).
  """

  @doc """
  Escapes the `LIKE`/`ILIKE` metacharacters (`\\`, `%`, `_`) in `term` so a
  user-supplied search string matches literally instead of as a wildcard.

  Every metacharacter is escaped in a single pass, so the result is the same
  regardless of which character appears first. The caller wraps the result in
  `%...%` (or similar) and, for raw SQL, appends `ESCAPE '\\\\'` to the condition.

  ## Examples

      iex> GoodAnalytics.SQL.escape_like("50%off")
      "50\\\\%off"

      iex> GoodAnalytics.SQL.escape_like("a_b")
      "a\\\\_b"
  """
  @spec escape_like(String.t()) :: String.t()
  def escape_like(term) when is_binary(term) do
    String.replace(term, ["\\", "%", "_"], fn char -> "\\" <> char end)
  end

  @doc """
  Ecto query fragment that normalizes a URL column for page-level grouping:
  strips the query string, collapses duplicate slashes (keeping `://`), and
  drops a trailing slash, defaulting empty/null to `"/"`.

  Single source of truth so the analytics "Top Pages" breakdown grouping and any
  drill-down filter on the same dimension stay in lockstep. Import the module and
  use it inside a query:

      import GoodAnalytics.SQL
      from(e in Event, group_by: normalized_url(e.url), select: normalized_url(e.url))
  """
  defmacro normalized_url(field) do
    quote do
      fragment(
        "coalesce(nullif(regexp_replace(regexp_replace(split_part(coalesce(?, '/'), chr(63), 1), $re$([^:])/+$re$, $rep$\\1/$rep$, 'g'), $re$/$$re$, ''), ''), '/')",
        unquote(field)
      )
    end
  end
end
