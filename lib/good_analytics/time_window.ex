defmodule GoodAnalytics.TimeWindow do
  @moduledoc """
  Time window helpers built around half-open ranges.

  All windows use the convention `[start_at, end_at)`, where `start_at` is
  inclusive and `end_at` is exclusive.
  """

  @type t :: %{start_at: DateTime.t(), end_at: DateTime.t()}

  @doc "Returns the start timestamp of a trailing window ending at `end_at`."
  @spec trailing_start(DateTime.t(), non_neg_integer(), :day | :hour | :minute | :second) ::
          DateTime.t()
  def trailing_start(end_at, amount, unit) do
    DateTime.add(end_at, -amount * unit_seconds(unit), :second)
  end

  @doc "Builds a trailing half-open window `[start_at, end_at)`."
  @spec trailing(DateTime.t(), non_neg_integer(), :day | :hour | :minute | :second) :: t()
  def trailing(end_at, amount, unit) do
    %{start_at: trailing_start(end_at, amount, unit), end_at: end_at}
  end

  @doc "Returns the contiguous prior window with identical duration (in seconds)."
  @spec previous(t()) :: t()
  def previous(window) do
    duration = DateTime.diff(window.end_at, window.start_at, :second)

    %{
      start_at: DateTime.add(window.start_at, -duration, :second),
      end_at: window.start_at
    }
  end

  @doc "True when `datetime` is inside the half-open window `[window.start_at, window.end_at)`."
  @spec contains?(t(), DateTime.t()) :: boolean()
  def contains?(window, datetime) do
    DateTime.compare(datetime, window.start_at) != :lt and
      DateTime.compare(datetime, window.end_at) == :lt
  end

  defp unit_seconds(:day), do: 86_400
  defp unit_seconds(:hour), do: 3_600
  defp unit_seconds(:minute), do: 60
  defp unit_seconds(:second), do: 1
end
