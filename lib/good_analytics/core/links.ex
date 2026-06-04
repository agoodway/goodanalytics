defmodule GoodAnalytics.Core.Links do
  @moduledoc """
  Context for link CRUD operations.
  """

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Links.Link
  alias GoodAnalytics.Core.Partners
  alias GoodAnalytics.PubSub
  alias GoodAnalytics.Repo

  import Ecto.Query

  # Default row cap for link listing and click history queries.
  @default_list_limit 50

  @doc "Creates a tracked link."
  def create_link(attrs) do
    repo = Repo.repo()

    changeset = Link.changeset(%Link{id: Uniq.UUID.uuid7()}, attrs)

    case check_active_partner(attrs) do
      :ok ->
        repo.insert(changeset, prefix: GoodAnalytics.schema_name())

      {:error, :inactive_partner} ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :partner_id,
           "must reference an active partner in the same workspace"
         )}
    end
  end

  defp check_active_partner(%{link_type: "referral", partner_id: pid, workspace_id: wid})
       when is_binary(pid) and is_binary(wid) do
    case Partners.get_active_partner(wid, pid) do
      nil -> {:error, :inactive_partner}
      _partner -> :ok
    end
  end

  defp check_active_partner(_attrs), do: :ok

  @doc "Gets a link by ID."
  def get_link(id) do
    Repo.repo().get(Link, id, prefix: GoodAnalytics.schema_name())
  end

  @doc "Gets a link by domain and key (only non-archived)."
  def get_link_by_key(domain, key) do
    repo = Repo.repo()

    from(l in Link,
      where: l.domain == ^domain,
      where: l.key == ^key,
      where: is_nil(l.archived_at)
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Resolves a live (non-archived, non-expired) link by domain and key.

  Returns `{:ok, link}`, `{:error, :not_found}`, or `{:error, :expired}`.
  """
  def resolve_live_link(domain, key) do
    domain
    |> get_link_by_key(key)
    |> live_link_result()
  end

  defp live_link_result(link) do
    case link do
      nil ->
        {:error, :not_found}

      %{expires_at: nil} = link ->
        {:ok, link}

      %{expires_at: expires_at} = link ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:ok, link}
        else
          {:error, :expired}
        end
    end
  end

  @doc "Gets all non-archived links that share a key, across every domain."
  def get_links_by_key(key) do
    repo = Repo.repo()

    from(l in Link,
      where: l.key == ^key,
      where: is_nil(l.archived_at)
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Resolves a live (non-archived, non-expired) link by key alone, ignoring domain.

  Useful when the public host is unavailable at redirect time — e.g. behind a
  CDN/edge proxy that rewrites the `Host` header, or when the short-link domain
  differs from the backend host. Keys are globally unique in practice, but the
  `(domain, key)` schema permits the same key under different domains, so this
  returns `{:error, :ambiguous}` when more than one *live* link shares the key.

  Returns `{:ok, link}`, `{:error, :not_found}`, `{:error, :expired}`, or
  `{:error, :ambiguous}`.
  """
  def resolve_live_link_by_key(key) do
    case get_links_by_key(key) do
      [] -> {:error, :not_found}
      [link] -> live_link_result(link)
      links -> resolve_ambiguous_by_key(links)
    end
  end

  defp resolve_ambiguous_by_key(links) do
    case Enum.filter(links, &live_link?/1) do
      [link] -> {:ok, link}
      [] -> {:error, :expired}
      _ -> {:error, :ambiguous}
    end
  end

  defp live_link?(link), do: match?({:ok, _}, live_link_result(link))

  @doc "Lists links for a workspace with optional filters."
  def list_links(workspace_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, @default_list_limit)
    offset = Keyword.get(opts, :offset, 0)

    from(l in Link,
      where: l.workspace_id == ^workspace_id,
      where: is_nil(l.archived_at),
      order_by: [desc: l.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  @doc "Archives a link (soft delete, frees up domain/key)."
  def archive_link(id) do
    repo = Repo.repo()

    case get_link(id) do
      nil ->
        {:error, :not_found}

      link ->
        link
        |> Link.changeset(%{archived_at: DateTime.utc_now()})
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Updates a link."
  def update_link(id, attrs) do
    repo = Repo.repo()

    case get_link(id) do
      nil ->
        {:error, :not_found}

      link ->
        link
        |> Link.changeset(attrs)
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Gets aggregated stats for a link."
  def link_stats(link_id, _opts \\ []) do
    case get_link(link_id) do
      nil ->
        {:error, :not_found}

      link ->
        {:ok,
         %{
           total_clicks: link.total_clicks,
           unique_clicks: link.unique_clicks,
           total_leads: link.total_leads,
           total_sales: link.total_sales,
           total_revenue_cents: link.total_revenue_cents
         }}
    end
  end

  @doc "Atomically increments click counters on a link."
  def increment_clicks(link_id, unique? \\ true) do
    repo = Repo.repo()

    increments =
      if unique?,
        do: [total_clicks: 1, unique_clicks: 1],
        else: [total_clicks: 1]

    workspace_id =
      from(l in Link, where: l.id == ^link_id, select: l.workspace_id)
      |> repo.one(prefix: GoodAnalytics.schema_name())

    result =
      from(l in Link, where: l.id == ^link_id)
      |> repo.update_all([inc: increments], prefix: GoodAnalytics.schema_name())

    if elem(result, 0) > 0 and workspace_id do
      broadcast_click(link_id, workspace_id, unique?)
    end

    result
  end

  defp broadcast_click(link_id, workspace_id, unique?) do
    message = {:link_click, link_id, unique?}

    Phoenix.PubSub.broadcast(PubSub, "good_analytics:link_clicks", message)

    Phoenix.PubSub.broadcast(
      PubSub,
      "good_analytics:link_clicks:#{workspace_id}",
      message
    )
  end

  @doc "Gets click events for a link."
  def link_clicks(link_id, opts \\ []) do
    repo = Repo.repo()
    limit = Keyword.get(opts, :limit, @default_list_limit)
    offset = Keyword.get(opts, :offset, 0)

    from(e in Event,
      where: e.link_id == ^link_id,
      where: e.event_type == "link_click",
      order_by: [desc: e.inserted_at],
      limit: ^limit,
      offset: ^offset
    )
    |> repo.all(prefix: GoodAnalytics.schema_name())
  end

  # ── Workspace-scoped variants (for API layer) ──

  @doc "Gets a link by ID, scoped to a workspace."
  def get_link(workspace_id, id) do
    repo = Repo.repo()

    from(l in Link,
      where: l.id == ^id,
      where: l.workspace_id == ^workspace_id
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  @doc "Updates a link, scoped to a workspace."
  def update_link(workspace_id, id, attrs) do
    repo = Repo.repo()

    case get_link(workspace_id, id) do
      nil -> {:error, :not_found}
      link -> link |> Link.changeset(attrs) |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Archives a link, scoped to a workspace."
  def archive_link(workspace_id, id) do
    repo = Repo.repo()

    case get_link(workspace_id, id) do
      nil ->
        {:error, :not_found}

      link ->
        link
        |> Link.changeset(%{archived_at: DateTime.utc_now()})
        |> repo.update(prefix: GoodAnalytics.schema_name())
    end
  end

  @doc "Gets click events for a link, scoped to a workspace."
  def link_clicks(workspace_id, id, opts) do
    case get_link(workspace_id, id) do
      nil ->
        {:error, :not_found}

      _link ->
        link_clicks(id, opts)
    end
  end
end
