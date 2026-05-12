defmodule GoodAnalytics.Core.Funnels.QueryTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Funnels.{Funnel, Query, Step, Filter}

  @workspace_id "00000000-0000-0000-0000-000000000001"

  defp build_funnel(steps, opts \\ []) do
    %Funnel{
      id: "00000000-0000-0000-0000-000000000099",
      workspace_id: @workspace_id,
      name: "Test Funnel",
      conversion_window_days: Keyword.get(opts, :conversion_window_days, 7),
      cohort_source_filter: Keyword.get(opts, :cohort_source_filter, nil),
      steps:
        Enum.map(steps, fn {kind, label, filters} ->
          %Step{
            kind: kind,
            label: label,
            filters:
              Enum.map(filters, fn attrs ->
                struct!(Filter, attrs)
              end)
          }
        end)
    }
  end

  describe "build_sql/2 with 2-step funnel" do
    test "generates valid SQL with 2 CTEs" do
      funnel =
        build_funnel([
          {"event", "Pageview", [%{type: "event", event_type: "pageview"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      window_start = ~U[2026-01-01 00:00:00Z]
      window_end = ~U[2026-01-31 23:59:59Z]

      {sql, params} = Query.build_sql(funnel, window_start: window_start, window_end: window_end)

      assert sql =~ "step_1 AS"
      assert sql =~ "step_2 AS"
      assert sql =~ "UNION ALL"
      assert sql =~ "ORDER BY step_index"

      # Base params: workspace_id, window_start, window_end, conversion_window_days
      assert Enum.at(params, 0) == @workspace_id
      assert Enum.at(params, 1) == window_start
      assert Enum.at(params, 2) == window_end
      assert Enum.at(params, 3) == 7
    end

    test "uses INTERVAL '1 day' multiplication instead of string concat" do
      funnel =
        build_funnel([
          {"event", "Pageview", [%{type: "event", event_type: "pageview"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, _params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "$4 * INTERVAL '1 day'"
      refute sql =~ "|| ' days'"
    end

    test "step_2 uses s1 from FROM clause (no duplicate JOIN)" do
      funnel =
        build_funnel([
          {"event", "PV", [%{type: "event", event_type: "pageview"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, _params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      # Extract just the step_2 CTE body (between "step_2 AS" and "SELECT *")
      [_, step_2_rest] = String.split(sql, "step_2 AS", parts: 2)
      step_2_body = String.split(step_2_rest, "SELECT *") |> List.first()

      assert step_2_body =~ "FROM step_1 s1"
      refute step_2_body =~ "JOIN step_1 s1"
    end

    test "step_3+ has explicit JOIN step_1 s1" do
      funnel =
        build_funnel([
          {"event", "PV", [%{type: "event", event_type: "pageview"}]},
          {"event", "Lead", [%{type: "event", event_type: "lead"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, _params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      step_3_cte = String.split(sql, "step_3 AS") |> List.last()
      assert step_3_cte =~ "JOIN step_1 s1"
    end
  end

  describe "build_sql/2 with 3-step funnel" do
    test "generates 3 CTEs" do
      funnel =
        build_funnel([
          {"event", "PV", [%{type: "event", event_type: "pageview"}]},
          {"event", "Lead", [%{type: "event", event_type: "lead"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, _params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "step_1 AS"
      assert sql =~ "step_2 AS"
      assert sql =~ "step_3 AS"
    end
  end

  describe "build_sql/2 filter types" do
    test "url equals filter" do
      funnel =
        build_funnel([
          {"url", "Pricing", [%{type: "url", match: "equals", value: "/pricing"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "e.url ="
      assert "/pricing" in params
    end

    test "url starts_with filter" do
      funnel =
        build_funnel([
          {"url", "Blog", [%{type: "url", match: "starts_with", value: "/blog"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "e.url LIKE"
      assert "/blog%" in params
    end

    test "url regex filter" do
      funnel =
        build_funnel([
          {"url", "Posts", [%{type: "url", match: "regex", value: "/posts/\\d+"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "e.url ~"
      assert "/posts/\\d+" in params
    end

    test "property eq filter" do
      funnel =
        build_funnel([
          {"property", "Plan", [%{type: "property", key: "plan", op: "eq", value: "pro"}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "e.properties->>"
      assert "plan" in params
      assert "pro" in params
    end

    test "property in filter" do
      funnel =
        build_funnel([
          {"property", "Plan", [%{type: "property", key: "plan", op: "in", values: ["pro", "enterprise"]}]},
          {"event", "Sale", [%{type: "event", event_type: "sale"}]}
        ])

      {sql, params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "ANY("
      assert "plan" in params
      assert ["pro", "enterprise"] in params
    end

    test "cohort source filter applied to step 1" do
      funnel =
        build_funnel(
          [
            {"event", "PV", [%{type: "event", event_type: "pageview"}]},
            {"event", "Sale", [%{type: "event", event_type: "sale"}]}
          ],
          cohort_source_filter: %GoodAnalytics.Core.Funnels.CohortSourceFilter{
            platform: "google",
            medium: "cpc",
            campaign: nil
          }
        )

      {sql, params} = Query.build_sql(funnel, window_start: ~U[2026-01-01 00:00:00Z], window_end: ~U[2026-01-31 23:59:59Z])

      assert sql =~ "e.source_platform"
      assert sql =~ "e.source_medium"
      assert "google" in params
      assert "cpc" in params
    end
  end
end
