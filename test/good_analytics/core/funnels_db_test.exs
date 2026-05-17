defmodule GoodAnalytics.Core.FunnelsDBTest do
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Funnels
  alias GoodAnalytics.Core.Funnels.Funnel

  @workspace_id GoodAnalytics.default_workspace_id()

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
    name: "Pricing-to-Sale",
    conversion_window_days: 7,
    steps: @valid_steps
  }

  defp create_funnel!(attrs \\ %{}) do
    merged = Map.merge(@valid_attrs, attrs)
    name = Map.get(merged, :name, "funnel-#{System.unique_integer([:positive])}")
    merged = Map.put(merged, :name, name)
    {:ok, funnel} = Funnels.create_funnel(@workspace_id, merged)
    funnel
  end

  describe "create_funnel/2" do
    test "creates a funnel with valid attrs" do
      assert {:ok, %Funnel{} = funnel} = Funnels.create_funnel(@workspace_id, @valid_attrs)
      assert funnel.name == "Pricing-to-Sale"
      assert funnel.conversion_window_days == 7
      assert length(funnel.steps) == 2
      assert is_nil(funnel.archived_at)
    end

    test "rejects duplicate name in same workspace" do
      create_funnel!(%{name: "Duplicate"})

      assert {:error, changeset} =
               Funnels.create_funnel(@workspace_id, Map.put(@valid_attrs, :name, "Duplicate"))

      assert errors_on(changeset)[:name]
    end

    test "allows duplicate name after archiving original" do
      funnel = create_funnel!(%{name: "Reusable"})
      {:ok, _} = Funnels.archive_funnel(funnel)

      assert {:ok, %Funnel{}} =
               Funnels.create_funnel(@workspace_id, Map.put(@valid_attrs, :name, "Reusable"))
    end
  end

  describe "update_funnel/2" do
    test "updates name and steps" do
      funnel = create_funnel!()

      new_steps = [
        %{kind: "event", label: "PV", filters: [%{type: "event", event_type: "pageview"}]},
        %{kind: "event", label: "Lead", filters: [%{type: "event", event_type: "lead"}]},
        %{kind: "event", label: "Sale", filters: [%{type: "event", event_type: "sale"}]}
      ]

      assert {:ok, updated} = Funnels.update_funnel(funnel, %{name: "Updated", steps: new_steps})
      assert updated.name == "Updated"
      assert length(updated.steps) == 3
    end

    test "rejects duplicate name on update" do
      create_funnel!(%{name: "Existing"})
      funnel = create_funnel!(%{name: "Other"})

      assert {:error, changeset} = Funnels.update_funnel(funnel, %{name: "Existing"})
      assert errors_on(changeset)[:name]
    end

    test "rejects update on archived funnel" do
      funnel = create_funnel!()
      {:ok, archived} = Funnels.archive_funnel(funnel)

      assert {:error, :archived} = Funnels.update_funnel(archived, %{name: "New Name"})
    end
  end

  describe "get_funnel/1" do
    test "returns funnel by ID" do
      funnel = create_funnel!()
      assert found = Funnels.get_funnel(funnel.id)
      assert found.id == funnel.id
    end

    test "returns nil for nonexistent ID" do
      assert Funnels.get_funnel(Uniq.UUID.uuid7()) == nil
    end
  end

  describe "get_funnel!/2 with workspace IDOR check" do
    test "returns funnel when workspace matches" do
      funnel = create_funnel!()
      assert found = Funnels.get_funnel!(@workspace_id, funnel.id)
      assert found.id == funnel.id
    end

    test "raises when workspace does not match" do
      funnel = create_funnel!()
      other_workspace = Uniq.UUID.uuid7()

      assert_raise Ecto.NoResultsError, fn ->
        Funnels.get_funnel!(other_workspace, funnel.id)
      end
    end
  end

  describe "list_funnels/1" do
    test "lists non-archived funnels ordered by inserted_at desc" do
      f1 = create_funnel!(%{name: "First"})
      f2 = create_funnel!(%{name: "Second"})

      result = Funnels.list_funnels(@workspace_id)
      ids = Enum.map(result, & &1.id)

      assert f2.id in ids
      assert f1.id in ids
    end

    test "excludes archived funnels" do
      f1 = create_funnel!(%{name: "Active"})
      f2 = create_funnel!(%{name: "Archived"})
      {:ok, _} = Funnels.archive_funnel(f2)

      result = Funnels.list_funnels(@workspace_id)
      ids = Enum.map(result, & &1.id)

      assert f1.id in ids
      refute f2.id in ids
    end

    test "returns empty list for workspace with no funnels" do
      assert Funnels.list_funnels(Uniq.UUID.uuid7()) == []
    end
  end

  describe "analyze/2 ingest-to-query integration" do
    test "funnel with scope=path matches recorded event by path" do
      visitor = create_visitor!()

      {:ok, _event} =
        GoodAnalytics.Core.Events.Recorder.record(visitor, "pageview", %{
          url: "https://acme.com/pricing?utm=x"
        })

      {:ok, _event} =
        GoodAnalytics.Core.Events.Recorder.record(visitor, "sale", %{})

      funnel =
        create_funnel!(%{
          name: "Path Integration #{System.unique_integer([:positive])}",
          steps: [
            %{
              kind: "url",
              label: "Pricing",
              filters: [%{type: "url", scope: "path", match: "equals", value: "/pricing"}]
            },
            %{
              kind: "event",
              label: "Sale",
              filters: [%{type: "event", event_type: "sale"}]
            }
          ]
        })

      {:ok, result} =
        Funnels.analyze(funnel,
          window_start: DateTime.add(DateTime.utc_now(), -3600),
          window_end: DateTime.add(DateTime.utc_now(), 3600)
        )

      assert result.total_visitors == 1
    end
  end

  describe "analyze/2 combine=any with url-in integration" do
    test "combine=any with url-in filter matches visitors hitting any listed path" do
      visitor1 = create_visitor!()
      visitor2 = create_visitor!()

      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor1, "pageview", %{
          url: "https://acme.com/pricing"
        })

      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor1, "sale", %{})

      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor2, "pageview", %{
          url: "https://acme.com/plans"
        })

      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor2, "sale", %{})

      funnel =
        create_funnel!(%{
          name: "Combine Any Integration #{System.unique_integer([:positive])}",
          steps: [
            %{
              kind: "url",
              label: "Pricing or Plans",
              combine: "any",
              filters: [
                %{type: "url", scope: "path", match: "in", values: ["/pricing", "/plans", "/buy"]}
              ]
            },
            %{
              kind: "event",
              label: "Sale",
              filters: [%{type: "event", event_type: "sale"}]
            }
          ]
        })

      {:ok, result} =
        Funnels.analyze(funnel,
          window_start: DateTime.add(DateTime.utc_now(), -3600),
          window_end: DateTime.add(DateTime.utc_now(), 3600)
        )

      assert result.total_visitors == 2

      # Assert combine=any was persisted and reloaded correctly
      reloaded = Funnels.get_funnel(funnel.id)
      first_step = List.first(reloaded.steps)
      assert first_step.combine == :any
    end
  end

  describe "analyze/2 combine=all with multiple filters" do
    test "combine=all with 2 filters returns only visitors matching both" do
      visitor_both = create_visitor!()
      visitor_one = create_visitor!()

      # visitor_both hits /pricing AND has a sale event
      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor_both, "pageview", %{
          url: "https://acme.com/pricing"
        })

      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor_both, "sale", %{})

      # visitor_one hits /about (does NOT match /pricing)
      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor_one, "pageview", %{
          url: "https://acme.com/about"
        })

      {:ok, _} =
        GoodAnalytics.Core.Events.Recorder.record(visitor_one, "sale", %{})

      funnel =
        create_funnel!(%{
          name: "Combine All Integration #{System.unique_integer([:positive])}",
          steps: [
            %{
              kind: "url",
              label: "Pricing path",
              combine: "all",
              filters: [
                %{type: "url", scope: "path", match: "equals", value: "/pricing"},
                %{type: "url", scope: "path", match: "starts_with", value: "/pric"}
              ]
            },
            %{
              kind: "event",
              label: "Sale",
              filters: [%{type: "event", event_type: "sale"}]
            }
          ]
        })

      {:ok, result} =
        Funnels.analyze(funnel,
          window_start: DateTime.add(DateTime.utc_now(), -3600),
          window_end: DateTime.add(DateTime.utc_now(), 3600)
        )

      # visitor_both matches both filters, visitor_one matches neither
      assert result.total_visitors == 1
    end
  end

  describe "archive_funnel/1" do
    test "sets archived_at timestamp" do
      funnel = create_funnel!()
      assert {:ok, archived} = Funnels.archive_funnel(funnel)
      assert archived.archived_at != nil
    end

    test "archived funnel still retrievable via get_funnel/1" do
      funnel = create_funnel!()
      {:ok, _} = Funnels.archive_funnel(funnel)
      assert found = Funnels.get_funnel(funnel.id)
      assert found.archived_at != nil
    end

    test "raises for nonexistent ID with workspace scope" do
      assert_raise Ecto.NoResultsError, fn ->
        Funnels.archive_funnel(@workspace_id, Uniq.UUID.uuid7())
      end
    end

    test "raises for wrong workspace" do
      funnel = create_funnel!()
      other_workspace = Uniq.UUID.uuid7()

      assert_raise Ecto.NoResultsError, fn ->
        Funnels.archive_funnel(other_workspace, funnel.id)
      end
    end
  end
end
