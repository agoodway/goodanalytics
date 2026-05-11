defmodule GoodAnalytics.Connectors.DispatchTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.Dispatch

  @valid_attrs %{
    workspace_id: "00000000-0000-0000-0000-000000000000",
    connector_type: "meta",
    connector_event_id: "meta_evt_abc123",
    event_id: "11111111-1111-1111-1111-111111111111",
    event_inserted_at: ~U[2026-04-21 12:00:00.000000Z],
    visitor_id: "22222222-2222-2222-2222-222222222222",
    payload_snapshot: %{"action_source" => "website", "event_name" => "Lead"},
    source_context: %{"signals" => %{"_fbp" => "fb.1.123"}, "event_type" => "lead"}
  }

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = Dispatch.changeset(%Dispatch{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = Dispatch.changeset(%Dispatch{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert %{workspace_id: _} = errors
      assert %{connector_type: _} = errors
      assert %{connector_event_id: _} = errors
      assert %{event_id: _} = errors
      assert %{event_inserted_at: _} = errors
      assert %{visitor_id: _} = errors
    end

    test "invalid status rejected" do
      attrs = Map.put(@valid_attrs, :status, "invalid_status")
      changeset = Dispatch.changeset(%Dispatch{}, attrs)
      refute changeset.valid?
    end

    test "accepts all valid statuses" do
      for status <-
            ~w(pending delivering delivered failed credential_error rate_limited skipped_disabled permanently_failed) do
        changeset = Dispatch.changeset(%Dispatch{}, Map.put(@valid_attrs, :status, status))
        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "defaults status to pending" do
      changeset = Dispatch.changeset(%Dispatch{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == "pending"
    end

    test "defaults attempts to 0" do
      changeset = Dispatch.changeset(%Dispatch{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :attempts) == 0
    end

    test "defaults max_attempts to 5" do
      changeset = Dispatch.changeset(%Dispatch{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :max_attempts) == 5
    end
  end

  describe "delivery_changeset/2" do
    test "updates delivery status and response metadata" do
      dispatch = %Dispatch{status: "pending", attempts: 0}

      changeset =
        Dispatch.delivery_changeset(dispatch, %{
          status: "delivered",
          attempts: 1,
          last_attempted_at: DateTime.utc_now(),
          response_status: 200,
          response_body: %{"success" => true}
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "delivered"
      assert Ecto.Changeset.get_change(changeset, :attempts) == 1
      assert Ecto.Changeset.get_change(changeset, :response_status) == 200
    end

    test "rejects invalid status" do
      changeset = Dispatch.delivery_changeset(%Dispatch{}, %{status: "bad"})
      refute changeset.valid?
    end
  end

  describe "replay_changeset/2" do
    test "sets replay metadata" do
      dispatch = %Dispatch{}
      now = DateTime.utc_now()

      changeset =
        Dispatch.replay_changeset(dispatch, %{
          replayed_from_id: "33333333-3333-3333-3333-333333333333",
          replayed_at: now
        })

      assert changeset.valid?
    end

    test "requires replayed_from_id and replayed_at" do
      changeset = Dispatch.replay_changeset(%Dispatch{}, %{})
      refute changeset.valid?
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
