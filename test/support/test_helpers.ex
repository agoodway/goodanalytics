defmodule GoodAnalytics.TestHelpers do
  @moduledoc """
  Shared factory and helper functions for GoodAnalytics tests.
  """

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors.Visitor

  import Ecto.Query

  @workspace_id GoodAnalytics.default_workspace_id()

  def default_workspace_id, do: @workspace_id

  @doc "Current UTC time truncated to `:microsecond` (default) or `:second`."
  @spec utc_now(:microsecond | :second) :: DateTime.t()
  def utc_now(precision \\ :microsecond)

  def utc_now(:microsecond) do
    DateTime.utc_now() |> DateTime.truncate(:microsecond)
  end

  def utc_now(:second) do
    DateTime.utc_now() |> DateTime.truncate(:second)
  end

  @doc """
  Offset from `utc_now/0`, e.g. `at(-1, :hour)` or `at(-30, :day)`.
  """
  def at(offset, unit \\ :second) when is_integer(offset) and is_atom(unit) do
    utc_now() |> DateTime.add(offset, unit)
  end

  @doc """
  Truncates a DateTime to the start of its UTC hour.
  """
  def truncate_hour(%DateTime{} = dt) do
    %{dt | minute: 0, second: 0, microsecond: {0, 6}}
  end

  @doc """
  Returns `%{start_at:, end_at:}` around now.

  Options `:before` and `:after` accept an integer day count or `{n, unit}`.
  Defaults: 14 days before, 1 day after.
  """
  def query_window(opts \\ []) do
    now = utc_now()

    {before_n, before_unit} = offset_parts(Keyword.get(opts, :before, 14))
    {after_n, after_unit} = offset_parts(Keyword.get(opts, :after, 1))

    %{
      start_at: DateTime.add(now, -before_n, before_unit),
      end_at: DateTime.add(now, after_n, after_unit)
    }
  end

  defp offset_parts({n, unit}) when is_integer(n) and is_atom(unit), do: {n, unit}
  defp offset_parts(n) when is_integer(n), do: {n, :day}

  @doc """
  Creates a link via `GoodAnalytics.create_link/1`. Raises on failure.
  Generates a unique key by default.
  """
  def create_link!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          domain: "test.link",
          key: "k#{System.unique_integer([:positive])}",
          url: "https://example.com"
        },
        attrs
      )

    {:ok, link} = GoodAnalytics.create_link(attrs)
    link
  end

  @doc """
  Creates a visitor directly via Repo.insert!.
  Sets workspace_id and timestamps by default.
  """
  def create_visitor!(attrs \\ %{}) do
    now = utc_now()

    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      )

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(attrs)
    |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
  end

  @doc """
  Resolves a visitor via IdentityResolver. Raises on error.
  """
  def resolve_visitor!(signals, opts \\ []) do
    opts = Keyword.put_new(opts, :workspace_id, @workspace_id)

    case IdentityResolver.resolve(signals, opts) do
      {:ok, visitor} -> visitor
      {:error, reason} -> raise "resolve_visitor! failed: #{inspect(reason)}"
    end
  end

  @doc """
  Records an event via Recorder. Raises on error.
  """
  def record_event!(visitor, event_type, attrs \\ %{}) do
    {inserted_at, attrs} = Map.pop(attrs, :inserted_at)

    case Recorder.record(visitor, event_type, attrs) do
      {:ok, event} -> maybe_set_inserted_at!(event, inserted_at)
      {:error, reason} -> raise "record_event! failed: #{inspect(reason)}"
    end
  end

  defp maybe_set_inserted_at!(event, nil), do: event

  defp maybe_set_inserted_at!(event, %DateTime{} = inserted_at) do
    repo = GoodAnalytics.Repo.repo()

    # Back-date only `inserted_at` (not `updated_at`) so window-filtering queries
    # see the intended event time. Match `{1, _}` so a zero-row update (wrong
    # prefix/stale id) fails loudly here instead of surfacing as a confusing
    # off-window count elsewhere.
    {1, _} =
      from(e in Event, where: e.id == ^event.id)
      |> repo.update_all([set: [inserted_at: inserted_at]], prefix: "good_analytics")

    %{event | inserted_at: inserted_at}
  end

  defp maybe_set_inserted_at!(_event, other) do
    raise ArgumentError,
          "record_event! :inserted_at must be a DateTime, got: #{inspect(other)}"
  end
end
