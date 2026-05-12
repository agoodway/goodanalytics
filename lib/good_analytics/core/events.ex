defmodule GoodAnalytics.Core.Events do
  @moduledoc """
  Context for event queries.
  """

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Repo

  import Ecto.Query

  @doc "Lists recent events for a workspace."
  def list_events(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, 30)

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      order_by: [desc: e.inserted_at],
      limit: ^limit
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc "Returns source platform/medium breakdown for a workspace."
  def source_breakdown(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, 10)

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: not is_nil(e.source_platform),
      group_by: [e.source_platform, e.source_medium],
      select: %{
        platform: e.source_platform,
        medium: e.source_medium,
        count: count(e.id)
      },
      order_by: [desc: count(e.id)],
      limit: ^limit
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Gets a single event by id only.

  `Repo.get(Event, id)` is unsafe because the events table has a composite
  primary key `(id, inserted_at)` (required by Postgres for partitioned
  tables). This helper performs the equivalent fetch using a `where`
  clause and returns `nil` if no event is found.
  """
  def get_by_id(id) do
    repo = Repo.repo()

    from(e in Event, where: e.id == ^id, limit: 1)
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Finds an event by idempotency key within a workspace.

  Returns `nil` if no event matches the key.
  """
  def get_by_idempotency_key(workspace_id, idempotency_key) do
    repo = Repo.repo()

    from(e in Event,
      where: e.workspace_id == ^workspace_id,
      where: fragment("?->>'_idempotency_key' = ?", e.properties, ^idempotency_key),
      limit: 1
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets the most recent event of a given type for a visitor."
  def last_event(visitor_id, event_type) do
    repo = Repo.repo()

    from(e in Event,
      where: e.visitor_id == ^visitor_id,
      where: e.event_type == ^event_type,
      order_by: [desc: e.inserted_at],
      limit: 1
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end
end
