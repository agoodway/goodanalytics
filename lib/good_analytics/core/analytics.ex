defmodule GoodAnalytics.Core.Analytics do
  @moduledoc """
  Aggregate read surface over the library-managed `good_analytics`
  event/visitor/session tables.

  Every function takes a bare `workspace_id` binary plus a plain `opts`
  keyword: the time window as `opts[:window]`
  (`%{start_at: DateTime.t(), end_at: DateTime.t()}`) and the workspace timezone
  as `opts[:timezone]` (a string, default `"Etc/UTC"`). Callers resolve their own
  window, timezone, authorization, and filter inputs and pass plain values in.

  `GoodAnalytics.Core.Audience` provides the single-dimension `breakdown/3`. This
  module provides `timeseries/3`, `kpis/2`, `conversion_breakdown/3`, and
  `session_metrics/2`.
  """

  import Ecto.Query, warn: false
  import GoodAnalytics.SQL, only: [escape_like: 1, integer_value: 1, dump_uuid!: 1, not_set: 0]

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Repo
  alias GoodAnalytics.TimeWindow

  @default_timezone "Etc/UTC"

  @bucket_intervals [
    %{key: :minute, label: "1m", seconds: 60},
    %{key: :minute_5, label: "5m", seconds: 5 * 60},
    %{key: :minute_15, label: "15m", seconds: 15 * 60},
    %{key: :minute_30, label: "30m", seconds: 30 * 60},
    %{key: :hour, label: "1h", seconds: 60 * 60},
    %{key: :hour_2, label: "2h", seconds: 2 * 60 * 60},
    %{key: :hour_3, label: "3h", seconds: 3 * 60 * 60},
    %{key: :hour_6, label: "6h", seconds: 6 * 60 * 60},
    %{key: :hour_12, label: "12h", seconds: 12 * 60 * 60},
    %{key: :day, label: "1d", seconds: 24 * 60 * 60},
    %{key: :day_2, label: "2d", seconds: 2 * 24 * 60 * 60},
    %{key: :week, label: "1w", seconds: 7 * 24 * 60 * 60},
    %{key: :week_2, label: "2w", seconds: 14 * 24 * 60 * 60},
    %{key: :month, label: "1mo", seconds: 30 * 24 * 60 * 60}
  ]

  @breakdown_dimensions ~w(
    channel
    source_platform
    source_medium
    source_campaign
    url
    click_id_param
    device_type
    browser
    os
    country
    city
    short_link
  )a

  @event_filter_fields ~w(
    inserted_at
    event_type
    source_platform
    source_medium
    source_campaign
    url
    click_id
    link_id
  )a

  @session_filter_fields ~w(
    source_platform
    source_medium
    source_campaign
    click_id
    device_type
    browser
    os
    entry_url
    entry_page
    exit_page
  )a

  @doc "The supported breakdown/conversion dimensions, in declaration order."
  @spec breakdown_dimensions() :: [atom()]
  def breakdown_dimensions, do: @breakdown_dimensions

  @doc "The allowlisted event filter fields, in declaration order."
  @spec event_filter_fields() :: [atom()]
  def event_filter_fields, do: @event_filter_fields

  @doc """
  Selects a bucket interval for a window from the fixed ladder.
  """
  @spec bucket_interval(%{start_at: DateTime.t(), end_at: DateTime.t()}) :: map()
  def bucket_interval(%{start_at: start_at, end_at: end_at}) do
    window_seconds = max(DateTime.diff(end_at, start_at, :second), 60)
    target_buckets = target_bucket_count(window_seconds)

    Enum.find(@bucket_intervals, List.last(@bucket_intervals), fn interval ->
      window_seconds / interval.seconds <= target_buckets
    end)
  end

  @doc """
  Floors a timestamp to a bucket boundary in the given timezone.
  """
  @spec align_bucket_start(DateTime.t(), map(), String.t()) :: DateTime.t()
  def align_bucket_start(datetime, interval, timezone) do
    query_aligned_bucket_start(interval.seconds, datetime, timezone)
  end

  @doc """
  Returns zero-filled, timezone-aligned buckets for chart rendering.

  Supported metrics are `:visitors`, `:pageviews`, `:revenue`, `:sessions`, and
  `:engaged`. Options: `:window` (`%{start_at:, end_at:}`, required), `:timezone`
  (string, default `"Etc/UTC"`), `:bucket_interval` (from `bucket_interval/1`,
  default derived from the window), `:filters` (keyword of `{event_field, value}`
  restricted to `event_filter_fields/0`).
  """
  @spec timeseries(
          Ecto.UUID.t(),
          :visitors | :pageviews | :revenue | :sessions | :engaged,
          keyword()
        ) :: [map()]
  def timeseries(workspace_id, metric, opts) when is_binary(workspace_id) do
    metric = normalize_metric!(metric)
    window = TimeWindow.fetch!(opts)
    timezone = Keyword.get(opts, :timezone, @default_timezone)
    interval = Keyword.get_lazy(opts, :bucket_interval, fn -> bucket_interval(window) end)
    filters = Keyword.get(opts, :filters, [])

    workspace_id
    |> timeseries_rows(metric, window, interval, timezone, filters)
    |> Enum.map(&timeseries_bucket(&1, interval))
  end

  @doc """
  Aggregates `ga_sessions` for a window into rate/duration metrics and
  entry/exit page tallies.

  Returns `%{sessions:, bounce_rate:, avg_duration:, engaged_rate:,
  entry_pages: %{path => count}, exit_pages: %{path => count}}`. Rates are
  floats in `0.0..1.0`; an empty window yields all-zero metrics and empty
  page maps. Options: `:window` (required), `:filters`,
  `:include_page_tallies` (boolean, default `true`; pass `false` to return only
  the headline aggregate without `entry_pages`/`exit_pages`, saving two
  queries).
  """
  @spec session_metrics(Ecto.UUID.t(), keyword()) :: map()
  def session_metrics(workspace_id, opts) when is_binary(workspace_id) do
    window = TimeWindow.fetch!(opts)
    filters = Keyword.get(opts, :filters, [])
    repo = Repo.repo()

    aggregate = session_headline_metrics(repo, workspace_id, window, filters)

    if Keyword.get(opts, :include_page_tallies, true) do
      Map.merge(aggregate, %{
        entry_pages: page_tally(repo, workspace_id, window, :entry_page, filters),
        exit_pages: page_tally(repo, workspace_id, window, :exit_page, filters)
      })
    else
      aggregate
    end
  end

  defp session_headline_metrics(repo, workspace_id, window, filters) do
    from(s in Session,
      where: s.workspace_id == ^workspace_id,
      where: s.started_at >= ^window.start_at and s.started_at < ^window.end_at,
      select: %{
        sessions: count(s.id),
        bounce_rate: type(coalesce(avg(fragment("(?)::int", s.is_bounce)), 0.0), :float),
        avg_duration: type(coalesce(avg(s.duration_seconds), 0.0), :float),
        engaged_rate: type(coalesce(avg(fragment("(?)::int", s.is_engaged)), 0.0), :float)
      }
    )
    |> apply_session_filters(filters)
    |> repo.one(prefix: GoodAnalytics.schema_name())
    |> case do
      nil -> %{sessions: 0, bounce_rate: 0.0, avg_duration: 0.0, engaged_rate: 0.0}
      row -> row
    end
  end

  @doc """
  Raw KPI counts for one window, merged with session headline metrics.

  Returns `%{visitors:, new_visitors:, pageviews:, revenue:,
  identification_rate:, sessions:, bounce_rate:, avg_duration:,
  engaged_rate:}`. `identification_rate` is the simple in-window
  identified-over-total canonical-visitor ratio (a float in `0.0..1.0`);
  callers that need a matured-cohort policy or period-over-period deltas layer
  those on top. Options: `:window` (required).
  """
  @spec kpis(Ecto.UUID.t(), keyword()) :: map()
  def kpis(workspace_id, opts) when is_binary(workspace_id) do
    window = TimeWindow.fetch!(opts)
    filters = Keyword.get(opts, :filters, [])
    repo = Repo.repo()

    counts = active_event_metrics(repo, workspace_id, window, filters)
    new_visitors = new_visitors(repo, workspace_id, window, filters)

    sessions =
      session_metrics(workspace_id, window: window, filters: filters, include_page_tallies: false)

    %{
      visitors: counts.visitors,
      new_visitors: new_visitors,
      pageviews: counts.pageviews,
      revenue: counts.revenue,
      identification_rate: counts.identification_rate,
      sessions: sessions.sessions,
      bounce_rate: sessions.bounce_rate,
      avg_duration: sessions.avg_duration,
      engaged_rate: sessions.engaged_rate
    }
  end

  @conversion_event_columns ~w(device_type browser os source_platform source_medium source_campaign)a

  @doc "The dimensions `conversion_breakdown/3` supports, in declaration order."
  @spec conversion_dimensions() :: [atom()]
  def conversion_dimensions, do: @conversion_event_columns

  @doc """
  Sale-only conversion breakdown rows for a workspace window.

  Each row: `%{value:, sales:, visitors:, revenue_cents:, percentage:,
  conversion_rate:}`. `conversion_rate` is sale conversions over converting
  visitors for the bucket (a float `0.0..1.0`). `visitors` counts distinct
  canonical visitors among sale events (distinct from
  `GoodAnalytics.Core.Audience`'s `users`, which counts canonical visitors
  across all events). Dimension must be in `breakdown_dimensions/0`; unsupported
  dimensions raise `ArgumentError`. Options: `:window` (required), `:filters`.
  """
  @spec conversion_breakdown(Ecto.UUID.t(), atom(), keyword()) :: [map()]
  def conversion_breakdown(workspace_id, dimension, opts)
      when is_binary(workspace_id) and dimension in @conversion_event_columns do
    window = TimeWindow.fetch!(opts)
    filters = Keyword.get(opts, :filters, [])
    repo = Repo.repo()

    from(e in Event,
      as: :event,
      join: v in Visitor,
      as: :visitor,
      on: v.id == e.visitor_id and v.workspace_id == e.workspace_id,
      where: e.workspace_id == ^workspace_id,
      where: e.event_type == "sale",
      where: e.inserted_at >= ^window.start_at and e.inserted_at < ^window.end_at
    )
    |> apply_event_filters(filters)
    |> group_by([e], selected_as(:value))
    |> select([e, v], %{
      value: selected_as(type(coalesce(field(e, ^dimension), ^not_set()), :string), :value),
      sales: count(e.id),
      visitors: count(fragment("coalesce(?, ?)", v.merged_into_id, v.id), :distinct),
      revenue_cents: type(coalesce(sum(e.amount_cents), 0), :integer)
    })
    |> repo.all(prefix: GoodAnalytics.schema_name())
    |> with_revenue_percentage()
    |> with_conversion_rate()
  end

  def conversion_breakdown(workspace_id, dimension, _opts)
      when is_binary(workspace_id) and dimension in @breakdown_dimensions do
    raise ArgumentError,
          "conversion_breakdown/3 supports #{inspect(conversion_dimensions())}; got #{inspect(dimension)}"
  end

  def conversion_breakdown(workspace_id, dimension, _opts) when is_binary(workspace_id) do
    raise ArgumentError, "unknown breakdown dimension: #{inspect(dimension)}"
  end

  @doc "Counts pageview events in a workspace window. Options: `:window`."
  @spec pageviews(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def pageviews(workspace_id, opts) when is_binary(workspace_id) do
    window = TimeWindow.fetch!(opts)

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: e.event_type == "pageview",
      where: e.inserted_at >= ^window.start_at and e.inserted_at < ^window.end_at,
      select: count(e.id)
    )
    |> Repo.repo().one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Sums sale-event revenue cents in a workspace window. Options: `:window`."
  @spec revenue(Ecto.UUID.t(), keyword()) :: non_neg_integer()
  def revenue(workspace_id, opts) when is_binary(workspace_id) do
    window = TimeWindow.fetch!(opts)

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: e.event_type == "sale",
      where: e.inserted_at >= ^window.start_at and e.inserted_at < ^window.end_at,
      select: coalesce(sum(e.amount_cents), 0)
    )
    |> Repo.repo().one(prefix: GoodAnalytics.schema_name())
    |> integer_value()
  end

  defp with_revenue_percentage(rows) do
    total = rows |> Enum.map(& &1.revenue_cents) |> Enum.sum()

    Enum.map(rows, fn row ->
      pct = if total == 0, do: 0.0, else: Float.round(row.revenue_cents / total * 100.0, 2)
      Map.put(row, :percentage, pct)
    end)
  end

  # conversion_rate = sale conversions / converting visitors for the bucket.
  # (One converting visitor with N sale events => rate N/visitors.)
  defp with_conversion_rate(rows) do
    Enum.map(rows, fn row ->
      rate = if row.visitors == 0, do: 0.0, else: row.sales / row.visitors
      Map.put(row, :conversion_rate, rate)
    end)
  end

  defp active_event_metrics(repo, workspace_id, window, filters) do
    from(e in Event,
      join: v in Visitor,
      on: v.id == e.visitor_id and v.workspace_id == e.workspace_id,
      where: e.workspace_id == ^workspace_id,
      where: e.inserted_at >= ^window.start_at and e.inserted_at < ^window.end_at,
      select: %{
        visitors: count(fragment("coalesce(?, ?)", v.merged_into_id, v.id), :distinct),
        identified_visitors:
          count(
            fragment(
              "CASE WHEN ? IS NOT NULL THEN coalesce(?, ?) END",
              v.identified_at,
              v.merged_into_id,
              v.id
            ),
            :distinct
          ),
        pageviews: filter(count(e.id), e.event_type == "pageview"),
        revenue:
          type(
            coalesce(
              sum(
                fragment(
                  "CASE WHEN ? = 'sale' THEN coalesce(?, 0) ELSE 0 END",
                  e.event_type,
                  e.amount_cents
                )
              ),
              0
            ),
            :integer
          )
      }
    )
    |> apply_event_filters(filters)
    |> repo.one(prefix: GoodAnalytics.schema_name())
    |> case do
      nil ->
        %{visitors: 0, pageviews: 0, revenue: 0, identification_rate: 0.0}

      row ->
        visitors = row.visitors

        %{
          visitors: visitors,
          pageviews: integer_value(row.pageviews),
          revenue: integer_value(row.revenue),
          identification_rate: if(visitors > 0, do: row.identified_visitors / visitors, else: 0.0)
        }
    end
  end

  defp new_visitors(repo, workspace_id, window, filters) do
    from(e in Event,
      join: v in Visitor,
      on: v.id == e.visitor_id and v.workspace_id == e.workspace_id,
      where: e.workspace_id == ^workspace_id,
      where: v.first_seen_at >= ^window.start_at and v.first_seen_at < ^window.end_at,
      where: e.inserted_at >= ^window.start_at and e.inserted_at < ^window.end_at,
      select: count(fragment("coalesce(?, ?)", v.merged_into_id, v.id), :distinct)
    )
    |> apply_event_filters(filters)
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  defp page_tally(repo, workspace_id, window, column, filters) do
    from(s in Session,
      where: s.workspace_id == ^workspace_id,
      where: s.started_at >= ^window.start_at and s.started_at < ^window.end_at,
      where: not is_nil(field(s, ^column)),
      group_by: field(s, ^column),
      select: {field(s, ^column), count(s.id)}
    )
    |> apply_session_filters(filters)
    |> repo.all(prefix: GoodAnalytics.schema_name())
    |> Map.new()
  end

  defp normalize_metric!(metric)
       when metric in [:visitors, :pageviews, :revenue, :sessions, :engaged],
       do: metric

  defp normalize_metric!(metric) do
    raise ArgumentError, "unsupported analytics timeseries metric: #{inspect(metric)}"
  end

  defp timeseries_rows(workspace_id, :visitors, window, interval, timezone, filters) do
    {filter_sql, filter_params} = timeseries_filter_sql(filters, 6)

    sql = """
    WITH params AS (
      SELECT
        $1::uuid AS workspace_id,
        $2::timestamptz AS start_at,
        $3::timestamptz AS end_at,
        $4::text AS timezone,
        make_interval(secs => $5::int) AS bucket_interval,
        '2000-01-03 00:00:00'::timestamp AS origin
    ),
    bounds AS (
      SELECT
        date_bin(bucket_interval, start_at AT TIME ZONE timezone, origin) AS local_start,
        date_bin(bucket_interval, (end_at AT TIME ZONE timezone) - interval '1 microsecond', origin) AS local_end
      FROM params
    ),
    buckets AS (
      SELECT generate_series(bounds.local_start, bounds.local_end, params.bucket_interval) AS local_start
      FROM bounds, params
    ),
    values AS (
      SELECT
        date_bin(params.bucket_interval, e.inserted_at AT TIME ZONE params.timezone, params.origin) AS local_start,
        count(DISTINCT coalesce(v.merged_into_id, v.id)) AS value
      FROM params
      JOIN good_analytics.ga_events e ON e.workspace_id = params.workspace_id
      JOIN good_analytics.ga_visitors v ON v.id = e.visitor_id AND v.workspace_id = e.workspace_id
      WHERE e.inserted_at >= params.start_at AND e.inserted_at < params.end_at
        #{filter_sql}
      GROUP BY 1
    )
    SELECT
      buckets.local_start AT TIME ZONE params.timezone AS bucket_start,
      (buckets.local_start + params.bucket_interval) AT TIME ZONE params.timezone AS bucket_end,
      coalesce(values.value, 0) AS value
    FROM params, buckets
    LEFT JOIN values ON values.local_start = buckets.local_start
    ORDER BY buckets.local_start
    """

    query_timeseries(sql, workspace_id, window, interval, timezone, filter_params)
  end

  defp timeseries_rows(workspace_id, metric, window, interval, timezone, filters)
       when metric in [:pageviews, :revenue] do
    {event_type, aggregate} =
      case metric do
        :pageviews -> {"pageview", "count(e.id)"}
        :revenue -> {"sale", "coalesce(sum(e.amount_cents), 0)"}
      end

    {filter_sql, filter_params} = timeseries_filter_sql(filters, 7)

    sql = """
    WITH params AS (
      SELECT
        $1::uuid AS workspace_id,
        $2::timestamptz AS start_at,
        $3::timestamptz AS end_at,
        $4::text AS timezone,
        make_interval(secs => $5::int) AS bucket_interval,
        $6::text AS event_type,
        '2000-01-03 00:00:00'::timestamp AS origin
    ),
    bounds AS (
      SELECT
        date_bin(bucket_interval, start_at AT TIME ZONE timezone, origin) AS local_start,
        date_bin(bucket_interval, (end_at AT TIME ZONE timezone) - interval '1 microsecond', origin) AS local_end
      FROM params
    ),
    buckets AS (
      SELECT generate_series(bounds.local_start, bounds.local_end, params.bucket_interval) AS local_start
      FROM bounds, params
    ),
    values AS (
      SELECT
        date_bin(params.bucket_interval, e.inserted_at AT TIME ZONE params.timezone, params.origin) AS local_start,
        #{aggregate} AS value
      FROM params
      JOIN good_analytics.ga_events e ON e.workspace_id = params.workspace_id
      WHERE e.event_type = params.event_type
        AND e.inserted_at >= params.start_at
        AND e.inserted_at < params.end_at
        #{filter_sql}
      GROUP BY 1
    )
    SELECT
      buckets.local_start AT TIME ZONE params.timezone AS bucket_start,
      (buckets.local_start + params.bucket_interval) AT TIME ZONE params.timezone AS bucket_end,
      coalesce(values.value, 0) AS value
    FROM params, buckets
    LEFT JOIN values ON values.local_start = buckets.local_start
    ORDER BY buckets.local_start
    """

    query_timeseries(sql, workspace_id, window, interval, timezone, [event_type | filter_params])
  end

  # Session-grain series group ga_sessions by started_at; event-grain filters do not apply.
  defp timeseries_rows(workspace_id, metric, window, interval, timezone, _filters)
       when metric in [:sessions, :engaged] do
    aggregate =
      case metric do
        :sessions -> "count(s.id)"
        :engaged -> "count(s.id) FILTER (WHERE s.is_engaged)"
      end

    sql = """
    WITH params AS (
      SELECT
        $1::uuid AS workspace_id,
        $2::timestamptz AS start_at,
        $3::timestamptz AS end_at,
        $4::text AS timezone,
        make_interval(secs => $5::int) AS bucket_interval,
        '2000-01-03 00:00:00'::timestamp AS origin
    ),
    bounds AS (
      SELECT
        date_bin(bucket_interval, start_at AT TIME ZONE timezone, origin) AS local_start,
        date_bin(bucket_interval, (end_at AT TIME ZONE timezone) - interval '1 microsecond', origin) AS local_end
      FROM params
    ),
    buckets AS (
      SELECT generate_series(bounds.local_start, bounds.local_end, params.bucket_interval) AS local_start
      FROM bounds, params
    ),
    values AS (
      SELECT
        date_bin(params.bucket_interval, s.started_at AT TIME ZONE params.timezone, params.origin) AS local_start,
        #{aggregate} AS value
      FROM params
      JOIN good_analytics.ga_sessions s ON s.workspace_id = params.workspace_id
      WHERE s.started_at >= params.start_at AND s.started_at < params.end_at
      GROUP BY 1
    )
    SELECT
      buckets.local_start AT TIME ZONE params.timezone AS bucket_start,
      (buckets.local_start + params.bucket_interval) AT TIME ZONE params.timezone AS bucket_end,
      coalesce(values.value, 0) AS value
    FROM params, buckets
    LEFT JOIN values ON values.local_start = buckets.local_start
    ORDER BY buckets.local_start
    """

    query_timeseries(sql, workspace_id, window, interval, timezone, [])
  end

  defp apply_session_filters(query, filters) do
    filters
    |> session_supported_filters()
    |> Enum.reduce(query, &apply_session_filter/2)
  end

  defp session_supported_filters(filters) do
    Enum.filter(filters, fn
      {field, _value} -> session_filter_field?(field)
      {field, _operator, _value} -> session_filter_field?(field)
      _filter -> false
    end)
  end

  defp session_filter_field?(field), do: field in @session_filter_fields

  defp apply_session_filter({field, value}, query),
    do: apply_session_filter({field, :eq, value}, query)

  defp apply_session_filter({field, operator, value}, query) do
    session_filter_condition(query, field, operator, value)
  end

  defp session_filter_condition(query, :click_id, :eq, value)
       when is_binary(value) and value != "",
       do: where(query, [s], fragment("?::text", field(s, ^:click_id)) == ^value)

  defp session_filter_condition(query, :click_id, :neq, value)
       when is_binary(value) and value != "",
       do: where(query, [s], fragment("?::text", field(s, ^:click_id)) != ^value)

  defp session_filter_condition(query, :click_id, :in, values)
       when is_list(values) and values != [] do
    values = Enum.map(values, &to_string/1)
    where(query, [s], fragment("?::text", field(s, ^:click_id)) in ^values)
  end

  defp session_filter_condition(query, :click_id, :not_in, values)
       when is_list(values) and values != [] do
    values = Enum.map(values, &to_string/1)
    where(query, [s], fragment("?::text", field(s, ^:click_id)) not in ^values)
  end

  defp session_filter_condition(query, :click_id, :ilike, value)
       when is_binary(value) and value != "" do
    pattern = "%" <> escape_like(value) <> "%"
    where(query, [s], fragment("?::text ILIKE ? ESCAPE '\\'", field(s, ^:click_id), ^pattern))
  end

  defp session_filter_condition(query, field, :eq, value)
       when is_binary(value) and value != "",
       do: where(query, [s], field(s, ^field) == ^value)

  defp session_filter_condition(query, field, :neq, value)
       when is_binary(value) and value != "",
       do: where(query, [s], field(s, ^field) != ^value)

  defp session_filter_condition(query, field, :in, values)
       when is_list(values) and values != [] do
    values = Enum.map(values, &to_string/1)
    where(query, [s], field(s, ^field) in ^values)
  end

  defp session_filter_condition(query, field, :not_in, values)
       when is_list(values) and values != [] do
    values = Enum.map(values, &to_string/1)
    where(query, [s], field(s, ^field) not in ^values)
  end

  defp session_filter_condition(query, field, :ilike, value)
       when is_binary(value) and value != "" do
    pattern = "%" <> escape_like(value) <> "%"
    where(query, [s], fragment("? ILIKE ? ESCAPE '\\'", field(s, ^field), ^pattern))
  end

  defp session_filter_condition(query, _field, _operator, _value), do: query

  # Applies filters to a sale-event Ecto query as WHERE conditions, matching
  # `build_timeseries_condition/4`'s operator semantics but as Ecto expressions.
  # Filters arrive as either `{field, value}` (implicit `:eq`) or
  # `{field, operator, value}`. `:inserted_at` is skipped (the window already
  # constrains time); any field not in `@event_filter_fields` is skipped.
  defp apply_event_filters(query, filters) do
    Enum.reduce(filters, query, &apply_event_filter/2)
  end

  defp apply_event_filter({field, value}, query),
    do: apply_event_filter({field, :eq, value}, query)

  defp apply_event_filter({field, operator, value}, query)
       when field in @event_filter_fields and field != :inserted_at do
    event_filter_condition(query, field, operator, value)
  end

  defp apply_event_filter(_filter, query), do: query

  # `link_id` is a uuid column; the filter value is a string, so compare against
  # the cast text (matching how `timeseries_filter_field/1` emits
  # `e.link_id::text`).
  defp event_filter_condition(query, :link_id, :eq, value)
       when is_binary(value) and value != "",
       do: where(query, [e], fragment("?::text", field(e, ^:link_id)) == ^value)

  defp event_filter_condition(query, :link_id, :neq, value)
       when is_binary(value) and value != "",
       do: where(query, [e], fragment("?::text", field(e, ^:link_id)) != ^value)

  defp event_filter_condition(query, field, :eq, value)
       when is_binary(value) and value != "",
       do: where(query, [e], field(e, ^field) == ^value)

  defp event_filter_condition(query, field, :neq, value)
       when is_binary(value) and value != "",
       do: where(query, [e], field(e, ^field) != ^value)

  defp event_filter_condition(query, field, :in, values)
       when is_list(values) and values != [] do
    values = Enum.map(values, &to_string/1)
    where(query, [e], field(e, ^field) in ^values)
  end

  defp event_filter_condition(query, field, :not_in, values)
       when is_list(values) and values != [] do
    values = Enum.map(values, &to_string/1)
    where(query, [e], field(e, ^field) not in ^values)
  end

  defp event_filter_condition(query, field, :ilike, value)
       when is_binary(value) and value != "" do
    pattern = "%" <> escape_like(value) <> "%"
    where(query, [e], fragment("? ILIKE ? ESCAPE '\\'", field(e, ^field), ^pattern))
  end

  defp event_filter_condition(query, _field, _operator, _value), do: query

  # Filters arrive as either a `{field, value}` tuple (implicit `:eq`) or an
  # operator-tagged `{field, operator, value}` tuple. The `:inserted_at` field is
  # always rejected (it is the time axis). Supported operators are `:eq`, `:neq`,
  # `:in`, `:not_in`, and `:ilike` (with literal escaping). Only allowlisted
  # columns from `@event_filter_fields` are emitted, and values bind as `$N`
  # params.
  defp timeseries_filter_sql(filters, first_param_index) do
    filters
    |> Enum.reduce({"", [], first_param_index}, fn filter, {sql, params, index} ->
      case timeseries_filter_condition(filter, index) do
        {:ok, condition, value} ->
          {"#{sql}\n        AND #{condition}", params ++ [value], index + 1}

        :skip ->
          {sql, params, index}
      end
    end)
    |> then(fn {sql, params, _index} -> {sql, params} end)
  end

  defp timeseries_filter_condition({field, value}, index),
    do: timeseries_filter_condition({field, :eq, value}, index)

  defp timeseries_filter_condition({field, operator, value}, index)
       when field in @event_filter_fields and field != :inserted_at do
    build_timeseries_condition(timeseries_filter_field(field), operator, value, index)
  end

  defp timeseries_filter_condition(_filter, _index), do: :skip

  defp build_timeseries_condition(sql_field, :eq, value, index)
       when is_binary(value) and value != "",
       do: {:ok, "#{sql_field} = $#{index}", value}

  defp build_timeseries_condition(sql_field, :neq, value, index)
       when is_binary(value) and value != "",
       do: {:ok, "#{sql_field} != $#{index}", value}

  defp build_timeseries_condition(sql_field, :in, values, index)
       when is_list(values) and values != [],
       do: {:ok, "#{sql_field} = ANY($#{index}::text[])", Enum.map(values, &to_string/1)}

  defp build_timeseries_condition(sql_field, :not_in, values, index)
       when is_list(values) and values != [],
       do: {:ok, "NOT (#{sql_field} = ANY($#{index}::text[]))", Enum.map(values, &to_string/1)}

  defp build_timeseries_condition(sql_field, :ilike, value, index)
       when is_binary(value) and value != "",
       do:
         {:ok, "#{sql_field} ILIKE $#{index} ESCAPE '\\'",
          "%#{GoodAnalytics.SQL.escape_like(value)}%"}

  defp build_timeseries_condition(_sql_field, _operator, _value, _index), do: :skip

  defp timeseries_filter_field(:link_id), do: "e.link_id::text"
  defp timeseries_filter_field(field), do: "e.#{field}"

  # Sobelow: `sql` is built from module-internal heredocs plus
  # `timeseries_filter_sql/2`, which emits only allowlisted column names from
  # `@event_filter_fields` and `$N` placeholders. No user value is interpolated.
  defp query_timeseries(sql, workspace_id, window, interval, timezone, extra_params) do
    params = [
      dump_uuid!(workspace_id),
      window.start_at,
      window.end_at,
      timezone,
      interval.seconds
      | extra_params
    ]

    %{rows: rows} = Repo.repo().query!(sql, params, prefix: GoodAnalytics.schema_name())
    rows
  end

  defp timeseries_bucket([bucket_start, bucket_end, value], interval) do
    %{
      bucket_start: bucket_start,
      bucket_end: bucket_end,
      interval: interval,
      value: integer_value(value)
    }
  end

  defp target_bucket_count(window_seconds) do
    cond do
      window_seconds <= 60 * 60 -> 60
      window_seconds <= 24 * 60 * 60 -> 24
      true -> 60
    end
  end

  # Sobelow: `sql` is a module-internal literal; the only param is `$N`-bound.
  @doc false
  defp query_aligned_bucket_start(interval_seconds, datetime, timezone) do
    %{rows: [[bucket_start]]} =
      Repo.repo().query!(
        """
        SELECT date_bin(make_interval(secs => $1::int), $2::timestamptz AT TIME ZONE $3, '2000-01-03 00:00:00'::timestamp) AT TIME ZONE $3
        """,
        [interval_seconds, datetime, timezone],
        prefix: GoodAnalytics.schema_name()
      )

    bucket_start
  end
end
