defmodule GoodAnalytics.Core.Funnels.CohortSourceFilter do
  @moduledoc """
  Embedded schema for funnel cohort source filtering.

  Applied to step 1 to restrict analysis to visitors from a specific
  traffic source (platform, medium, and/or campaign).
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field(:platform, :string)
    field(:medium, :string)
    field(:campaign, :string)
  end

  def changeset(filter, attrs) do
    filter
    |> cast(attrs, [:platform, :medium, :campaign])
    |> validate_length(:platform, max: 255)
    |> validate_length(:medium, max: 255)
    |> validate_length(:campaign, max: 255)
  end

  @doc """
  Returns true when all filter fields are blank (nil or empty string).
  Used by the parent schema to discard an all-blank embed.
  """
  def blank?(%__MODULE__{} = filter) do
    blank_value?(filter.platform) and blank_value?(filter.medium) and blank_value?(filter.campaign)
  end

  def blank?(nil), do: true

  defp blank_value?(nil), do: true
  defp blank_value?(""), do: true
  defp blank_value?(_), do: false
end
