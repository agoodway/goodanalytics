defmodule GoodAnalytics.Connectors.Dispatches do
  @moduledoc """
  Context for connector dispatch record operations.

  Provides CRUD and query functions for durable outbound connector
  dispatch records used by the delivery, replay, and reconciliation flows.
  """

  alias GoodAnalytics.Connectors.Dispatch
  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Repo

  import Ecto.Query

  @prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")
  # Default row cap for workspace-scoped dispatch history queries.
  @default_workspace_list_limit 50
  # Default row cap for pending dispatch polling queries.
  @default_pending_list_limit 100

  @doc "Creates a new dispatch record."
  def create_dispatch(attrs) do
    repo = Repo.repo()

    %Dispatch{id: Uniq.UUID.uuid7()}
    |> Dispatch.changeset(attrs)
    |> repo.insert(prefix: @prefix)
  end

  @doc "Creates multiple dispatch records in a single transaction."
  def create_dispatches(dispatches_attrs) when is_list(dispatches_attrs) do
    repo = Repo.repo()

    Ecto.Multi.new()
    |> then(fn multi ->
      dispatches_attrs
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {attrs, idx}, multi ->
        changeset =
          %Dispatch{id: Uniq.UUID.uuid7()}
          |> Dispatch.changeset(attrs)

        Ecto.Multi.insert(multi, {:dispatch, idx}, changeset, prefix: @prefix)
      end)
    end)
    |> repo.transaction()
  end

  @doc "Gets a dispatch by ID."
  def get_dispatch(id) do
    repo = Repo.repo()
    repo.get(Dispatch, id, prefix: @prefix)
  end

  @doc "Gets a dispatch by connector type and connector event ID."
  def get_by_connector_event_id(connector_type, connector_event_id) do
    repo = Repo.repo()

    from(d in Dispatch,
      where: d.connector_type == ^connector_type,
      where: d.connector_event_id == ^connector_event_id
    )
    |> repo.one(prefix: @prefix)
  end

  @doc "Lists dispatches for a source event."
  def list_by_event(event_id) do
    repo = Repo.repo()

    from(d in Dispatch,
      where: d.event_id == ^event_id,
      order_by: [asc: d.inserted_at]
    )
    |> repo.all(prefix: @prefix)
  end

  @doc "Lists dispatches for a workspace and connector type."
  def list_by_workspace(workspace_id, connector_type, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, @default_workspace_list_limit)
    statuses = Keyword.get(opts, :statuses)

    query =
      from(d in Dispatch,
        where: d.workspace_id == ^workspace_id,
        where: d.connector_type == ^connector_type,
        order_by: [desc: d.inserted_at],
        limit: ^limit
      )

    query =
      if statuses do
        from(d in query, where: d.status in ^statuses)
      else
        query
      end

    repo.all(query, prefix: @prefix)
  end

  @doc "Lists pending/retryable dispatches for a connector type."
  def list_pending(connector_type, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, @default_pending_list_limit)
    now = DateTime.utc_now()

    from(d in Dispatch,
      where: d.connector_type == ^connector_type,
      where: d.status in ["pending", "failed", "rate_limited"],
      where: is_nil(d.next_retry_at) or d.next_retry_at <= ^now,
      where: d.attempts < d.max_attempts,
      order_by: [asc: d.next_retry_at, asc: d.inserted_at],
      limit: ^limit
    )
    |> repo.all(prefix: @prefix)
  end

  @doc "Updates a dispatch with delivery result metadata."
  def update_delivery(dispatch, attrs) do
    repo = Repo.repo()

    dispatch
    |> Dispatch.delivery_changeset(attrs)
    |> repo.update(prefix: @prefix)
  end

  @doc "Checks if a workspace+connector_type has credential errors."
  def has_credential_errors?(workspace_id, connector_type) do
    repo = Repo.repo()

    from(d in Dispatch,
      where: d.workspace_id == ^workspace_id,
      where: d.connector_type == ^connector_type,
      where: d.status == "credential_error",
      limit: 1
    )
    |> repo.exists?(prefix: @prefix)
  end

  @doc """
  Finds connector-eligible events in a time window that are missing dispatches
  for the given connector type. Used by the reconciliation flow.
  """
  def find_missing_dispatches(connector_type, workspace_id, since, event_types) do
    repo = Repo.repo()

    from(e in {"ga_events", Event},
      left_join: d in Dispatch,
      on:
        d.event_id == e.id and
          d.event_inserted_at == e.inserted_at and
          d.connector_type == ^connector_type,
      where: e.workspace_id == ^workspace_id,
      where: e.event_type in ^event_types,
      where: e.inserted_at >= ^since,
      where: is_nil(d.id),
      select: e
    )
    |> repo.all(prefix: @prefix)
  end
end
