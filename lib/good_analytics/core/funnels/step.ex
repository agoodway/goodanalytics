defmodule GoodAnalytics.Core.Funnels.Step do
  @moduledoc """
  Embedded schema for a funnel step.

  Each step declares a `kind` and a non-empty list of filters.
  Filters within a step are AND-combined during query execution.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GoodAnalytics.Core.Funnels.Filter

  @primary_key false
  embedded_schema do
    field(:kind, :string)
    field(:label, :string)

    embeds_many :filters, Filter, on_replace: :delete
  end

  @kinds ~w(event url property source)

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:kind, :label])
    |> validate_required([:kind, :label])
    |> validate_inclusion(:kind, @kinds)
    |> cast_embed(:filters, required: true)
    |> validate_filters_present()
    |> validate_filters_match_kind()
  end

  defp validate_filters_present(changeset) do
    validate_change(changeset, :filters, fn :filters, filters ->
      if length(filters) > 0 do
        []
      else
        [filters: "must have at least one filter"]
      end
    end)
  end

  defp validate_filters_match_kind(changeset) do
    kind = get_field(changeset, :kind)
    filters = get_field(changeset, :filters) || []

    if kind && filters != [] do
      mismatched =
        Enum.any?(filters, fn
          %{type: type} -> type != kind
          %{"type" => type} -> type != kind
          _ -> false
        end)

      if mismatched do
        add_error(changeset, :filters, "all filters must match step kind '#{kind}'")
      else
        changeset
      end
    else
      changeset
    end
  end
end
