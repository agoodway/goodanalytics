defmodule GoodAnalytics.Core.Funnels.Filter do
  @moduledoc """
  Embedded schema for a funnel step filter.

  Supports four filter types:
  - `event`: matches by event_type (and optional event_name)
  - `url`: matches by URL with equals/starts_with/regex/in
  - `property`: matches event properties by key with eq/in operators
  - `source`: matches source_platform/source_medium/source_campaign
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GoodAnalytics.Core.Events.Event

  @primary_key false
  embedded_schema do
    field(:type, :string)

    # Event filter fields
    field(:event_type, :string)
    field(:event_name, :string)

    # URL filter fields
    field(:scope, Ecto.Enum, values: [:path, :host, :full_url], default: :path)
    field(:match, :string)
    field(:value, :string)

    # Property filter fields
    field(:key, :string)
    field(:op, :string)
    # For property "in" op — list of values
    field(:values, {:array, :string})

    # Source filter fields
    field(:platform, :string)
    field(:medium, :string)
    field(:campaign, :string)
  end

  @filter_types ~w(event url property source)
  @url_match_modes ~w(equals starts_with regex in)
  @property_ops ~w(eq in)

  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [
      :type,
      :event_type,
      :event_name,
      :scope,
      :match,
      :value,
      :key,
      :op,
      :values,
      :platform,
      :medium,
      :campaign
    ])
    |> validate_required([:type])
    |> validate_inclusion(:type, @filter_types)
    |> validate_by_type()
  end

  defp validate_by_type(changeset) do
    case get_field(changeset, :type) do
      "event" -> validate_event_filter(changeset)
      "url" -> validate_url_filter(changeset)
      "property" -> validate_property_filter(changeset)
      "source" -> validate_source_filter(changeset)
      _ -> changeset
    end
  end

  defp validate_event_filter(changeset) do
    changeset
    |> validate_required([:event_type])
    |> validate_inclusion(:event_type, Event.event_types())
  end

  defp validate_url_filter(changeset) do
    changeset
    |> validate_required([:match])
    |> validate_inclusion(:match, @url_match_modes)
    |> validate_url_by_match()
  end

  defp validate_url_by_match(changeset) do
    case get_field(changeset, :match) do
      "in" ->
        changeset
        |> validate_url_in_values()
        |> validate_url_in_value_exclusivity()

      _ ->
        changeset
        |> validate_required([:value])
        |> validate_length(:value, max: 2000)
        |> validate_regex_syntax()
    end
  end

  defp validate_url_in_values(changeset) do
    values = get_field(changeset, :values)

    cond do
      is_nil(values) or values == [] ->
        add_error(changeset, :values, "must be a non-empty list for url 'in' match mode")

      Enum.any?(values, &(&1 == "")) ->
        add_error(changeset, :values, "all entries must be non-empty strings")

      length(values) > 50 ->
        add_error(changeset, :values, "must have 50 or fewer values")

      Enum.any?(values, &(String.length(&1) > 2000)) ->
        add_error(changeset, :values, "each value must be 2000 characters or fewer")

      true ->
        changeset
    end
  end

  defp validate_url_in_value_exclusivity(changeset) do
    value = get_field(changeset, :value)

    if is_binary(value) and value != "" do
      add_error(
        changeset,
        :value,
        "value and values are mutually exclusive for url 'in' match mode"
      )
    else
      changeset
    end
  end

  defp validate_regex_syntax(changeset) do
    if get_field(changeset, :match) == "regex" do
      value = get_field(changeset, :value)

      cond do
        is_nil(value) ->
          changeset

        String.length(value) > 200 ->
          add_error(changeset, :value, "regex pattern must be 200 characters or fewer")

        true ->
          case :re.compile(value) do
            {:ok, _} -> changeset
            {:error, _} -> add_error(changeset, :value, "invalid regex pattern")
          end
      end
    else
      changeset
    end
  end

  defp validate_property_filter(changeset) do
    changeset
    |> validate_required([:key, :op])
    |> validate_inclusion(:op, @property_ops)
    |> validate_length(:key, max: 255)
    |> validate_length(:value, max: 1000)
    |> validate_property_value()
  end

  defp validate_property_value(changeset) do
    case get_field(changeset, :op) do
      "eq" ->
        validate_required(changeset, [:value])

      "in" ->
        changeset
        |> validate_change(:values, fn :values, values ->
          cond do
            not is_list(values) or length(values) == 0 ->
              [values: "must be a non-empty list for 'in' operator"]

            length(values) > 100 ->
              [values: "must have 100 or fewer values"]

            Enum.any?(values, &(String.length(&1) > 1000)) ->
              [values: "each value must be 1000 characters or fewer"]

            true ->
              []
          end
        end)

      _ ->
        changeset
    end
  end

  defp validate_source_filter(changeset) do
    platform = get_field(changeset, :platform)
    medium = get_field(changeset, :medium)
    campaign = get_field(changeset, :campaign)

    if is_nil(platform) and is_nil(medium) and is_nil(campaign) do
      add_error(
        changeset,
        :type,
        "source filter must specify at least one of platform, medium, or campaign"
      )
    else
      changeset
    end
  end
end
