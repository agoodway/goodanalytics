defmodule GoodAnalytics.Core.Funnels.FunnelTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset, only: [get_change: 2]

  alias GoodAnalytics.Core.Funnels.Funnel

  @workspace_id "00000000-0000-0000-0000-000000000000"

  @valid_steps [
    %{
      kind: "url",
      label: "Visit pricing",
      filters: [%{type: "url", match: "starts_with", value: "/pricing"}]
    },
    %{
      kind: "event",
      label: "Sale",
      filters: [%{type: "event", event_type: "sale"}]
    }
  ]

  @valid_attrs %{
    workspace_id: @workspace_id,
    name: "Pricing-to-Sale",
    conversion_window_days: 7,
    steps: @valid_steps
  }

  describe "changeset/2 basics" do
    test "valid with required fields and 2 steps" do
      changeset = Funnel.changeset(%Funnel{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without name" do
      changeset = Funnel.changeset(%Funnel{}, Map.delete(@valid_attrs, :name))
      refute changeset.valid?
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without workspace_id" do
      changeset = Funnel.changeset(%Funnel{}, Map.delete(@valid_attrs, :workspace_id))
      refute changeset.valid?
      assert %{workspace_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid without steps" do
      changeset = Funnel.changeset(%Funnel{}, Map.delete(@valid_attrs, :steps))
      refute changeset.valid?
    end
  end

  describe "step count validation" do
    test "rejects 1 step" do
      attrs = Map.put(@valid_attrs, :steps, [hd(@valid_steps)])
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
      assert %{steps: ["must have between 2 and 8 steps"]} = errors_on(changeset)
    end

    test "accepts 2 steps" do
      changeset = Funnel.changeset(%Funnel{}, @valid_attrs)
      assert changeset.valid?
    end

    test "accepts 8 steps" do
      steps = for i <- 1..8 do
        %{kind: "event", label: "Step #{i}", filters: [%{type: "event", event_type: "pageview"}]}
      end

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "rejects 9 steps" do
      steps = for i <- 1..9 do
        %{kind: "event", label: "Step #{i}", filters: [%{type: "event", event_type: "pageview"}]}
      end

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
      assert %{steps: ["must have between 2 and 8 steps"]} = errors_on(changeset)
    end
  end

  describe "conversion_window_days validation" do
    test "rejects 0" do
      attrs = Map.put(@valid_attrs, :conversion_window_days, 0)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:conversion_window_days]
    end

    test "accepts 1" do
      attrs = Map.put(@valid_attrs, :conversion_window_days, 1)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "accepts 90" do
      attrs = Map.put(@valid_attrs, :conversion_window_days, 90)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "rejects 91" do
      attrs = Map.put(@valid_attrs, :conversion_window_days, 91)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:conversion_window_days]
    end
  end

  describe "step filter validations" do
    test "event filter validates event_type against known set" do
      steps = [
        %{kind: "event", label: "Step 1", filters: [%{type: "event", event_type: "checkout_step"}]},
        %{kind: "event", label: "Step 2", filters: [%{type: "event", event_type: "sale"}]}
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
    end

    test "url filter requires match mode" do
      steps = [
        %{kind: "url", label: "Step 1", filters: [%{type: "url", value: "/pricing"}]},
        %{kind: "event", label: "Step 2", filters: [%{type: "event", event_type: "sale"}]}
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
    end

    test "property filter accepts eq and in operators" do
      steps = [
        %{
          kind: "property",
          label: "Eq step",
          filters: [%{type: "property", key: "plan", op: "eq", value: "pro"}]
        },
        %{
          kind: "property",
          label: "In step",
          filters: [%{type: "property", key: "plan", op: "in", values: ["pro", "enterprise"]}]
        }
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "property filter rejects unknown op" do
      steps = [
        %{kind: "property", label: "Step 1", filters: [%{type: "property", key: "plan", op: "gt", value: "5"}]},
        %{kind: "event", label: "Step 2", filters: [%{type: "event", event_type: "sale"}]}
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
    end

    test "source filter requires at least one field" do
      steps = [
        %{kind: "source", label: "Step 1", filters: [%{type: "source"}]},
        %{kind: "event", label: "Step 2", filters: [%{type: "event", event_type: "sale"}]}
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
    end

    test "source filter with platform is valid" do
      steps = [
        %{kind: "source", label: "Step 1", filters: [%{type: "source", platform: "google"}]},
        %{kind: "event", label: "Step 2", filters: [%{type: "event", event_type: "sale"}]}
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "step kind must be valid" do
      steps = [
        %{kind: "invalid", label: "Step 1", filters: [%{type: "event", event_type: "pageview"}]},
        %{kind: "event", label: "Step 2", filters: [%{type: "event", event_type: "sale"}]}
      ]

      attrs = Map.put(@valid_attrs, :steps, steps)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      refute changeset.valid?
    end
  end

  describe "cohort_source_filter validation" do
    test "nil is accepted" do
      attrs = Map.put(@valid_attrs, :cohort_source_filter, nil)
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "valid with platform" do
      attrs = Map.put(@valid_attrs, :cohort_source_filter, %{platform: "google"})
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
    end

    test "empty map is discarded to nil" do
      attrs = Map.put(@valid_attrs, :cohort_source_filter, %{})
      changeset = Funnel.changeset(%Funnel{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :cohort_source_filter) == nil
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
