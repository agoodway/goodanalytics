defmodule GoodAnalytics.Core.Visitors.VisitorTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Visitors.Visitor

  @valid_attrs %{
    workspace_id: "00000000-0000-0000-0000-000000000000",
    status: "anonymous"
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Visitor.changeset(%Visitor{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without workspace_id" do
      changeset = Visitor.changeset(%Visitor{}, %{})
      refute changeset.valid?
      assert %{workspace_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "invalid status" do
      attrs = Map.put(@valid_attrs, :status, "invalid")
      changeset = Visitor.changeset(%Visitor{}, attrs)
      refute changeset.valid?
      assert %{status: [_]} = errors_on(changeset)
    end

    test "accepts all valid statuses" do
      for status <- ~w(anonymous identified lead customer churned merged) do
        changeset = Visitor.changeset(%Visitor{}, %{@valid_attrs | status: status})
        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "accepts identity signal arrays" do
      attrs =
        Map.merge(@valid_attrs, %{
          fingerprints: ["fp_abc", "fp_def"],
          anonymous_ids: ["anon_1"],
          click_ids: [Ecto.UUID.generate()]
        })

      changeset = Visitor.changeset(%Visitor{}, attrs)
      assert changeset.valid?
    end

    test "accepts customer fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          person_external_id: "cust_123",
          person_email: "test@example.com",
          person_name: "Test User",
          person_metadata: %{"plan" => "pro"}
        })

      changeset = Visitor.changeset(%Visitor{}, attrs)
      assert changeset.valid?
    end
  end

  describe "identify_changeset/2" do
    test "casts customer identification fields" do
      visitor = %Visitor{workspace_id: Ecto.UUID.generate()}

      changeset =
        Visitor.identify_changeset(visitor, %{
          person_external_id: "cust_123",
          person_email: "test@example.com",
          status: "identified",
          identified_at: DateTime.utc_now()
        })

      assert changeset.valid?
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
