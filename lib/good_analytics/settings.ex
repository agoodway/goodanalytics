defmodule GoodAnalytics.Settings do
  @moduledoc """
  Per-workspace runtime settings with Nebulex caching.

  Settings are stored in `ga_settings` and cached with a configurable TTL
  (default 5 minutes). Cache is invalidated on put/delete.

  ## Usage

      GoodAnalytics.Settings.get(workspace_id, "tracking.cookie_name", "_ga_good")
      GoodAnalytics.Settings.put(workspace_id, "tracking.cookie_name", "_my_cookie")
      GoodAnalytics.Settings.delete(workspace_id, "tracking.cookie_name")

  """

  alias GoodAnalytics.Cache
  alias GoodAnalytics.Repo
  alias GoodAnalytics.Settings.Setting

  import Ecto.Query

  @cache Cache
  @default_ttl :timer.minutes(5)
  @not_found :__ga_settings_not_found__

  @doc """
  Gets a setting value, checking cache first.

  Returns `default` if the setting doesn't exist.
  """
  def get(workspace_id, key, default \\ nil) do
    cache_key = cache_key(workspace_id, key)

    case @cache.get(cache_key) do
      @not_found ->
        default

      nil ->
        case fetch_from_db(workspace_id, key) do
          {:ok, value} ->
            @cache.put(cache_key, value, ttl: ttl())
            value

          :error ->
            @cache.put(cache_key, @not_found, ttl: ttl())
            default
        end

      value ->
        value
    end
  end

  @doc """
  Sets a setting value. Creates or updates the setting and invalidates cache.
  """
  def put(workspace_id, key, value) do
    repo = Repo.repo()
    now = DateTime.utc_now()

    attrs = %{
      workspace_id: workspace_id,
      key: key,
      value: wrap_value(value),
      inserted_at: now,
      updated_at: now
    }

    result =
      %Setting{id: Uniq.UUID.uuid7()}
      |> Setting.changeset(attrs)
      |> repo.insert(
        prefix: GoodAnalytics.schema_name(),
        on_conflict: {:replace, [:value, :updated_at]},
        conflict_target: [:workspace_id, :key]
      )

    case result do
      {:ok, setting} ->
        @cache.delete(cache_key(workspace_id, key))
        {:ok, setting}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a setting and invalidates cache.
  """
  def delete(workspace_id, key) do
    repo = Repo.repo()

    {count, _} =
      Setting
      |> where([s], s.workspace_id == ^workspace_id and s.key == ^key)
      |> repo.delete_all(prefix: GoodAnalytics.schema_name())

    @cache.delete(cache_key(workspace_id, key))
    {:ok, count}
  end

  defp fetch_from_db(workspace_id, key) do
    repo = Repo.repo()

    case repo.one(
           from(s in Setting,
             where: s.workspace_id == ^workspace_id and s.key == ^key,
             select: s.value
           ),
           prefix: GoodAnalytics.schema_name()
         ) do
      nil -> :error
      value -> {:ok, unwrap_value(value)}
    end
  end

  # JSONB requires a map at the top level, so we wrap scalar values.
  defp wrap_value(value) when is_map(value), do: value
  defp wrap_value(value), do: %{"_v" => value}

  defp unwrap_value(%{"_v" => value}), do: value
  defp unwrap_value(value), do: value

  defp cache_key(workspace_id, key), do: {:ga_setting, workspace_id, key}

  defp ttl do
    Application.get_env(:good_analytics, :settings_cache_ttl, @default_ttl)
  end
end
