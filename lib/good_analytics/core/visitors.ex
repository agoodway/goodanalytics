defmodule GoodAnalytics.Core.Visitors do
  @moduledoc """
  Context for visitor CRUD and lifecycle operations.
  """

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Repo

  import Ecto.Query

  @doc "Lists recent visitors for a workspace."
  def list_visitors(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    from(v in Visitor,
      where: v.workspace_id == ^workspace_id,
      where: v.status != "merged",
      order_by: [desc: v.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a visitor by ID."
  def get_visitor(id) do
    Repo.repo().get(Visitor, id, prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a visitor by ID, scoped to a workspace."
  def get_visitor(workspace_id, id) do
    repo = Repo.repo()

    from(v in Visitor,
      where: v.id == ^id,
      where: v.workspace_id == ^workspace_id
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a visitor by host-app external ID within a workspace."
  def get_by_external_id(workspace_id, person_external_id) do
    repo = Repo.repo()

    from(v in Visitor,
      where: v.workspace_id == ^workspace_id,
      where: v.person_external_id == ^person_external_id,
      where: v.status != "merged"
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets the event timeline for a visitor, ordered by inserted_at desc."
  def timeline(visitor_id) do
    repo = Repo.repo()

    from(e in Event,
      where: e.visitor_id == ^visitor_id,
      order_by: [desc: e.inserted_at]
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets the attribution path for a visitor."
  def attribution(visitor_id) do
    case get_visitor(visitor_id) do
      nil -> []
      visitor -> visitor.attribution_path || []
    end
  end

  @doc "Updates the lifecycle status of a visitor."
  def update_status(visitor_id, status) do
    repo = Repo.repo()

    case get_visitor(visitor_id) do
      nil ->
        {:error, :not_found}

      visitor ->
        visitor
        |> Visitor.changeset(%{status: status})
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Updates visitor attribution fields (extension point for GoodPartners)."
  def update_attribution(visitor_id, attrs) do
    repo = Repo.repo()

    case get_visitor(visitor_id) do
      nil ->
        {:error, :not_found}

      visitor ->
        visitor
        |> Visitor.changeset(attrs)
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc """
  Removes all PII, events, and identity signals for a visitor (GDPR forget).

  Clears all identifying fields and deletes associated events.
  """
  def forget(visitor_id) do
    repo = Repo.repo()

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:get_visitor, fn _repo, _changes ->
        case repo.get(Visitor, visitor_id, prefix: GoodAnalytics.schema_name()) do
          nil -> {:error, :not_found}
          visitor -> {:ok, visitor}
        end
      end)
      |> Ecto.Multi.delete_all(
        :delete_events,
        fn _changes ->
          from(e in Event, where: e.visitor_id == ^visitor_id)
        end,
        prefix: GoodAnalytics.schema_name()
      )
      |> Ecto.Multi.run(:clear_pii, fn _repo, %{get_visitor: visitor} ->
        # NOTE: The visitor row is retained (not hard-deleted) to preserve
        # aggregate stats integrity. All PII and timestamps are cleared
        # to prevent re-identification.
        pii_changeset =
          Visitor.changeset(visitor, %{
            fingerprints: [],
            anonymous_ids: [],
            click_ids: [],
            ga_id: nil,
            person_external_id: nil,
            person_email: nil,
            person_name: nil,
            person_metadata: %{},
            click_id_params: %{},
            geo: %{},
            device: %{},
            attribution_path: [],
            first_source: nil,
            last_source: nil,
            first_seen_at: ~U[1970-01-01 00:00:00Z],
            last_seen_at: ~U[1970-01-01 00:00:00Z],
            identified_at: nil,
            converted_at: nil,
            status: "anonymous"
          })

        repo.update(pii_changeset, prefix: GoodAnalytics.schema_name())
      end)

    case repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, :get_visitor, :not_found, _} -> {:error, :not_found}
      {:error, _, reason, _} -> {:error, reason}
    end
  end
end
