defmodule GoodAnalytics.Core.Funnels do
  @moduledoc """
  Context for funnel definition CRUD and analysis.
  """

  alias GoodAnalytics.Core.Funnels.Funnel
  alias GoodAnalytics.Core.Funnels.Query
  alias GoodAnalytics.Repo

  import Ecto.Query

  @doc "Creates a funnel definition for a workspace."
  def create_funnel(workspace_id, attrs) do
    repo = Repo.repo()

    %Funnel{id: Uniq.UUID.uuid7(), workspace_id: workspace_id}
    |> Funnel.changeset(attrs)
    |> repo.insert(prefix: GoodAnalytics.schema_name())
  end

  @doc "Updates a non-archived funnel."
  def update_funnel(%Funnel{archived_at: archived_at}, _attrs) when not is_nil(archived_at) do
    {:error, :archived}
  end

  def update_funnel(%Funnel{} = funnel, attrs) do
    repo = Repo.repo()

    funnel
    |> Funnel.changeset(attrs)
    |> repo.update(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a funnel by ID."
  def get_funnel(id) do
    Repo.repo().get(Funnel, id, prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a funnel by ID, raising if not found."
  def get_funnel!(id) do
    Repo.repo().get!(Funnel, id, prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a funnel by ID scoped to a workspace. Raises if not found."
  def get_funnel!(workspace_id, id) do
    Repo.repo().get_by!(Funnel, [id: id, workspace_id: workspace_id],
      prefix: GoodAnalytics.schema_name()
    )
  end

  @doc "Lists non-archived funnels for a workspace, ordered by inserted_at desc."
  def list_funnels(workspace_id, opts \\ []) do
    repo = Repo.repo()
    include_archived = Keyword.get(opts, :include_archived, false)

    query =
      from(f in Funnel,
        where: f.workspace_id == ^workspace_id,
        order_by: [desc: f.inserted_at]
      )

    query =
      if include_archived do
        query
      else
        from(f in query, where: is_nil(f.archived_at))
      end

    repo.all(query, prefix: GoodAnalytics.schema_name())
  end

  @doc "Archives a funnel (soft delete)."
  def archive_funnel(%Funnel{} = funnel) do
    repo = Repo.repo()

    funnel
    |> Ecto.Changeset.change(archived_at: DateTime.utc_now())
    |> repo.update(prefix: GoodAnalytics.schema_name())
  end

  def archive_funnel(workspace_id, id) when is_binary(workspace_id) and is_binary(id) do
    funnel = get_funnel!(workspace_id, id)
    archive_funnel(funnel)
  end

  @doc """
  Analyzes a funnel for the given time window.

  Returns a result map with per-step counts, conversion rates, and median time.

  ## Options
    * `:window_start` - start of analysis window (required)
    * `:window_end` - end of analysis window (required)
    * `:cohort_source_filter` - optional source filter applied to step 1
  """
  def analyze(%Funnel{} = funnel, opts) do
    repo = Repo.repo()
    {sql, params} = Query.build_sql(funnel, opts)

    result =
      repo.query!(sql, params, prefix: GoodAnalytics.schema_name())

    compute_analysis(funnel, result)
  end

  defp compute_analysis(funnel, result) do
    col_index = column_index(result.columns)

    step_counts =
      Enum.into(result.rows, %{}, fn row ->
        {Enum.at(row, col_index["step_index"]), Enum.at(row, col_index["visitor_count"])}
      end)

    step_count = length(funnel.steps)

    median_time =
      result.rows
      |> Enum.find(fn row -> Enum.at(row, col_index["step_index"]) == step_count end)
      |> case do
        nil -> nil
        row -> Enum.at(row, col_index["median_time"])
      end

    total_visitors = Map.get(step_counts, 1, 0)
    completed_visitors = Map.get(step_counts, step_count, 0)

    overall_conversion =
      if total_visitors == 0 do
        :no_visitors
      else
        completed_visitors / total_visitors
      end

    steps =
      funnel.steps
      |> Enum.with_index(1)
      |> Enum.map(fn {step, index} ->
        count = Map.get(step_counts, index, 0)
        prev_count = if index == 1, do: count, else: Map.get(step_counts, index - 1, 0)

        %{
          step_index: index,
          label: step.label,
          count: count,
          conversion_to_step_1:
            if(total_visitors == 0, do: 0.0, else: count / total_visitors),
          conversion_to_prev:
            if(prev_count == 0, do: 0.0, else: count / prev_count),
          drop_off: prev_count - count
        }
      end)

    %{
      steps: steps,
      total_visitors: total_visitors,
      completed_visitors: completed_visitors,
      overall_conversion: overall_conversion,
      median_time_seconds: median_time
    }
  end

  defp column_index(columns) do
    columns
    |> Enum.with_index()
    |> Map.new()
  end
end
