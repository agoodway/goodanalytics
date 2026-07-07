defmodule GoodAnalytics.Connectors.EventMappings do
  @moduledoc """
  Context for workspace-scoped custom event connector mappings.
  """

  alias GoodAnalytics.Connectors.EventMapping
  alias GoodAnalytics.Repo

  import Ecto.Query

  @prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @doc "Creates a connector event mapping."
  def create_mapping(attrs) do
    repo = Repo.repo()

    %EventMapping{id: Uniq.UUID.uuid7()}
    |> EventMapping.changeset(attrs)
    |> repo.insert(prefix: @prefix)
  end

  @doc """
  Updates a connector event mapping's delivery configuration.

  Only `connector_event_name`, `config`, and `enabled` are mutable — the
  workspace and identity of the mapping are frozen at creation.
  """
  def update_mapping(%EventMapping{} = mapping, attrs) do
    repo = Repo.repo()

    mapping
    |> EventMapping.update_changeset(attrs)
    |> repo.update(prefix: @prefix)
  end

  @doc "Deletes a connector event mapping."
  def delete_mapping(%EventMapping{} = mapping) do
    Repo.repo().delete(mapping, prefix: @prefix)
  end

  @doc """
  Gets a mapping by id, scoped to a workspace.

  Returns `nil` when the mapping does not exist or belongs to another workspace.
  Callers must always pass their own `workspace_id` so a leaked mapping id can
  never be read, updated, or deleted across a tenant boundary.
  """
  def get_mapping(workspace_id, id) do
    from(m in EventMapping,
      where: m.workspace_id == ^workspace_id,
      where: m.id == ^id
    )
    |> Repo.repo().one(prefix: @prefix)
  end

  @doc "Gets a workspace mapping by event name and connector type."
  def get_mapping(workspace_id, event_name, connector_type) do
    repo = Repo.repo()
    normalized_event_name = normalize_event_name(event_name)
    connector_type = normalize_connector_type(connector_type)

    from(m in EventMapping,
      where: m.workspace_id == ^workspace_id,
      where: m.event_name == ^normalized_event_name,
      where: m.connector_type == ^connector_type
    )
    |> repo.one(prefix: @prefix)
  end

  @doc "Lists mappings for a workspace, optionally scoped to one connector type."
  def list_mappings(workspace_id, connector_type \\ nil) do
    repo = Repo.repo()

    query =
      from(m in EventMapping,
        where: m.workspace_id == ^workspace_id,
        order_by: [asc: m.connector_type, asc: m.event_name]
      )

    query =
      case connector_type do
        nil -> query
        type -> from(m in query, where: m.connector_type == ^normalize_connector_type(type))
      end

    repo.all(query, prefix: @prefix)
  end

  @doc "Returns an enabled mapping for a custom event and connector."
  def enabled_mapping_for_event(workspace_id, event_name, connector_type) do
    repo = Repo.repo()
    normalized_event_name = normalize_event_name(event_name)
    connector_type = normalize_connector_type(connector_type)

    from(m in EventMapping,
      where: m.workspace_id == ^workspace_id,
      where: m.event_name == ^normalized_event_name,
      where: m.connector_type == ^connector_type,
      where: m.enabled == true
    )
    |> repo.one(prefix: @prefix)
  end

  @doc "Lists enabled custom event names mapped for a workspace and connector."
  def enabled_event_names(workspace_id, connector_type) do
    repo = Repo.repo()
    connector_type = normalize_connector_type(connector_type)

    from(m in EventMapping,
      where: m.workspace_id == ^workspace_id,
      where: m.connector_type == ^connector_type,
      where: m.enabled == true,
      order_by: [asc: m.event_name],
      select: m.event_name
    )
    |> repo.all(prefix: @prefix)
  end

  @doc """
  Lists the enabled mapping structs for a workspace and connector.

  Reconciliation loads these once per connector and indexes them by event name,
  so it can gate eligibility and build snapshots without a per-event query.
  """
  def list_enabled_mappings(workspace_id, connector_type) do
    repo = Repo.repo()
    connector_type = normalize_connector_type(connector_type)

    from(m in EventMapping,
      where: m.workspace_id == ^workspace_id,
      where: m.connector_type == ^connector_type,
      where: m.enabled == true,
      order_by: [asc: m.event_name]
    )
    |> repo.all(prefix: @prefix)
  end

  defp normalize_event_name(value) when is_binary(value), do: String.trim(value)
  defp normalize_event_name(value), do: value

  defp normalize_connector_type(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_connector_type(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end
end
