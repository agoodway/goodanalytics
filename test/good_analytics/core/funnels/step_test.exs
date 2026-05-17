defmodule GoodAnalytics.Core.Funnels.StepTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Funnels.Step

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        kind: "event",
        label: "Pageview",
        filters: [%{type: "event", event_type: "pageview"}]
      },
      overrides
    )
  end

  describe "combine field" do
    test "defaults to :all when omitted" do
      changeset = Step.changeset(%Step{}, valid_attrs())
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :combine) == :all
    end

    test "accepts :all" do
      changeset = Step.changeset(%Step{}, valid_attrs(%{combine: :all}))
      assert changeset.valid?
    end

    test "accepts :any" do
      changeset = Step.changeset(%Step{}, valid_attrs(%{combine: :any}))
      assert changeset.valid?
    end

    test "accepts string 'all'" do
      changeset = Step.changeset(%Step{}, valid_attrs(%{combine: "all"}))
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :combine) == :all
    end

    test "accepts string 'any'" do
      changeset = Step.changeset(%Step{}, valid_attrs(%{combine: "any"}))
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :combine) == :any
    end

    test "rejects unknown combine value" do
      changeset = Step.changeset(%Step{}, valid_attrs(%{combine: "either"}))
      refute changeset.valid?
      assert errors_on(changeset)[:combine]
    end
  end

  describe "filter count bounds" do
    test "accepts 1 filter" do
      changeset = Step.changeset(%Step{}, valid_attrs())
      assert changeset.valid?
    end

    test "accepts 10 filters" do
      filters = for _ <- 1..10, do: %{type: "event", event_type: "pageview"}
      changeset = Step.changeset(%Step{}, valid_attrs(%{filters: filters}))
      assert changeset.valid?
    end

    test "rejects 0 filters" do
      changeset = Step.changeset(%Step{}, valid_attrs(%{filters: []}))
      refute changeset.valid?
      assert errors_on(changeset)[:filters]
    end

    test "rejects 11 filters" do
      filters = for _ <- 1..11, do: %{type: "event", event_type: "pageview"}
      changeset = Step.changeset(%Step{}, valid_attrs(%{filters: filters}))
      refute changeset.valid?
      assert "must contain between 1 and 10 filters" in errors_on(changeset)[:filters]
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
