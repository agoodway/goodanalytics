defmodule GoodAnalytics.TimeWindowTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.TimeWindow

  describe "trailing_start/3" do
    test "subtracts day units" do
      end_at = DateTime.from_naive!(~N[2024-01-10 12:00:00], "Etc/UTC")

      assert TimeWindow.trailing_start(end_at, 2, :day) ==
               DateTime.from_naive!(~N[2024-01-08 12:00:00], "Etc/UTC")
    end

    test "subtracts hour units" do
      end_at = DateTime.from_naive!(~N[2024-01-01 06:00:00], "Etc/UTC")

      assert TimeWindow.trailing_start(end_at, 3, :hour) ==
               DateTime.from_naive!(~N[2024-01-01 03:00:00], "Etc/UTC")
    end

    test "subtracts minute units" do
      end_at = DateTime.from_naive!(~N[2024-01-01 00:30:00], "Etc/UTC")

      assert TimeWindow.trailing_start(end_at, 15, :minute) ==
               DateTime.from_naive!(~N[2024-01-01 00:15:00], "Etc/UTC")
    end

    test "subtracts second units" do
      end_at = DateTime.from_naive!(~N[2024-01-01 00:00:10], "Etc/UTC")

      assert TimeWindow.trailing_start(end_at, 7, :second) ==
               DateTime.from_naive!(~N[2024-01-01 00:00:03], "Etc/UTC")
    end

    # Documents the timezone-naive contract of trailing_start/3.
    # The function does fixed-second arithmetic (1 day = 86_400 s) regardless
    # of DST transitions in the caller's timezone. A "1 day" trailing window
    # is always exactly 86_400 seconds long; callers that want wall-clock day
    # alignment in a non-UTC timezone must convert with DateTime.shift_zone!/2
    # and shift by calendar days outside this helper.
    test "trailing_start/3 is fixed-seconds — DST does not extend or shrink the window" do
      end_at = DateTime.from_naive!(~N[2024-03-11 04:30:00], "Etc/UTC")

      result_1d = TimeWindow.trailing_start(end_at, 1, :day)
      result_14d = TimeWindow.trailing_start(end_at, 14, :day)

      assert DateTime.diff(end_at, result_1d, :second) == 86_400
      assert DateTime.diff(end_at, result_14d, :second) == 14 * 86_400
    end
  end

  describe "trailing/3" do
    test "returns a start/end map for a half-open window" do
      end_at = DateTime.from_naive!(~N[2024-01-10 00:00:00], "Etc/UTC")

      assert TimeWindow.trailing(end_at, 1, :day) == %{
               start_at: DateTime.from_naive!(~N[2024-01-09 00:00:00], "Etc/UTC"),
               end_at: end_at
             }
    end
  end

  describe "previous/1" do
    test "returns a contiguous prior window with equal duration" do
      current = %{
        start_at: DateTime.from_naive!(~N[2024-01-10 00:00:00], "Etc/UTC"),
        end_at: DateTime.from_naive!(~N[2024-01-12 00:00:00], "Etc/UTC")
      }

      previous = TimeWindow.previous(current)
      duration = DateTime.diff(current.end_at, current.start_at, :second)

      assert previous.end_at == current.start_at
      assert previous.start_at == DateTime.add(current.start_at, -duration, :second)
    end
  end

  describe "contains?/2" do
    test "uses half-open boundaries and rejects out-of-range values" do
      window = %{
        start_at: DateTime.from_naive!(~N[2024-01-01 00:00:00], "Etc/UTC"),
        end_at: DateTime.from_naive!(~N[2024-01-01 01:00:00], "Etc/UTC")
      }

      at_start = DateTime.from_naive!(~N[2024-01-01 00:00:00], "Etc/UTC")
      inside = DateTime.from_naive!(~N[2024-01-01 00:30:00], "Etc/UTC")
      before_start = DateTime.from_naive!(~N[2023-12-31 23:59:59], "Etc/UTC")
      at_end = DateTime.from_naive!(~N[2024-01-01 01:00:00], "Etc/UTC")

      assert TimeWindow.contains?(window, at_start)
      assert TimeWindow.contains?(window, inside)
      refute TimeWindow.contains?(window, before_start)
      refute TimeWindow.contains?(window, at_end)
    end
  end
end
