defmodule GoodAnalytics.Core.Events do
  @moduledoc """
  Context for event queries.
  """

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Repo
  alias GoodAnalytics.SQL

  import Ecto.Query
  import GoodAnalytics.SQL, only: [normalized_url: 1]

  @default_limit 50
  @default_window_days 7
  @seconds_per_day 86_400

  @doc """
  Lists events for a workspace with filtering, pagination, and date-range bounding.

  ## Options

    * `:event_type` — `{:in, list}` or `{:not_in, list}` for multi-select filtering
    * `:source_platform` — `{:in, list}` or `{:not_in, list}` for multi-select filtering
    * `:source_campaign` — `{:in, list}` or `{:not_in, list}` for multi-select filtering
    * `:url` — `{:in, list}` or `{:not_in, list}` for multi-select filtering
    * `:click_id` — `{:in, list}` or `{:not_in, list}` for multi-select filtering
    * `:visitor_id` — exact match on visitor_id
    * `:search` — ILIKE search across event_name and url
    * `:start_at` — lower bound for inserted_at (defaults to 7 days ago)
    * `:end_at` — upper bound for inserted_at (defaults to now)
    * `:limit` — page size (default 50)
    * `:offset` — page offset (default 0)

  All queries include date-range bounds to enable partition pruning.
  """
  @spec list_events(Ecto.UUID.t(), keyword()) :: [Event.t()]
  def list_events(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, @default_limit)
    offset = Keyword.get(opts, :offset, 0)

    workspace_id
    |> filtered_events_query(opts)
    |> limit(^limit)
    |> offset(^offset)
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Counts events matching the same filters as `list_events/2` (minus limit/offset).
  """
  @spec count_events(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def count_events(workspace_id, opts \\ []) do
    repo = Repo.repo()

    workspace_id
    |> filtered_events_query(opts)
    |> repo.aggregate(:count, :id, prefix: GoodAnalytics.schema_name())
  end

  @filter_options_window_days 90

  @doc """
  Returns distinct event_type and source_platform values for a workspace.

  Scans events from the last 90 days to keep the query partition-safe.
  Used to populate multi-select filter options.
  """
  @spec filter_options(Ecto.UUID.t()) :: %{
          event_types: [String.t()],
          source_platforms: [String.t()]
        }
  def filter_options(workspace_id) do
    repo = Repo.repo()
    prefix = GoodAnalytics.schema_name()

    since =
      DateTime.add(DateTime.utc_now(), -@filter_options_window_days * @seconds_per_day, :second)

    event_types =
      from(e in Event,
        where: e.workspace_id == ^workspace_id,
        where: e.inserted_at >= ^since,
        where: not is_nil(e.event_type),
        distinct: true,
        select: e.event_type,
        order_by: e.event_type
      )
      |> repo.all(prefix: prefix)

    source_platforms =
      from(e in Event,
        where: e.workspace_id == ^workspace_id,
        where: e.inserted_at >= ^since,
        where: not is_nil(e.source_platform),
        distinct: true,
        select: e.source_platform,
        order_by: e.source_platform
      )
      |> repo.all(prefix: prefix)

    %{event_types: event_types, source_platforms: source_platforms}
  end

  @doc """
  Gets a single event by id scoped to a workspace.

  Returns `nil` if the event doesn't exist or belongs to a different workspace.
  Uses WHERE clause instead of `Repo.get` due to composite primary key.

  NOTE: This query has no `inserted_at` bound, so Postgres will scan all
  partitions. Acceptable for single-row lookups hitting idx_ga_events_workspace,
  but pass `inserted_at` from the caller if performance becomes an issue.
  """
  @spec get_event(Ecto.UUID.t(), Ecto.UUID.t()) :: Event.t() | nil
  def get_event(workspace_id, event_id) do
    with {:ok, _} <- Ecto.UUID.cast(event_id) do
      repo = Repo.repo()

      from(e in Event,
        where: e.workspace_id == ^workspace_id,
        where: e.id == ^event_id,
        limit: 1
      )
      |> repo.one(prefix: GoodAnalytics.schema_name())
    else
      _ -> nil
    end
  end

  defp filtered_events_query(workspace_id, opts) do
    {start_at, end_at} = date_bounds(opts)

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: e.inserted_at >= ^start_at,
      where: e.inserted_at <= ^end_at,
      order_by: [desc: e.inserted_at]
    )
    |> maybe_filter_event_type(opts[:event_type])
    |> maybe_filter_source_platform(opts[:source_platform])
    |> maybe_filter_source_campaign(opts[:source_campaign])
    |> maybe_filter_url(opts[:url])
    |> maybe_filter_click_id(opts[:click_id])
    |> maybe_filter_visitor_id(opts[:visitor_id])
    |> maybe_filter_search(opts[:search])
  end

  defp date_bounds(opts) do
    now = DateTime.utc_now()
    start_at = Keyword.get(opts, :start_at, default_start(now))
    end_at = Keyword.get(opts, :end_at, now)
    {start_at, end_at}
  end

  defp default_start(now) do
    DateTime.add(now, -@default_window_days * @seconds_per_day, :second)
  end

  defp maybe_filter_event_type(query, {:in, types}) when is_list(types),
    do: where(query, [e], e.event_type in ^types)

  defp maybe_filter_event_type(query, {:not_in, types}) when is_list(types),
    do: where(query, [e], e.event_type not in ^types)

  defp maybe_filter_event_type(query, _), do: query

  defp maybe_filter_source_platform(query, {:in, platforms}) when is_list(platforms),
    do: where(query, [e], e.source_platform in ^platforms)

  defp maybe_filter_source_platform(query, {:not_in, platforms}) when is_list(platforms),
    do: where(query, [e], e.source_platform not in ^platforms)

  defp maybe_filter_source_platform(query, _), do: query

  defp maybe_filter_source_campaign(query, {:in, campaigns}) when is_list(campaigns),
    do: where(query, [e], e.source_campaign in ^campaigns)

  defp maybe_filter_source_campaign(query, {:not_in, campaigns}) when is_list(campaigns),
    do: where(query, [e], e.source_campaign not in ^campaigns)

  defp maybe_filter_source_campaign(query, _), do: query

  # Matches the normalized URL (query string / trailing slash collapsed) so a
  # filter drilled from a page-level breakdown row resolves the same events the
  # row counted.
  defp maybe_filter_url(query, {:in, urls}) when is_list(urls),
    do: where(query, [e], normalized_url(e.url) in ^urls)

  defp maybe_filter_url(query, {:not_in, urls}) when is_list(urls),
    do: where(query, [e], normalized_url(e.url) not in ^urls)

  defp maybe_filter_url(query, _), do: query

  defp maybe_filter_click_id(query, {:in, ids}) when is_list(ids),
    do: where(query, [e], e.click_id in ^ids)

  defp maybe_filter_click_id(query, {:not_in, ids}) when is_list(ids),
    do: where(query, [e], e.click_id not in ^ids)

  defp maybe_filter_click_id(query, _), do: query

  defp maybe_filter_visitor_id(query, nil), do: query
  defp maybe_filter_visitor_id(query, ""), do: query

  defp maybe_filter_visitor_id(query, visitor_id),
    do: where(query, [e], e.visitor_id == ^visitor_id)

  @max_search_length 200

  defp maybe_filter_search(query, nil), do: query
  defp maybe_filter_search(query, ""), do: query

  defp maybe_filter_search(query, search) do
    search = String.slice(search, 0, @max_search_length)
    pattern = "%#{SQL.escape_like(search)}%"
    where(query, [e], ilike(e.event_name, ^pattern) or ilike(e.url, ^pattern))
  end

  @doc """
  Returns source platform/medium breakdown for a workspace.

  Accepts `:start_at` and `:end_at` to bound the date range for partition
  pruning. Defaults to the last 7 days when no bounds are provided.
  """
  def source_breakdown(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, 10)
    {start_at, end_at} = date_bounds(opts)

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: e.inserted_at >= ^start_at,
      where: e.inserted_at <= ^end_at,
      where: not is_nil(e.source_platform),
      group_by: [e.source_platform, e.source_medium],
      select: %{
        platform: e.source_platform,
        medium: e.source_medium,
        count: count(e.id)
      },
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Gets a single event by id only — **not workspace-scoped**.

  `Repo.get(Event, id)` is unsafe because the events table has a composite
  primary key `(id, inserted_at)` (required by Postgres for partitioned
  tables). This helper performs the equivalent fetch using a `where`
  clause and returns `nil` if no event is found.

  WARNING: This function does NOT scope by workspace. Callers MUST ensure
  tenant isolation before exposing results to users. Prefer `get_event/2`
  for workspace-scoped lookups.
  """
  def get_by_id(id) do
    repo = Repo.repo()

    from(e in Event, where: e.id == ^id, limit: 1)
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Finds an event by idempotency key within a workspace.

  Returns `nil` if no event matches the key.
  """
  def get_by_idempotency_key(workspace_id, idempotency_key) do
    repo = Repo.repo()

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: fragment("?->>'_idempotency_key' = ?", e.properties, ^idempotency_key),
      limit: 1
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets the most recent event of a given type for a visitor."
  def last_event(visitor_id, event_type) do
    repo = Repo.repo()

    from(e in Event,
      where: e.visitor_id == ^visitor_id,
      where: e.event_type == ^event_type,
      order_by: [desc: e.inserted_at],
      limit: 1
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end
end
