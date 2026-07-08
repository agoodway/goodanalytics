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

  @doc """
  The label for the null/empty bucket in a dimension breakdown.

  Rows whose dimension value is `NULL` or absent are grouped under this label
  via `coalesce(column, not_set())`. Query builders and any consumer that
  renders or joins on the bucket value must reference this single source so the
  label stays consistent across grouping, joins, and display.
  """
  @spec not_set() :: String.t()
  def not_set, do: "(not set)"

  @doc """
  Coerces a numeric aggregate result to an integer.

  Postgres `sum`/`count` can come back as a `Decimal`, a plain integer, or
  `nil` (empty set). Returns the integer value, treating `nil` as `0`.
  """
  @spec integer_value(Decimal.t() | integer() | nil) :: integer()
  def integer_value(%Decimal{} = value), do: Decimal.to_integer(value)
  def integer_value(value) when is_integer(value), do: value
  def integer_value(nil), do: 0

  @doc """
  Dumps a UUID string into the binary form a raw SQL parameter expects.

  Raises `ArgumentError` when `uuid` is not a valid UUID.
  """
  @spec dump_uuid!(Ecto.UUID.t()) :: binary()
  def dump_uuid!(uuid) do
    case Ecto.UUID.dump(uuid) do
      {:ok, dumped} -> dumped
      :error -> raise ArgumentError, "invalid UUID: #{inspect(uuid)}"
    end
  end
end
