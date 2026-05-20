defmodule GoodAnalytics.Core.Partners do
  @moduledoc """
  Context for partner CRUD operations.
  """

  alias GoodAnalytics.Core.Partners.Partner
  alias GoodAnalytics.Repo

  import Ecto.Query

  @default_list_limit 50

  @doc "Creates a partner in the given workspace."
  def create_partner(attrs) do
    repo = Repo.repo()

    %Partner{id: Uniq.UUID.uuid7()}
    |> Partner.changeset(attrs)
    |> repo.insert(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a partner by ID."
  def get_partner(id) do
    Repo.repo().get(Partner, id, prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a partner by ID, scoped to a workspace."
  def get_partner(workspace_id, id) do
    repo = Repo.repo()

    from(p in Partner,
      where: p.id == ^id,
      where: p.workspace_id == ^workspace_id
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets an active partner by ID and workspace. Returns nil if not found or not active."
  def get_active_partner(workspace_id, id) do
    repo = Repo.repo()

    from(p in Partner,
      where: p.id == ^id,
      where: p.workspace_id == ^workspace_id,
      where: p.status == "active",
      where: is_nil(p.archived_at)
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets an active partner by key and workspace."
  def get_active_partner_by_key(workspace_id, key) do
    repo = Repo.repo()

    from(p in Partner,
      where: p.workspace_id == ^workspace_id,
      where: p.key == ^key,
      where: p.status == "active",
      where: is_nil(p.archived_at)
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Lists partners for a workspace (excludes archived by default)."
  def list_partners(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, @default_list_limit)
    offset = Keyword.get(opts, :offset, 0)
    include_archived = Keyword.get(opts, :include_archived, false)

    query =
      from(p in Partner,
        where: p.workspace_id == ^workspace_id,
        order_by: [desc: p.inserted_at],
        limit: ^limit,
        offset: ^offset
      )

    query =
      if include_archived do
        query
      else
        from(p in query, where: is_nil(p.archived_at))
      end

    repo.all(query, prefix: GoodAnalytics.schema_name())
  end

  @doc "Updates a partner."
  def update_partner(id, attrs) do
    repo = Repo.repo()

    case get_partner(id) do
      nil ->
        {:error, :not_found}

      partner ->
        partner
        |> Partner.update_changeset(attrs)
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Updates a partner, scoped to a workspace."
  def update_partner(workspace_id, id, attrs) do
    repo = Repo.repo()

    case get_partner(workspace_id, id) do
      nil ->
        {:error, :not_found}

      partner ->
        partner
        |> Partner.update_changeset(attrs)
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Archives a partner (sets status to archived and archived_at timestamp)."
  def archive_partner(id) do
    repo = Repo.repo()

    case get_partner(id) do
      nil ->
        {:error, :not_found}

      partner ->
        partner
        |> Partner.archive_changeset()
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Archives a partner, scoped to a workspace."
  def archive_partner(workspace_id, id) do
    repo = Repo.repo()

    case get_partner(workspace_id, id) do
      nil ->
        {:error, :not_found}

      partner ->
        partner
        |> Partner.archive_changeset()
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end
end
