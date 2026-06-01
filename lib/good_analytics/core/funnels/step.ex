defmodule GoodAnalytics.Core.Funnels.Step do
  @moduledoc """
  Embedded schema for a funnel step.

  Each step declares a `kind`, a `combine` mode (`:all` or `:any`), and a list of 1..10 filters.
  Filters within a step are combined according to `combine`: `:all` → AND, `:any` → OR.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GoodAnalytics.Core.Funnels.Filter

  @primary_key false
  embedded_schema do
    field(:kind, :string)
    field(:label, :string)
    field(:combine, Ecto.Enum, values: [:all, :any], default: :all)

    embeds_many(:filters, Filter, on_replace: :delete)
  end

  @kinds ~w(event url property source)

  def changeset(step, attrs) do
    step
    |> cast(attrs, [:kind, :label, :combine])
    |> validate_required([:kind, :label])
    |> validate_inclusion(:kind, @kinds)
    |> cast_embed(:filters, required: true)
    |> validate_filter_count()
    |> validate_filters_match_kind()
  end

  defp validate_filter_count(changeset) do
    validate_change(changeset, :filters, fn :filters, filters ->
      count = length(filters)

      if count >= 1 and count <= 10 do
        []
      else
        [filters: "must contain between 1 and 10 filters"]
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
