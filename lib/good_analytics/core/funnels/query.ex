defmodule GoodAnalytics.Core.Funnels.Query do
  @moduledoc """
  Builds funnel analysis SQL queries.

  Generates one CTE per funnel step joined sequentially on canonical visitor
  identity with `inserted_at` bounds on every CTE for partition pruning.
  Canonical visitor identity is `COALESCE(ga_visitors.merged_into_id, ga_visitors.id)`.
  """

  alias GoodAnalytics.Core.Funnels.Funnel

  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @doc """
  Builds a parameterized SQL query and params list for funnel analysis.

  ## Options
    * `:window_start` - DateTime, start of analysis window (required)
    * `:window_end` - DateTime, end of analysis window (required)
    * `:cohort_source_filter` - optional map with platform/medium/campaign
  """
  def build_sql(%Funnel{} = funnel, opts) do
    window_start = Keyword.fetch!(opts, :window_start)
    window_end = Keyword.fetch!(opts, :window_end)
    cohort_filter = Keyword.get(opts, :cohort_source_filter, funnel.cohort_source_filter)

    # Start with base params: workspace_id, window_start, window_end, conversion_window_days
    # workspace_id is dumped to a 16-byte binary because raw `Repo.query!` bypasses Ecto's UUID casting.
    base_params = [
      Ecto.UUID.dump!(funnel.workspace_id),
      window_start,
      window_end,
      funnel.conversion_window_days
    ]

    {ctes, params} = build_ctes(funnel.steps, cohort_filter, base_params)
    step_count = length(funnel.steps)

    final_select = build_final_select(step_count)

    sql = "WITH #{Enum.join(ctes, ",\n")} #{final_select}"

    {sql, params}
  end

  defp build_ctes(steps, cohort_filter, base_params) do
    {ctes_reversed, params} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({[], base_params}, fn {step, index}, {ctes, params} ->
        {cte, params} = build_step_cte(step, index, cohort_filter, params)
        {[cte | ctes], params}
      end)

    {Enum.reverse(ctes_reversed), params}
  end

  defp build_step_cte(step, 1 = _index, cohort_filter, params) do
    {filter_sql, params} = build_step_filters(step, params, cohort_filter)

    cte = """
    step_1 AS (
      SELECT
        COALESCE(v.merged_into_id, v.id) AS canonical_visitor_id,
        MIN(e.inserted_at) AS step_at
      FROM #{@schema_prefix}.ga_events e
      JOIN #{@schema_prefix}.ga_visitors v ON v.id = e.visitor_id AND v.workspace_id = $1
      WHERE e.workspace_id = $1
        AND e.inserted_at BETWEEN $2 AND $3
        #{filter_sql}
      GROUP BY canonical_visitor_id
    )
    """

    {cte, params}
  end

  defp build_step_cte(step, index, _cohort_filter, params) do
    prev = index - 1
    {filter_sql, params} = build_step_filters(step, params, nil)

    # For step_2, s_prev IS s1, so no extra JOIN needed.
    # For step_3+, we must JOIN step_1 separately for the conversion window bound.
    step_1_join =
      if prev > 1 do
        "JOIN step_1 s1 ON s1.canonical_visitor_id = s#{prev}.canonical_visitor_id"
      else
        ""
      end

    cte = """
    step_#{index} AS (
      SELECT
        s#{prev}.canonical_visitor_id,
        MIN(e.inserted_at) AS step_at
      FROM step_#{prev} s#{prev}
      #{step_1_join}
      JOIN #{@schema_prefix}.ga_events e
        ON e.workspace_id = $1
        AND e.inserted_at BETWEEN $2 AND $3
        AND e.inserted_at > s#{prev}.step_at
        AND e.inserted_at <= s1.step_at + $4 * INTERVAL '1 day'
      JOIN #{@schema_prefix}.ga_visitors v
        ON v.id = e.visitor_id
        AND v.workspace_id = $1
        AND COALESCE(v.merged_into_id, v.id) = s#{prev}.canonical_visitor_id
      WHERE 1=1
        #{filter_sql}
      GROUP BY s#{prev}.canonical_visitor_id
    )
    """

    {cte, params}
  end

  defp build_final_select(step_count) do
    unions =
      1..step_count
      |> Enum.map(fn index ->
        median_expr =
          if index == step_count do
            "EXTRACT(EPOCH FROM PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY s#{index}.step_at - s1.step_at))::FLOAT"
          else
            "NULL::FLOAT"
          end

        join_step_1 =
          if index > 1 do
            "JOIN step_1 s1 ON s1.canonical_visitor_id = s#{index}.canonical_visitor_id"
          else
            ""
          end

        """
        SELECT #{index} AS step_index,
               COUNT(*) AS visitor_count,
               #{median_expr} AS median_time
        FROM step_#{index} s#{index}
        #{if index > 1, do: join_step_1, else: ""}
        """
      end)
      |> Enum.join(" UNION ALL ")

    "SELECT * FROM (#{unions}) t ORDER BY step_index"
  end

  defp build_step_filters(step, params, cohort_filter) do
    {filter_parts_reversed, params} =
      step.filters
      |> Enum.reduce({[], params}, fn filter, {parts, params} ->
        {sql, params} = filter_to_sql(filter, params)
        {[sql | parts], params}
      end)

    filter_parts = Enum.reverse(filter_parts_reversed)

    # Combine filter predicates with AND or OR based on step.combine
    combine_mode = step.combine || :all
    joiner = if combine_mode == :any, do: " OR ", else: " AND "

    combined =
      case filter_parts do
        [single] -> "(#{single})"
        parts -> "(" <> Enum.map_join(parts, joiner, &"(#{&1})") <> ")"
      end

    # Merge cohort source filter: wraps the combined group
    {cohort_parts, params} =
      case cohort_filter do
        %{} = cf ->
          source_filter_to_sql(cf, params)

        _ ->
          {[], params}
      end

    sql =
      case cohort_parts do
        [] ->
          "AND #{combined}"

        parts ->
          cohort_sql = Enum.join(parts, " AND ")
          "AND (#{cohort_sql}) AND #{combined}"
      end

    {sql, params}
  end

  defp filter_to_sql(%{type: "event"} = filter, params) do
    param_idx = length(params) + 1
    params = params ++ [filter.event_type]
    sql = "e.event_type = $#{param_idx}"

    case filter.event_name do
      nil ->
        {sql, params}

      name ->
        name_idx = length(params) + 1
        params = params ++ [name]
        {"(#{sql} AND e.event_name = $#{name_idx})", params}
    end
  end

  defp filter_to_sql(%{type: "url", match: "equals"} = filter, params) do
    col = url_column(filter)
    param_idx = length(params) + 1
    params = params ++ [filter.value]
    {"#{col} = $#{param_idx}", params}
  end

  defp filter_to_sql(%{type: "url", match: "starts_with"} = filter, params) do
    col = url_column(filter)
    param_idx = length(params) + 1
    params = params ++ [filter.value <> "%"]
    {"#{col} LIKE $#{param_idx}", params}
  end

  defp filter_to_sql(%{type: "url", match: "regex"} = filter, params) do
    col = url_column(filter)
    param_idx = length(params) + 1
    params = params ++ [filter.value]
    {"#{col} ~ $#{param_idx}", params}
  end

  defp filter_to_sql(%{type: "url", match: "in", values: values} = filter, params)
       when is_list(values) do
    col = url_column(filter)
    param_idx = length(params) + 1
    params = params ++ [values]
    {"#{col} = ANY($#{param_idx})", params}
  end

  defp filter_to_sql(%{type: "url", match: "in"}, params) do
    {"1=0", params}
  end

  defp filter_to_sql(%{type: "property", op: "eq"} = filter, params) do
    key_idx = length(params) + 1
    val_idx = key_idx + 1
    params = params ++ [filter.key, filter.value]
    {"e.properties->>$#{key_idx} = $#{val_idx}", params}
  end

  defp filter_to_sql(%{type: "property", op: "in"} = filter, params) do
    key_idx = length(params) + 1
    val_idx = key_idx + 1
    params = params ++ [filter.key, filter.values]
    {"e.properties->>$#{key_idx} = ANY($#{val_idx})", params}
  end

  defp filter_to_sql(%{type: "source"} = filter, params) do
    {parts, params} = source_filter_to_sql(filter, params)
    {Enum.join(parts, " AND "), params}
  end

  defp source_filter_to_sql(filter, params) do
    fields = [
      {:platform, "e.source_platform"},
      {:medium, "e.source_medium"},
      {:campaign, "e.source_campaign"}
    ]

    Enum.reduce(fields, {[], params}, fn {key, col}, {parts, params} ->
      value = get_filter_field(filter, key)

      case value do
        nil ->
          {parts, params}

        val ->
          idx = length(params) + 1
          params = params ++ [val]
          {parts ++ ["#{col} = $#{idx}"], params}
      end
    end)
  end

  defp get_filter_field(%{} = filter, key) when is_atom(key) do
    Map.get(filter, key)
  end

  # COALESCE fallbacks extract host/path from e.url for historical events
  # that predate the v07 migration (where host/path columns are NULL).
  defp url_column(%{scope: :host}) do
    "COALESCE(e.host, lower(split_part(split_part(split_part(split_part(e.url, '://', 2), '/', 1), '?', 1), '#', 1)))"
  end

  defp url_column(%{scope: :path}) do
    "COALESCE(e.path, NULLIF(split_part(split_part(regexp_replace(e.url, '^https?://[^/]+', ''), '?', 1), '#', 1), ''), '/')"
  end

  defp url_column(%{scope: :full_url}), do: "e.url"
end
