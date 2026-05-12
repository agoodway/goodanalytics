defmodule GoodAnalytics.Core.IdentityResolver do
  @moduledoc """
  Resolves incoming tracking signals to a single visitor record.

  Signal priority (highest to lowest):
  1. person_external_id - post-signup, definitive identity
  2. ga_id cookie - our own attribution cookie, high confidence
  3. person_email - email address, high confidence
  4. fingerprint - ThumbmarkJS browser fingerprint, ~90% unique
  5. anonymous_id - random cookie, session-level identity
  6. click_id - from a specific link click

  When multiple signals match different visitor records, we MERGE them
  into a single record (keeping the oldest as primary), subject to
  merge confidence rules (fingerprint alone never triggers a merge).
  """

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Hooks
  alias GoodAnalytics.Maps
  alias GoodAnalytics.Repo

  import Ecto.Query

  @max_attribution_path 50

  @doc """
  Resolves signals to a visitor. Creates, updates, or merges as needed.

  ## Options

    * `:workspace_id` - required, scopes the lookup

  Returns `{:ok, visitor}` or `{:error, reason}`.
  """
  def resolve(signals, opts \\ []) do
    workspace_id = Keyword.fetch!(opts, :workspace_id)
    candidates = find_candidates(signals, workspace_id)

    case candidates do
      [] ->
        create_visitor(signals, workspace_id)

      [single] ->
        update_visitor(single, signals)

      [primary | duplicates] ->
        if merge_allowed?(signals, [primary | duplicates]) do
          merge_visitors(primary, duplicates, signals)
        else
          update_visitor(primary, signals)
        end
    end
  end

  @doc """
  Finds visitor candidates matching the given signals.

  Builds a dynamic OR query across all signal types, scoped to
  workspace and excluding merged visitors. Results are ordered
  by first_seen_at (oldest first, so primary is deterministic).
  """
  def find_candidates(signals, workspace_id) do
    repo = Repo.repo()

    conditions =
      []
      |> maybe_add_condition(signals[:person_external_id], fn cid ->
        dynamic([v], v.person_external_id == ^cid)
      end)
      |> maybe_add_condition(signals[:ga_id], fn ga_id ->
        dynamic([v], v.ga_id == ^ga_id)
      end)
      |> maybe_add_condition(signals[:person_email], fn email ->
        dynamic([v], v.person_email == ^email)
      end)
      |> maybe_add_condition(signals[:fingerprint], fn fp ->
        dynamic([v], fragment("? @> ARRAY[?]::text[]", v.fingerprints, ^fp))
      end)
      |> maybe_add_condition(signals[:anonymous_id], fn anon ->
        dynamic([v], fragment("? @> ARRAY[?]::text[]", v.anonymous_ids, ^anon))
      end)
      |> maybe_add_condition(signals[:click_id], fn click_id ->
        dynamic([v], fragment("? @> ARRAY[?]::uuid[]", v.click_ids, type(^click_id, Ecto.UUID)))
      end)

    case conditions do
      [] ->
        []

      _ ->
        or_expr =
          Enum.reduce(conditions, fn expr, acc ->
            dynamic([v], ^acc or ^expr)
          end)

        from(v in Visitor,
          where: v.workspace_id == ^workspace_id,
          where: v.status != "merged",
          where: ^or_expr
        )
        |> repo.all(prefix: GoodAnalytics.schema_name())
        |> Enum.sort_by(& &1.first_seen_at, DateTime)
    end
  end

  @doc """
  Determines if the matching signals are strong enough to merge candidates.

  Merge is allowed when at least one strong signal matches, or when
  two or more weak signals match. Fingerprint alone never triggers a merge.

  Strong signals: person_external_id, ga_id, person_email
  Weak signals: fingerprint, anonymous_id
  """
  def merge_allowed?(signals, _candidates) do
    strong_signals = [:person_external_id, :ga_id, :person_email]
    weak_signals = [:fingerprint, :anonymous_id]

    strong_count = Enum.count(strong_signals, &signals[&1])
    weak_count = Enum.count(weak_signals, &signals[&1])

    strong_count >= 1 or weak_count >= 2
  end

  @doc """
  Creates a new visitor from signals.
  """
  def create_visitor(signals, workspace_id) do
    repo = Repo.repo()
    now = DateTime.utc_now()

    attrs = %{
      workspace_id: workspace_id,
      fingerprints: List.wrap(signals[:fingerprint]),
      anonymous_ids: List.wrap(signals[:anonymous_id]),
      click_ids: List.wrap(signals[:click_id]),
      ga_id: signals[:ga_id],
      first_source: signals[:source],
      last_source: signals[:source],
      first_click_id: signals[:click_id],
      last_click_id: signals[:click_id],
      click_id_params: signals[:click_id_params] || %{},
      attribution_path: if(signals[:source], do: [signals[:source]], else: []),
      geo: signals[:geo] || %{},
      first_seen_at: now,
      last_seen_at: now
    }

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(attrs)
    |> repo.insert(prefix: GoodAnalytics.schema_name())
  end

  @doc """
  Updates an existing visitor with new signals.
  """
  def update_visitor(visitor, signals) do
    repo = Repo.repo()

    with {:ok, updated} <-
           visitor
           |> Visitor.changeset(signal_changes(visitor, signals))
           |> repo.update(prefix: GoodAnalytics.schema_name()) do
      # Geo write is intentionally separate from the changeset path so it can
      # be atomic: `Visitors.maybe_set_geo/2` issues a conditional UPDATE that
      # only succeeds when `geo` is still empty. This holds the first-event-
      # wins contract under concurrent click + beacon writes for the same
      # visitor. The visitor struct we return reflects the post-write state.
      maybe_apply_geo(updated, signals[:geo])
    end
  end

  defp signal_changes(visitor, signals) do
    %{
      last_seen_at: DateTime.utc_now(),
      last_source: signals[:source] || visitor.last_source,
      last_click_id: signals[:click_id] || visitor.last_click_id,
      fingerprints: add_to_array(visitor.fingerprints, signals[:fingerprint]),
      anonymous_ids: add_to_array(visitor.anonymous_ids, signals[:anonymous_id]),
      click_ids: add_to_array(visitor.click_ids, signals[:click_id]),
      ga_id: signals[:ga_id] || visitor.ga_id,
      click_id_params:
        Map.merge(visitor.click_id_params || %{}, signals[:click_id_params] || %{}),
      attribution_path: append_touchpoint(visitor.attribution_path, signals[:source])
    }
  end

  defp maybe_apply_geo(visitor, geo) when is_map(geo) and map_size(geo) > 0 do
    case Visitors.maybe_set_geo(visitor.id, geo) do
      {:ok, 1} -> {:ok, %{visitor | geo: geo}}
      {:ok, 0} -> {:ok, visitor}
      _ -> {:ok, visitor}
    end
  end

  defp maybe_apply_geo(visitor, _no_geo), do: {:ok, visitor}

  @doc """
  Merges duplicate visitors into the primary (oldest) visitor.

  Uses Ecto.Multi to atomically:
  1. Consolidate identity signals into the primary
  2. Apply new incoming signals
  3. Reassign all events from duplicates to primary
  4. Soft-delete duplicates (status = "merged")
  5. Fire :visitor_merged hook after commit
  """
  def merge_visitors(primary, duplicates, signals) do
    repo = Repo.repo()
    duplicate_ids = Enum.map(duplicates, & &1.id)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.run(:merge_signals, fn _repo, _changes ->
        # `pick_geo` runs once over the ORIGINAL set of visitors (not the
        # accumulator) so first-seen-wins is deterministic regardless of
        # reduction order or duplicate count.
        merged_geo = pick_geo([primary | duplicates])

        merged =
          Enum.reduce(duplicates, primary, fn dup, acc ->
            %{
              acc
              | fingerprints: Enum.uniq(acc.fingerprints ++ dup.fingerprints),
                anonymous_ids: Enum.uniq(acc.anonymous_ids ++ dup.anonymous_ids),
                click_ids: Enum.uniq(acc.click_ids ++ dup.click_ids),
                click_id_params:
                  Map.merge(acc.click_id_params || %{}, dup.click_id_params || %{}),
                attribution_path:
                  merge_attribution_paths(acc.attribution_path, dup.attribution_path)
            }
          end)

        {:ok, %{merged | geo: merged_geo}}
      end)
      |> Ecto.Multi.run(:update_primary, fn _repo, %{merge_signals: merged} ->
        update_visitor(merged, signals)
      end)
      |> Ecto.Multi.update_all(
        :reassign_events,
        from(e in Event, where: e.visitor_id in ^duplicate_ids),
        [set: [visitor_id: primary.id]],
        prefix: GoodAnalytics.schema_name()
      )
      |> Ecto.Multi.update_all(
        :mark_merged,
        from(v in Visitor, where: v.id in ^duplicate_ids),
        [
          set: [
            status: "merged",
            merged_into_id: primary.id,
            updated_at: DateTime.utc_now()
          ]
        ],
        prefix: GoodAnalytics.schema_name()
      )

    case repo.transaction(multi) do
      {:ok, %{update_primary: updated}} when is_struct(updated, Visitor) ->
        Hooks.notify_async(
          :visitor_merged,
          %{primary_id: primary.id, merged_ids: duplicate_ids},
          updated
        )

        {:ok, updated}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # First-observation-wins for geo on merge: the non-empty geo belonging to the
  # visitor with the earliest first_seen_at survives. Empty geos are skipped.
  # Returns `%{}` if no visitor has geo data.
  defp pick_geo(visitors) do
    visitors
    |> Enum.filter(fn v ->
      is_map(v.geo) and map_size(v.geo) > 0
    end)
    |> Enum.sort_by(& &1.first_seen_at, DateTime)
    |> case do
      [%{geo: geo} | _] -> geo
      [] -> %{}
    end
  end

  defp maybe_add_condition(conditions, nil, _builder), do: conditions
  defp maybe_add_condition(conditions, value, builder), do: [builder.(value) | conditions]

  defp add_to_array(list, nil), do: list
  defp add_to_array(list, val), do: Enum.uniq(List.wrap(val) ++ list)

  defp append_touchpoint(path, nil), do: path

  defp append_touchpoint(path, source) do
    (path ++ [Map.put(source, :timestamp, DateTime.utc_now())])
    |> cap_attribution_path()
  end

  defp merge_attribution_paths(a, b) do
    (a ++ b)
    |> Enum.sort_by(&touchpoint_sort_key/1)
    |> Enum.uniq()
    |> cap_attribution_path()
  end

  defp touchpoint_sort_key(touchpoint) when is_map(touchpoint) do
    case parse_touchpoint_timestamp(Maps.get_indifferent(touchpoint, :timestamp)) do
      {:ok, dt} -> {0, DateTime.to_unix(dt, :microsecond)}
      :error -> {1, 0}
    end
  end

  defp touchpoint_sort_key(_), do: {1, 0}

  defp parse_touchpoint_timestamp(%DateTime{} = dt), do: {:ok, dt}

  defp parse_touchpoint_timestamp(%NaiveDateTime{} = ndt) do
    DateTime.from_naive(ndt, "Etc/UTC")
  end

  defp parse_touchpoint_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        {:ok, dt}

      _ ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> DateTime.from_naive(ndt, "Etc/UTC")
          _ -> :error
        end
    end
  end

  defp parse_touchpoint_timestamp(_), do: :error

  defp cap_attribution_path(path) when length(path) > @max_attribution_path do
    Enum.take(path, -@max_attribution_path)
  end

  defp cap_attribution_path(path), do: path

  @doc """
  Identifies a visitor with the host app's known person attributes.

  If `person_external_id` or `person_email` already exists on another
  non-merged visitor in the same workspace, this triggers a merge into the
  older visitor (by `first_seen_at`) and then applies the remaining
  `person_attrs` (name, metadata, the un-collided identifier, etc.) to
  the survivor. The two collision keys are checked in order — `person_external_id`
  first, then `person_email` — so a single call carrying both can never
  produce two merges.
  """
  def identify(visitor, person_attrs) when is_struct(visitor, Visitor) do
    repo = Repo.repo()

    with :no_collision <-
           merge_on_collision(repo, visitor, person_attrs, :person_external_id),
         :no_collision <-
           merge_on_collision(repo, visitor, person_attrs, :person_email) do
      apply_identify(repo, visitor, person_attrs)
    else
      result -> result
    end
  end

  # When `person_attrs` carries `key` and another non-merged visitor in the
  # same workspace already holds that value, merge the older one as primary,
  # apply the remaining `person_attrs` to the survivor, and return
  # `{:ok, survivor}`. When `key` is missing or no other visitor holds the value,
  # return `:no_collision` so the caller can move on to the next collision key
  # (or fall through to a plain `apply_identify`).
  defp merge_on_collision(repo, visitor, person_attrs, key) do
    case Maps.get_indifferent(person_attrs, key) do
      nil -> :no_collision
      value -> resolve_collision(repo, visitor, person_attrs, key, value)
    end
  end

  defp resolve_collision(repo, visitor, person_attrs, key, value) do
    case find_other_visitor(repo, visitor, key, value) do
      nil -> :no_collision
      other -> merge_collided(repo, visitor, other, person_attrs, key, value)
    end
  end

  defp find_other_visitor(repo, visitor, key, value) do
    from(v in Visitor,
      where: v.workspace_id == ^visitor.workspace_id,
      where: field(v, ^key) == ^value,
      where: v.id != ^visitor.id,
      where: v.status != "merged"
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  defp merge_collided(repo, visitor, other_visitor, person_attrs, key, value) do
    [primary, duplicate] =
      Enum.sort_by([visitor, other_visitor], & &1.first_seen_at, DateTime)

    with {:ok, merged} <-
           merge_visitors(primary, [duplicate], %{key => value, :source => primary.last_source}) do
      apply_identify(repo, merged, person_attrs)
    end
  end

  @identify_keys ~w(person_external_id person_email person_name person_metadata)

  defp apply_identify(repo, visitor, person_attrs) do
    now = DateTime.utc_now()
    atom_keys = Enum.map(@identify_keys, &String.to_existing_atom/1)

    identify_attrs =
      person_attrs
      |> Map.take(@identify_keys ++ atom_keys)
      |> Map.new(fn
        {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
        {k, v} -> {k, v}
      end)
      |> Map.put_new(:status, "identified")
      |> Map.put_new(:identified_at, now)

    visitor
    |> Visitor.identify_changeset(identify_attrs)
    |> repo.update(prefix: GoodAnalytics.schema_name())
  end
end
