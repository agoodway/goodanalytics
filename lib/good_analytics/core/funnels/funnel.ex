defmodule GoodAnalytics.Core.Funnels.Funnel do
  @moduledoc """
  Funnel definition entity.

  A funnel is a workspace-scoped ordered set of step matchers used
  to measure visitor progression through a defined conversion path.
  Soft-archived via `archived_at`; no hard deletes.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GoodAnalytics.Core.Funnels.CohortSourceFilter
  alias GoodAnalytics.Core.Funnels.Step

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  schema "ga_funnels" do
    field(:workspace_id, Ecto.UUID)
    field(:name, :string)
    field(:description, :string)
    field(:conversion_window_days, :integer, default: 7)
    field(:archived_at, :utc_datetime_usec)

    embeds_one :cohort_source_filter, CohortSourceFilter, on_replace: :update
    embeds_many :steps, Step, on_replace: :delete

    timestamps()
  end

  @required_fields [:workspace_id, :name]
  @optional_fields [:description, :conversion_window_days]

  @doc """
  Changeset for creating or updating a funnel.
  """
  def changeset(funnel, attrs) do
    funnel
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_number(:conversion_window_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 90
    )
    |> cast_embed(:steps, required: true)
    |> cast_embed(:cohort_source_filter)
    |> discard_blank_cohort_filter()
    |> validate_step_count()
    |> unique_constraint(:name,
      name: :idx_ga_funnels_workspace_name,
      message: "has already been taken"
    )
  end

  defp discard_blank_cohort_filter(changeset) do
    case get_change(changeset, :cohort_source_filter) do
      nil ->
        changeset

      embed_changeset ->
        if CohortSourceFilter.blank?(apply_changes(embed_changeset)) do
          put_change(changeset, :cohort_source_filter, nil)
        else
          changeset
        end
    end
  end

  defp validate_step_count(changeset) do
    validate_change(changeset, :steps, fn :steps, steps ->
      count = length(steps)

      if count >= 2 and count <= 8 do
        []
      else
        [steps: "must have between 2 and 8 steps"]
      end
    end)
  end

end
