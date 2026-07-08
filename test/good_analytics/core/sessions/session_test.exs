defmodule GoodAnalytics.Core.Sessions.SessionTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Sessions.Session

  @now DateTime.utc_now()

  @valid_attrs %{
    workspace_id: "00000000-0000-0000-0000-000000000000",
    visitor_id: Uniq.UUID.uuid7(),
    started_at: @now,
    last_event_at: @now
  }

  describe "changeset/2" do
    test "is valid with the required fields" do
      changeset = Session.changeset(%Session{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires workspace_id, visitor_id, started_at, last_event_at" do
      changeset = Session.changeset(%Session{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.workspace_id
      assert "can't be blank" in errors.visitor_id
      assert "can't be blank" in errors.started_at
      assert "can't be blank" in errors.last_event_at
    end

    test "casts all session metric and acquisition fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          anonymous_id: "anon-123",
          entry_url: "https://x.test/landing?utm_source=google",
          entry_page: "/landing",
          exit_page: "/pricing",
          pageviews: 2,
          events: 3,
          duration_seconds: 42,
          engaged_seconds: 18,
          is_bounce: false,
          is_engaged: true,
          source_platform: "google",
          source_medium: "cpc",
          source_campaign: "spring",
          click_id: Uniq.UUID.uuid7(),
          device_type: "desktop",
          browser: "Chrome",
          os: "Mac"
        })

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :pageviews) == 2
      assert Ecto.Changeset.get_change(changeset, :is_bounce) == false
      assert Ecto.Changeset.get_change(changeset, :source_platform) == "google"
      assert Ecto.Changeset.get_change(changeset, :device_type) == "desktop"
    end

    test "requires defaulted metric and state fields when explicitly nil" do
      attrs =
        Map.merge(@valid_attrs, %{
          pageviews: nil,
          events: nil,
          duration_seconds: nil,
          engaged_seconds: nil,
          is_bounce: nil,
          is_engaged: nil
        })

      changeset = Session.changeset(%Session{}, attrs)
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "can't be blank" in errors.pageviews
      assert "can't be blank" in errors.events
      assert "can't be blank" in errors.duration_seconds
      assert "can't be blank" in errors.engaged_seconds
      assert "can't be blank" in errors.is_bounce
      assert "can't be blank" in errors.is_engaged
    end

    test "rejects negative metric fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          pageviews: -1,
          events: -1,
          duration_seconds: -1,
          engaged_seconds: -1
        })

      changeset = Session.changeset(%Session{}, attrs)
      refute changeset.valid?

      errors = errors_on(changeset)
      assert "must be greater than or equal to 0" in errors.pageviews
      assert "must be greater than or equal to 0" in errors.events
      assert "must be greater than or equal to 0" in errors.duration_seconds
      assert "must be greater than or equal to 0" in errors.engaged_seconds
    end

    test "requires last_event_at to be at or after started_at" do
      started_at = DateTime.add(@now, 60, :second)
      last_event_at = @now

      changeset =
        Session.changeset(%Session{}, %{
          @valid_attrs
          | started_at: started_at,
            last_event_at: last_event_at
        })

      refute changeset.valid?
      assert "must be at or after started_at" in errors_on(changeset).last_event_at
    end

    test "truncates oversized source strings instead of rejecting the session" do
      long = String.duplicate("a", 1_000)

      attrs =
        Map.merge(@valid_attrs, %{
          source_platform: long,
          source_medium: long,
          source_campaign: long
        })

      changeset = Session.changeset(%Session{}, attrs)

      assert changeset.valid?
      assert String.length(Ecto.Changeset.get_change(changeset, :source_platform)) == 255
      assert String.length(Ecto.Changeset.get_change(changeset, :source_medium)) == 255
      assert String.length(Ecto.Changeset.get_change(changeset, :source_campaign)) == 255
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
