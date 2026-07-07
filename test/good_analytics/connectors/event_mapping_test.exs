defmodule GoodAnalytics.Connectors.EventMappingTest.FakeConnector do
  @moduledoc false
  def connector_type, do: :custom_ads
end

defmodule GoodAnalytics.Connectors.EventMappingTest do
  # async: false — the generic-connector test temporarily registers a fake
  # connector via application env.
  use ExUnit.Case, async: false

  alias GoodAnalytics.Connectors.EventMapping
  alias GoodAnalytics.Connectors.EventMappingTest.FakeConnector

  @workspace_id "00000000-0000-0000-0000-000000000000"

  @valid_attrs %{
    workspace_id: @workspace_id,
    event_name: " trial_started ",
    connector_type: :meta,
    connector_event_name: "StartTrial"
  }

  describe "changeset/2" do
    test "normalizes event name and connector type" do
      changeset = EventMapping.changeset(%EventMapping{}, @valid_attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :event_name) == "trial_started"
      assert Ecto.Changeset.get_field(changeset, :connector_type) == "meta"
      assert Ecto.Changeset.get_field(changeset, :enabled) == true
      assert Ecto.Changeset.get_field(changeset, :config) == %{}
    end

    test "requires workspace, event name, and connector type" do
      changeset = EventMapping.changeset(%EventMapping{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert %{workspace_id: _} = errors
      assert %{event_name: _} = errors
      assert %{connector_type: _} = errors
    end

    test "rejects blank event names" do
      changeset =
        EventMapping.changeset(%EventMapping{}, Map.put(@valid_attrs, :event_name, "  "))

      refute changeset.valid?
      assert %{event_name: _} = errors_on(changeset)
    end

    test "rejects unregistered connector types" do
      changeset =
        EventMapping.changeset(%EventMapping{}, Map.put(@valid_attrs, :connector_type, :unknown))

      refute changeset.valid?
      assert %{connector_type: _} = errors_on(changeset)
    end

    test "requires connector event names for Meta and TikTok" do
      for connector_type <- [:meta, :tiktok] do
        attrs =
          @valid_attrs
          |> Map.put(:connector_type, connector_type)
          |> Map.delete(:connector_event_name)

        changeset = EventMapping.changeset(%EventMapping{}, attrs)

        refute changeset.valid?
        assert %{connector_event_name: _} = errors_on(changeset)
      end
    end

    test "requires Google conversion_action_id in config" do
      attrs = %{
        workspace_id: @workspace_id,
        event_name: "trial_started",
        connector_type: :google,
        config: %{}
      }

      changeset = EventMapping.changeset(%EventMapping{}, attrs)

      refute changeset.valid?
      assert %{config: _} = errors_on(changeset)
    end

    test "requires LinkedIn conversion_rule_id in config" do
      attrs = %{
        workspace_id: @workspace_id,
        event_name: "trial_started",
        connector_type: :linkedin,
        config: %{}
      }

      changeset = EventMapping.changeset(%EventMapping{}, attrs)

      refute changeset.valid?
      assert %{config: _} = errors_on(changeset)
    end

    test "accepts Google and LinkedIn mappings with required config" do
      google =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :google,
          config: %{"conversion_action_id" => "123456"}
        })

      linkedin =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :linkedin,
          config: %{"conversion_rule_id" => "abc123"}
        })

      assert google.valid?
      assert linkedin.valid?
    end

    test "rejects blank config id values" do
      changeset =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :google,
          config: %{"conversion_action_id" => "   "}
        })

      refute changeset.valid?
      assert %{config: _} = errors_on(changeset)
    end

    test "rejects config id values with unsafe characters" do
      changeset =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :google,
          config: %{"conversion_action_id" => "123/../../secret"}
        })

      refute changeset.valid?
      assert %{config: _} = errors_on(changeset)
    end

    test "rejects unsupported config keys for a built-in connector" do
      changeset =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :google,
          config: %{"conversion_action_id" => "123456", "client_secret" => "leaked"}
        })

      refute changeset.valid?
      assert %{config: _} = errors_on(changeset)
    end

    test "rejects config with too many keys" do
      big_config = for i <- 1..25, into: %{}, do: {"key_#{i}", "value"}

      changeset =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :meta,
          connector_event_name: "StartTrial",
          config: big_config
        })

      refute changeset.valid?
      assert %{config: _} = errors_on(changeset)
    end

    test "coerces a blank connector event name to nil for optional-field connectors" do
      changeset =
        EventMapping.changeset(%EventMapping{}, %{
          workspace_id: @workspace_id,
          event_name: "trial_started",
          connector_type: :google,
          connector_event_name: "   ",
          config: %{"conversion_action_id" => "123456"}
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :connector_event_name) == nil
    end

    test "rejects connector event names with invalid characters" do
      changeset =
        EventMapping.changeset(
          %EventMapping{},
          Map.put(@valid_attrs, :connector_event_name, "bad$name")
        )

      refute changeset.valid?
      assert %{connector_event_name: _} = errors_on(changeset)
    end

    test "rejects overly long connector event names" do
      changeset =
        EventMapping.changeset(
          %EventMapping{},
          Map.put(@valid_attrs, :connector_event_name, String.duplicate("a", 51))
        )

      refute changeset.valid?
      assert %{connector_event_name: _} = errors_on(changeset)
    end

    test "generic connector requires a connector event name or config" do
      previous = Application.get_env(:good_analytics, :connectors)
      Application.put_env(:good_analytics, :connectors, [FakeConnector])

      on_exit(fn ->
        if previous do
          Application.put_env(:good_analytics, :connectors, previous)
        else
          Application.delete_env(:good_analytics, :connectors)
        end
      end)

      base = %{
        workspace_id: @workspace_id,
        event_name: "trial_started",
        connector_type: :custom_ads
      }

      missing = EventMapping.changeset(%EventMapping{}, base)
      refute missing.valid?
      assert %{connector_event_name: _} = errors_on(missing)

      with_name =
        EventMapping.changeset(
          %EventMapping{},
          Map.put(base, :connector_event_name, "CustomGoal")
        )

      assert with_name.valid?

      with_config =
        EventMapping.changeset(
          %EventMapping{},
          Map.put(base, :config, %{"custom_key" => "value"})
        )

      assert with_config.valid?

      # Byte-size cap applies even to generic connectors whose keys are otherwise
      # unrestricted. A single key (under the key-count cap) with a large value
      # exercises the byte-size branch, not the key-count branch.
      oversized =
        EventMapping.changeset(
          %EventMapping{},
          Map.put(base, :config, %{"blob" => String.duplicate("a", 5_000)})
        )

      refute oversized.valid?
      assert %{config: _} = errors_on(oversized)
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
