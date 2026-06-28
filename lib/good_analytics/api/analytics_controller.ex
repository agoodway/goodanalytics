defmodule GoodAnalytics.Api.AnalyticsController do
  @moduledoc """
  Read-analytics endpoints over the consolidated core read layer
  (`GoodAnalytics.Core.Audience` and `GoodAnalytics.Core.Analytics`).

  All actions are workspace-scoped via `conn.assigns.workspace_id` (set by
  `GoodAnalytics.Api.AuthPlug`) and validate query params with
  `OpenApiSpex.Plug.CastAndValidate`, which casts the `from`/`to` RFC3339
  parameters to `DateTime` structs and rejects malformed or missing values
  with 422 before an action runs.
  """
  use Phoenix.Controller, formats: [:json]

  alias GoodAnalytics.Api.Schemas
  alias GoodAnalytics.Core.Analytics
  alias GoodAnalytics.Core.Audience
  alias OpenApiSpex.Operation

  plug(OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true)

  @interval_by_label %{
    "1m" => %{key: :minute, label: "1m", seconds: 60},
    "5m" => %{key: :minute_5, label: "5m", seconds: 300},
    "15m" => %{key: :minute_15, label: "15m", seconds: 900},
    "30m" => %{key: :minute_30, label: "30m", seconds: 1800},
    "1h" => %{key: :hour, label: "1h", seconds: 3600},
    "2h" => %{key: :hour_2, label: "2h", seconds: 7200},
    "3h" => %{key: :hour_3, label: "3h", seconds: 10_800},
    "6h" => %{key: :hour_6, label: "6h", seconds: 21_600},
    "12h" => %{key: :hour_12, label: "12h", seconds: 43_200},
    "1d" => %{key: :day, label: "1d", seconds: 86_400},
    "2d" => %{key: :day_2, label: "2d", seconds: 172_800},
    "1w" => %{key: :week, label: "1w", seconds: 604_800},
    "2w" => %{key: :week_2, label: "2w", seconds: 1_209_600},
    "1mo" => %{key: :month, label: "1mo", seconds: 2_592_000}
  }

  # ── OpenApiSpex operations ──

  def open_api_operation(:breakdown) do
    %Operation{
      tags: ["Analytics"],
      summary: "Audience breakdown by dimension",
      description: """
      Returns per-bucket counts for a dimension. Two metric grains are mixed in
      a single response: event-grain metrics (events, pageviews, users) are
      counted by event inserted_at, while session-grain metrics (sessions,
      bounce_rate, avg_duration, engaged_rate) are counted by session
      started_at — so mixed-grain totals cover slightly different populations.
      Session-grain fields are null for buckets that have no matching session.
      """,
      operationId: "analyticsBreakdown",
      parameters: [
        Operation.parameter(
          :dimension,
          :query,
          %OpenApiSpex.Schema{
            type: :string,
            enum: ~w(device_type browser os source_platform source_medium source_campaign country)
          },
          "Dimension to group by",
          required: true
        ),
        Operation.parameter(
          :from,
          :query,
          %OpenApiSpex.Schema{type: :string, format: :"date-time"},
          "Inclusive window start (RFC3339)",
          required: true
        ),
        Operation.parameter(
          :to,
          :query,
          %OpenApiSpex.Schema{type: :string, format: :"date-time"},
          "Exclusive window end (RFC3339)",
          required: true
        ),
        Operation.parameter(
          :metrics,
          :query,
          %OpenApiSpex.Schema{type: :string},
          "Comma-separated metric list"
        ),
        Operation.parameter(
          :filter,
          :query,
          %OpenApiSpex.Schema{type: :string},
          "Drilldown filter as 'dimension:value' (e.g. device_type:mobile)"
        ),
        Operation.parameter(
          :limit,
          :query,
          %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
          "Max rows"
        ),
        Operation.parameter(
          :order,
          :query,
          %OpenApiSpex.Schema{type: :string, enum: ~w(asc desc), default: "desc"},
          "Sort direction on the first metric"
        )
      ],
      responses: %{
        200 => Operation.response("Breakdown", "application/json", Schemas.BreakdownResponse),
        401 => Operation.response("Unauthorized", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Invalid parameters", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:timeseries) do
    %Operation{
      tags: ["Analytics"],
      summary: "Bucketed timeseries for a metric",
      description: """
      Returns a zero-filled list of time buckets for one metric. Buckets are
      aligned to midnight (or the nearest interval boundary) in the requested
      timezone and zero-filled so every bucket in the window is always present.
      """,
      operationId: "analyticsTimeseries",
      parameters: [
        Operation.parameter(
          :metric,
          :query,
          %OpenApiSpex.Schema{
            type: :string,
            enum: ~w(visitors pageviews revenue sessions engaged)
          },
          "Metric to bucket",
          required: true
        ),
        Operation.parameter(
          :from,
          :query,
          %OpenApiSpex.Schema{type: :string, format: :"date-time"},
          "Inclusive window start",
          required: true
        ),
        Operation.parameter(
          :to,
          :query,
          %OpenApiSpex.Schema{type: :string, format: :"date-time"},
          "Exclusive window end",
          required: true
        ),
        Operation.parameter(
          :interval,
          :query,
          %OpenApiSpex.Schema{
            type: :string,
            enum: ~w(1m 5m 15m 30m 1h 2h 3h 6h 12h 1d 2d 1w 2w 1mo)
          },
          "Optional bucket size, e.g. 1h"
        ),
        Operation.parameter(
          :timezone,
          :query,
          %OpenApiSpex.Schema{type: :string, default: "Etc/UTC"},
          "IANA timezone"
        )
      ],
      responses: %{
        200 => Operation.response("Timeseries", "application/json", Schemas.TimeseriesResponse),
        401 => Operation.response("Unauthorized", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Invalid parameters", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:summary) do
    %Operation{
      tags: ["Analytics"],
      summary: "Headline KPIs for a window",
      description: """
      Returns headline KPIs for the given window. Event-grain metrics
      (visitors, new_visitors, pageviews, revenue) are counted by event
      inserted_at, while session-grain metrics (sessions, bounce_rate,
      avg_duration, engaged_rate) are counted by session started_at — so
      mixed-grain totals cover slightly different populations. Session-grain
      floats are coalesced to 0.0 when no sessions exist in the window.
      """,
      operationId: "analyticsSummary",
      parameters: [
        Operation.parameter(
          :from,
          :query,
          %OpenApiSpex.Schema{type: :string, format: :"date-time"},
          "Inclusive window start",
          required: true
        ),
        Operation.parameter(
          :to,
          :query,
          %OpenApiSpex.Schema{type: :string, format: :"date-time"},
          "Exclusive window end",
          required: true
        )
      ],
      responses: %{
        200 =>
          Operation.response("Summary", "application/json", Schemas.AnalyticsSummaryResponse),
        401 => Operation.response("Unauthorized", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Invalid parameters", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  @max_buckets 1500

  # ── Actions ──

  def breakdown(conn, params) do
    workspace_id = conn.assigns.workspace_id
    dimension = String.to_existing_atom(params.dimension)

    with :ok <- validate_window(params),
         {:ok, metrics} <- parse_metrics(params, Audience.metrics()),
         {:ok, filters} <- parse_filters(params, Audience.dimensions()),
         {:ok, rows} <- run_breakdown(workspace_id, dimension, metrics, filters, params) do
      json(conn, %{
        dimension: to_string(dimension),
        metrics: Enum.map(metrics, &to_string/1),
        rows: Enum.map(rows, &serialize_row/1)
      })
    else
      {:error, message} -> unprocessable(conn, message)
    end
  end

  # Core raises ArgumentError for invalid dimension/metric combinations (e.g.
  # :country with session metrics, or a filter on a session-less dimension with
  # session metrics); translate that into a 422 rather than a 500.
  defp run_breakdown(workspace_id, dimension, metrics, filters, params) do
    rows =
      Audience.breakdown(workspace_id, dimension,
        window: window(params),
        metrics: metrics,
        filters: filters,
        limit: Map.get(params, :limit, 50),
        order_by: {List.first(metrics), order(params)}
      )

    {:ok, rows}
  rescue
    e in ArgumentError -> {:error, sanitize_message(Exception.message(e))}
  end

  def timeseries(conn, params) do
    metric = String.to_existing_atom(params.metric)
    interval = resolve_interval(params)

    with :ok <- validate_window(params),
         :ok <- validate_bucket_count(params, interval),
         {:ok, points} <- run_timeseries(conn.assigns.workspace_id, metric, params, interval) do
      json(conn, %{
        metric: to_string(metric),
        interval: interval.label,
        points: Enum.map(points, &serialize_point/1)
      })
    else
      {:error, message} -> unprocessable(conn, message)
    end
  end

  defp run_timeseries(workspace_id, metric, params, interval) do
    points =
      Analytics.timeseries(workspace_id, metric,
        window: window(params),
        timezone: Map.get(params, :timezone, "Etc/UTC"),
        bucket_interval: interval
      )

    {:ok, points}
  rescue
    # The only caller-controlled value that reaches raw SQL here is `timezone`;
    # echo just that input (never the raw Postgres message) to avoid leaking
    # internals and to stay robust when `e.postgres` is nil (connection errors).
    _e in [Postgrex.Error] ->
      {:error, "invalid timezone: #{Map.get(params, :timezone, "Etc/UTC")}"}
  end

  def summary(conn, params) do
    case validate_window(params) do
      :ok -> json(conn, Analytics.kpis(conn.assigns.workspace_id, window: window(params)))
      {:error, message} -> unprocessable(conn, message)
    end
  end

  # ── Param helpers ──

  # `from`/`to` arrive as DateTime structs (cast + validated by CastAndValidate).
  defp window(params), do: %{start_at: params.from, end_at: params.to}

  defp order(params) do
    case Map.get(params, :order, "desc") do
      "asc" -> :asc
      _ -> :desc
    end
  end

  # Comma-separated metric list, validated against the supported set. Absent ⇒
  # a single safe event metric so `:country` (which rejects session metrics)
  # works without an explicit list.
  defp parse_metrics(params, allowed) do
    case Map.get(params, :metrics) do
      nil ->
        {:ok, [:events]}

      csv ->
        requested = csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
        allowed_strings = Enum.map(allowed, &to_string/1)

        if requested != [] and Enum.all?(requested, &(&1 in allowed_strings)) do
          {:ok, Enum.map(requested, &String.to_existing_atom/1)}
        else
          {:error, "unknown metric in: #{csv}"}
        end
    end
  end

  # Single drilldown filter as "dimension:value". Absent ⇒ no filter.
  defp parse_filters(params, allowed) do
    case Map.get(params, :filter) do
      nil -> {:ok, []}
      raw -> validate_filter(raw, allowed)
    end
  end

  defp validate_filter(raw, allowed) do
    case String.split(raw, ":", parts: 2) do
      [field, value] when value != "" -> validate_filter_field(field, value, allowed)
      _ -> {:error, "invalid filter (expected 'dimension:value'): #{raw}"}
    end
  end

  defp validate_filter_field(field, value, allowed) do
    if field in Enum.map(allowed, &to_string/1) do
      {:ok, [{String.to_existing_atom(field), value}]}
    else
      {:error, "unknown filter dimension: #{field}"}
    end
  end

  # Resolve the requested interval label to a concrete bucket interval so the
  # response can echo the size actually used. An unrecognized label falls back
  # to core's window-derived default.
  defp resolve_interval(params) do
    case Map.get(params, :interval) do
      nil -> Analytics.bucket_interval(window(params))
      label -> Map.get(@interval_by_label, label) || Analytics.bucket_interval(window(params))
    end
  end

  defp validate_window(params) do
    if DateTime.compare(params.from, params.to) == :lt,
      do: :ok,
      else: {:error, "`from` must be before `to`"}
  end

  defp validate_bucket_count(params, interval) do
    span = DateTime.diff(params.to, params.from, :second)

    if div(span, interval.seconds) > @max_buckets,
      do:
        {:error,
         "interval too small for the requested window (would exceed #{@max_buckets} buckets)"},
      else: :ok
  end

  # Strip Elixir atom-inspect syntax (leading ':') so 422 bodies read naturally
  # for API clients (":country" -> "country").
  defp sanitize_message(message), do: Regex.replace(~r/:([a-zA-Z_]\w*)/, message, "\\1")

  defp unprocessable(conn, message) do
    conn |> put_status(422) |> json(%{error: message})
  end

  # ── Serialization ──

  # The core breakdown row is already a plain map of metric atoms → values that
  # Jason encodes with string keys; kept as a named seam for future rounding.
  defp serialize_row(row), do: row

  defp serialize_point(point), do: Map.take(point, [:bucket_start, :bucket_end, :value])
end
