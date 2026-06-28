defmodule GoodAnalytics.Core.Audience do
  @moduledoc """
  One shared, tested audience-breakdown query surface for every consumer.

  `breakdown/3` returns rows of `%{value: term(), <metrics...>}` for a single
  dimension over a workspace + time window. Dimensions and metrics are declared
  once (data-driven) so there is no per-dimension copy-paste.

  ## Grain (why some metrics are non-additive)

    * **Event-grain dimensions** (`:device_type`, `:browser`, `:os`,
      `:source_platform`, `:source_medium`, `:source_campaign`) group events by
      the *event's own* column — a device is the context of an interaction, not
      an attribute of the identity.
    * **Person-grain `:users`** counts `DISTINCT coalesce(merged_into_id, id)`,
      so one cross-device person is counted in **every** device/browser/os
      bucket they were active in. "mobile users + desktop users" can therefore
      exceed total users — and that is correct (GA4 behaviour). `:users` is
      **non-additive by design**; an additive partition would be a separately
      named `:primary_device_users` metric, deferred until requested.
    * **Session-grain metrics** (`:sessions`, `:bounce_rate`, `:avg_duration`,
      `:engaged_rate`) aggregate `ga_sessions`. A session's device/source is its
      first event's, stored on the session row, so they group cleanly by
      `s.device_type` etc.

  ## Metrics

  | metric | grain | definition |
  | --- | --- | --- |
  | `:events` | event | `count(e.id)` |
  | `:pageviews` | event | `count(e.id) FILTER (event_type = 'pageview')` |
  | `:users` | person | `count(DISTINCT coalesce(v.merged_into_id, v.id))` (non-additive) |
  | `:sessions` | session | `count(s.id)` |
  | `:bounce_rate` | session | `avg(s.is_bounce::int)` |
  | `:avg_duration` | session | `avg(s.duration_seconds)` |
  | `:engaged_rate` | session | `avg(s.is_engaged::int)` |

  ## Usage

      GoodAnalytics.Core.Audience.breakdown(workspace_id, :device_type,
        window: %{start_at: from, end_at: to},
        metrics: [:events, :users, :sessions, :bounce_rate],
        filters: [device_type: "mobile"],
        limit: 10
      )
  """

  import Ecto.Query

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Repo
  alias GoodAnalytics.TimeWindow

  @not_set GoodAnalytics.SQL.not_set()

  # value_kind: :event_column | :visitor_geo — how the dimension value is read.
  # session_column: the matching ga_sessions column (nil ⇒ no session metrics).
  @dimensions [
    {:device_type,
     %{value_kind: :event_column, column: :device_type, session_column: :device_type}},
    {:browser, %{value_kind: :event_column, column: :browser, session_column: :browser}},
    {:os, %{value_kind: :event_column, column: :os, session_column: :os}},
    {:source_platform,
     %{value_kind: :event_column, column: :source_platform, session_column: :source_platform}},
    {:source_medium,
     %{value_kind: :event_column, column: :source_medium, session_column: :source_medium}},
    {:source_campaign,
     %{value_kind: :event_column, column: :source_campaign, session_column: :source_campaign}},
    {:country, %{value_kind: :visitor_geo, geo_key: "country_code", session_column: nil}}
  ]

  @metrics [:events, :pageviews, :users, :sessions, :bounce_rate, :avg_duration, :engaged_rate]

  # Event/person-grain metrics selected from the joined event/visitor rows.
  @event_metrics [:events, :pageviews, :users]

  # Session-grain metrics that require a session_column on the dimension.
  @session_metrics [:sessions, :bounce_rate, :avg_duration, :engaged_rate]

  @doc "The supported breakdown dimensions, in declaration order."
  @spec dimensions() :: [atom()]
  def dimensions, do: Enum.map(@dimensions, &elem(&1, 0))

  @doc "The supported metrics, in declaration order."
  @spec metrics() :: [atom()]
  def metrics, do: @metrics

  @doc """
  Returns a dimension breakdown for `workspace_id` over the window.

  ## Options

    * `:window` — `%{start_at: from, end_at: to}` (required), an
      inclusive-start/exclusive-end `DateTime` range matched on `inserted_at`.
    * `:metrics` — subset of `metrics/0` (default: all). Mixing event/person
      metrics with session metrics composes a session sub-aggregate.
    * `:filters` — keyword of dimension equality filters for drilldown, e.g.
      `[device_type: "mobile"]`. Keys must be supported dimensions.
    * `:limit` — cap on returned rows.
    * `:order_by` — `{metric, :asc | :desc}` (default: the first requested
      metric, descending).

  Unknown dimension or metric raises `ArgumentError`. An empty window yields
  `[]`. Null dimension values bucket as `#{@not_set}`.
  """
  @spec breakdown(Ecto.UUID.t(), atom(), keyword()) :: [map()]
  def breakdown(workspace_id, dimension, opts) when is_binary(workspace_id) do
    dim = fetch_dimension!(dimension)
    metrics = validate_metrics!(Keyword.get(opts, :metrics, @metrics))
    validate_session_support!(dim, metrics)
    %{start_at: from, end_at: to} = TimeWindow.fetch!(opts)
    filters = Keyword.get(opts, :filters, [])
    {order_metric, order_dir} = order_spec(opts, metrics)
    limit = Keyword.get(opts, :limit)

    repo = Repo.repo()

    event_metrics = Enum.filter(metrics, &(&1 in @event_metrics))
    session_metrics = Enum.filter(metrics, &(&1 in @session_metrics))
    validate_filter_session_support!(filters, session_metrics)

    event_only? = session_metrics == []
    session_only? = event_metrics == []

    event_rows =
      if event_metrics == [] and session_metrics != [] do
        []
      else
        base_event_query(workspace_id, from, to, filters)
        |> group_by_dimension(dim)
        |> select_event_metrics(dim, event_metrics)
        |> push_sort_limit(
          event_only? and order_metric in event_metrics,
          order_metric,
          order_dir,
          limit,
          &event_metric_expr/1
        )
        |> repo.all(prefix: GoodAnalytics.schema_name())
      end

    session_rows =
      if session_metrics == [] do
        []
      else
        session_query(workspace_id, dim, from, to, filters, session_metrics)
        |> push_sort_limit(
          session_only? and order_metric in session_metrics,
          order_metric,
          order_dir,
          limit,
          &session_metric_expr/1
        )
        |> repo.all(prefix: GoodAnalytics.schema_name())
      end

    event_rows
    |> merge_rows(session_rows, event_metrics, session_metrics)
    |> order_rows(order_metric, order_dir)
    |> maybe_limit(limit)
  end

  # ---- option parsing & validation ------------------------------------------

  defp fetch_dimension!(dimension) do
    case List.keyfind(@dimensions, dimension, 0) do
      {^dimension, spec} -> Map.put(spec, :name, dimension)
      nil -> raise ArgumentError, "unknown breakdown dimension: #{inspect(dimension)}"
    end
  end

  defp validate_metrics!(metrics) do
    Enum.each(metrics, fn metric ->
      unless metric in @metrics do
        raise ArgumentError, "unknown metric: #{inspect(metric)}"
      end
    end)

    metrics
  end

  defp validate_session_support!(%{session_column: nil, name: name}, metrics) do
    requested = Enum.filter(metrics, &(&1 in @session_metrics))

    if requested != [] do
      raise ArgumentError,
            "dimension #{inspect(name)} does not support session metrics #{inspect(requested)}"
    end

    :ok
  end

  defp validate_session_support!(_dim, _metrics), do: :ok

  defp validate_filter_session_support!(_filters, []), do: :ok

  defp validate_filter_session_support!(filters, _session_metrics) do
    Enum.each(filters, fn {field, _value} ->
      case fetch_dimension!(field) do
        %{session_column: nil} ->
          raise ArgumentError,
                "filter on #{inspect(field)} cannot be combined with session metrics"

        _ ->
          :ok
      end
    end)
  end

  defp order_spec(opts, metrics) do
    default_metric = List.first(metrics)

    case Keyword.get(opts, :order_by, {default_metric, :desc}) do
      {metric, dir} when dir in [:asc, :desc] ->
        {metric, dir}

      other ->
        raise ArgumentError, "expected :order_by {metric, :asc|:desc}, got: #{inspect(other)}"
    end
  end

  defp order_rows(rows, nil, _dir), do: rows

  defp order_rows(rows, metric, dir) do
    sorter =
      case dir do
        :asc -> &<=/2
        :desc -> &>=/2
      end

    Enum.sort_by(rows, &order_key(Map.get(&1, metric)), sorter)
  end

  # Normalize Decimal/nil so mixed metric types sort deterministically.
  defp order_key(%Decimal{} = d), do: Decimal.to_float(d)
  defp order_key(nil), do: 0
  defp order_key(value), do: value

  defp maybe_limit(rows, nil), do: rows
  defp maybe_limit(rows, limit) when is_integer(limit), do: Enum.take(rows, limit)

  # For a single-grain request the top-N can be computed in SQL (no event/session
  # merge to reconcile), so push ORDER BY + LIMIT down to bound the rows fetched.
  # Guarded on the order metric belonging to this grain. The Elixir order_rows/3 +
  # maybe_limit/2 still run afterward and are idempotent on the already-ordered/
  # limited rows, preserving exact result semantics.
  defp push_sort_limit(query, false = _pushable?, _metric, _dir, _limit, _expr_fun), do: query

  defp push_sort_limit(query, true = _pushable?, order_metric, order_dir, limit, expr_fun) do
    query = order_by(query, ^[{order_dir, expr_fun.(order_metric)}])
    if is_integer(limit), do: limit(query, ^limit), else: query
  end

  # ---- base query & grouping -----------------------------------------------

  defp base_event_query(workspace_id, from, to, filters) do
    Event
    |> from(as: :event)
    |> join(:inner, [event: e], v in Visitor,
      as: :visitor,
      on: v.id == e.visitor_id and v.workspace_id == e.workspace_id
    )
    |> where([event: e], e.workspace_id == ^workspace_id)
    |> where([event: e], e.inserted_at >= ^from and e.inserted_at < ^to)
    |> apply_filters(filters)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn {field, value}, acc ->
      spec = fetch_dimension!(field)
      filter_by(acc, spec, value)
    end)
  end

  defp filter_by(query, %{value_kind: :event_column, column: col}, value) do
    where(query, [event: e], field(e, ^col) == ^value)
  end

  defp filter_by(query, %{value_kind: :visitor_geo, geo_key: key}, value) do
    where(query, [visitor: v], fragment("? ->> ? = ?", v.geo, ^key, ^value))
  end

  defp group_by_dimension(query, %{value_kind: :event_column, column: col}) do
    group_by(query, [event: e], field(e, ^col))
  end

  defp group_by_dimension(query, %{value_kind: :visitor_geo}) do
    # Group by the named `:value` select alias so Postgres sees the identical
    # expression in both GROUP BY and SELECT, avoiding parameter-slot mismatch
    # with the JSONB extraction fragment.
    group_by(query, selected_as(:value))
  end

  # ---- event/person metric selection ---------------------------------------

  defp select_event_metrics(query, dim, metrics) do
    selected =
      metrics
      |> Enum.filter(&(&1 in @event_metrics))
      |> Enum.reduce(%{value: dimension_value_select(dim)}, fn metric, acc ->
        Map.put(acc, metric, event_metric_expr(metric))
      end)

    select(query, [event: e, visitor: v], ^selected)
  end

  defp dimension_value_select(%{value_kind: :event_column, column: col}),
    do:
      dynamic([event: e], selected_as(type(coalesce(field(e, ^col), ^@not_set), :string), :value))

  defp dimension_value_select(%{value_kind: :visitor_geo, geo_key: key}),
    do:
      dynamic(
        [visitor: v],
        selected_as(fragment("coalesce(? ->> ?, ?)", v.geo, ^key, ^@not_set), :value)
      )

  defp event_metric_expr(:events), do: dynamic([event: e], count(e.id))

  defp event_metric_expr(:pageviews),
    do: dynamic([event: e], filter(count(e.id), e.event_type == "pageview"))

  defp event_metric_expr(:users),
    do:
      dynamic(
        [event: _e, visitor: v],
        count(fragment("coalesce(?, ?)", v.merged_into_id, v.id), :distinct)
      )

  # ---- session-grain metric selection --------------------------------------

  defp session_query(workspace_id, dim, from, to, filters, session_metrics) do
    Session
    |> from(as: :session)
    |> where([session: s], s.workspace_id == ^workspace_id)
    |> where([session: s], s.started_at >= ^from and s.started_at < ^to)
    |> apply_session_filters(filters)
    |> group_by_session_dimension(dim)
    |> select_session_metrics(dim, session_metrics)
  end

  defp apply_session_filters(query, filters) do
    Enum.reduce(filters, query, fn {field, value}, acc ->
      case fetch_dimension!(field) do
        %{session_column: nil} -> acc
        %{session_column: col} -> where(acc, [session: s], field(s, ^col) == ^value)
      end
    end)
  end

  defp group_by_session_dimension(query, %{session_column: _col}) do
    # Group by the named `:value` select alias so Postgres sees the identical
    # expression in both GROUP BY and SELECT, avoiding the parameter-slot
    # mismatch on the coalesce default.
    group_by(query, selected_as(:value))
  end

  defp select_session_metrics(query, %{session_column: col}, session_metrics) do
    value =
      dynamic(
        [session: s],
        selected_as(fragment("coalesce(?, ?)", field(s, ^col), ^@not_set), :value)
      )

    selected =
      Enum.reduce(session_metrics, %{value: value}, fn metric, acc ->
        Map.put(acc, metric, session_metric_expr(metric))
      end)

    select(query, [session: s], ^selected)
  end

  defp session_metric_expr(:sessions), do: dynamic([session: s], count(s.id))

  defp session_metric_expr(:bounce_rate),
    do: dynamic([session: s], type(avg(fragment("(?)::int", s.is_bounce)), :float))

  defp session_metric_expr(:avg_duration),
    do: dynamic([session: s], type(avg(s.duration_seconds), :float))

  defp session_metric_expr(:engaged_rate),
    do: dynamic([session: s], type(avg(fragment("(?)::int", s.is_engaged)), :float))

  # ---- outer-merge of event rows and session rows by dimension value -------

  defp merge_rows(event_rows, session_rows, event_metrics, session_metrics) do
    event_by_value = Map.new(event_rows, &{&1.value, &1})
    session_by_value = Map.new(session_rows, &{&1.value, &1})

    (Map.keys(event_by_value) ++ Map.keys(session_by_value))
    |> Enum.uniq()
    |> Enum.map(fn value ->
      e = Map.get(event_by_value, value, %{})
      s = Map.get(session_by_value, value, %{})

      %{value: value}
      |> merge_metric_values(e, event_metrics, 0)
      |> merge_metric_values(s, session_metrics, nil)
    end)
  end

  defp merge_metric_values(row, source, metrics, default) do
    Enum.reduce(metrics, row, fn metric, acc ->
      Map.put(acc, metric, Map.get(source, metric, default))
    end)
  end
end
