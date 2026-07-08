defmodule GoodAnalytics.Core.Sessions do
  @moduledoc """
  Server-side sessionization context.

  `sessionize/3` resolves the live session for a `{workspace_id, visitor_id}`
  with an `anonymous_id` fallback for freshly minted visitor ids, then applies
  the 30-minute inactivity boundary plus acquisition-change splitting.
  """

  import Ecto.Query

  alias GoodAnalytics.Core.Sessions.{Acquisition, Session, SessionFields}
  alias GoodAnalytics.Core.Visitors.Visitor
  alias GoodAnalytics.Maps
  alias GoodAnalytics.Repo

  @window_seconds 30 * 60
  @advisory_lock_max 9_223_372_036_854_775_807

  @typedoc "The session key carried from the recorder."
  @type key :: %{
          required(:workspace_id) => Ecto.UUID.t(),
          required(:visitor_id) => Ecto.UUID.t(),
          optional(:anonymous_id) => String.t() | nil
        }

  @doc """
  Find-or-create the live session for `key` and fold the event into it.

  The event timestamp is read from `attrs[:__ts__]` or `attrs["__ts__"]`;
  when absent, the current UTC time is used.
  """
  @spec sessionize(key(), String.t(), map()) :: {:ok, Session.t()} | {:error, term()}
  def sessionize(%{workspace_id: ws, visitor_id: vid} = key, event_type, attrs) do
    repo = Repo.repo()
    ts = event_timestamp(attrs)
    attrs = strip_internal_attrs(attrs)
    anon = normalize_anonymous_id(Map.get(key, :anonymous_id))
    key = Map.put(key, :anonymous_id, anon)

    repo.transaction(fn ->
      acquire_locks(repo, ws, vid, anon)

      case find_live_session(repo, ws, vid, anon, ts) do
        nil ->
          create_session(repo, key, event_type, attrs, ts)

        %Session{} = live ->
          fold_into(repo, live, key, event_type, attrs, ts)
      end
    end)
  end

  @doc """
  Attaches an engagement beacon to the visitor's live session.

  Accumulates engaged seconds from `engaged_ms`, bumps `last_event_at`,
  refreshes `is_engaged`, and recomputes duration using the same 30-minute
  per-hop cap as normal session updates. This never creates a session and never
  un-bounces one.
  """
  @spec record_engagement(key(), map(), DateTime.t()) :: {:ok, Session.t()} | :no_session
  def record_engagement(%{workspace_id: ws, visitor_id: vid} = key, attrs, ts) do
    repo = Repo.repo()
    anon = normalize_anonymous_id(Map.get(key, :anonymous_id))

    repo.transaction(fn ->
      acquire_locks(repo, ws, vid, anon)

      case find_live_session(repo, ws, vid, anon, ts) do
        nil -> repo.rollback(:no_session)
        %Session{} = live -> apply_engagement(repo, live, attrs, ts)
      end
    end)
    |> case do
      {:ok, session} -> {:ok, session}
      {:error, :no_session} -> :no_session
    end
  end

  @doc "Returns the live session for a visitor within the window, or nil."
  @spec find_live_session(module(), Ecto.UUID.t(), Ecto.UUID.t(), String.t() | nil, DateTime.t()) ::
          Session.t() | nil
  def find_live_session(repo, ws, vid, anon, ts) do
    cutoff = DateTime.add(ts, -@window_seconds, :second)

    find_by_visitor(repo, ws, vid, cutoff) || find_by_anonymous(repo, ws, anon, cutoff)
  end

  defp find_by_visitor(repo, ws, vid, cutoff) do
    from(s in Session,
      where: s.workspace_id == ^ws and s.visitor_id == ^vid,
      where: s.last_event_at >= ^cutoff,
      order_by: [desc: s.last_event_at],
      lock: "FOR UPDATE",
      limit: 1
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  defp find_by_anonymous(_repo, _ws, nil, _cutoff), do: nil

  defp find_by_anonymous(repo, ws, anon, cutoff) do
    from(s in Session,
      where: s.workspace_id == ^ws and s.anonymous_id == ^anon,
      where: s.last_event_at >= ^cutoff,
      order_by: [desc: s.last_event_at],
      lock: "FOR UPDATE",
      limit: 1
    )
    |> repo.one(prefix: GoodAnalytics.schema_name())
  end

  defp create_session(repo, key, event_type, attrs, ts) do
    base = %{
      workspace_id: key.workspace_id,
      visitor_id: key.visitor_id,
      anonymous_id: Map.get(key, :anonymous_id)
    }

    attrs =
      event_type
      |> SessionFields.new_session_attrs(attrs, ts)
      |> Map.merge(base)

    session =
      %Session{id: Uniq.UUID.uuid7()}
      |> Session.changeset(attrs)
      |> insert_or_rollback(repo)

    increment_total_sessions(repo, key.visitor_id)

    session
  end

  defp fold_into(repo, live, key, event_type, attrs, ts) do
    case Acquisition.decision(live, attrs) do
      :new_session ->
        create_session(repo, key, event_type, attrs, ts)

      :continue ->
        update_session(repo, live, key, event_type, attrs, ts, %{})

      :update_source ->
        update_session(
          repo,
          live,
          key,
          event_type,
          attrs,
          ts,
          Acquisition.to_session_acquisition(attrs)
        )
    end
  end

  defp update_session(repo, live, key, event_type, attrs, ts, extra_attrs) do
    changes =
      live
      |> SessionFields.update_session_attrs(event_type, attrs, ts)
      |> Map.merge(extra_attrs)
      |> Map.merge(%{
        visitor_id: key.visitor_id,
        anonymous_id: normalize_anonymous_id(Map.get(key, :anonymous_id)) || live.anonymous_id
      })

    session =
      live
      |> Session.changeset(changes)
      |> update_or_rollback(repo)

    reconcile_total_sessions(repo, live.visitor_id, key.visitor_id)

    session
  end

  defp insert_or_rollback(changeset, repo) do
    case repo.insert(changeset, prefix: GoodAnalytics.schema_name()) do
      {:ok, session} -> session
      {:error, changeset} -> repo.rollback({:insert_session, changeset})
    end
  end

  defp update_or_rollback(changeset, repo) do
    case repo.update(changeset, prefix: GoodAnalytics.schema_name()) do
      {:ok, session} -> session
      {:error, changeset} -> repo.rollback({:update_session, changeset})
    end
  end

  defp increment_total_sessions(repo, visitor_id) do
    from(v in Visitor, where: v.id == ^visitor_id)
    |> repo.update_all([inc: [total_sessions: 1]], prefix: GoodAnalytics.schema_name())
  end

  defp reconcile_total_sessions(_repo, visitor_id, visitor_id), do: :ok

  defp reconcile_total_sessions(repo, previous_visitor_id, current_visitor_id) do
    from(v in Visitor, where: v.id == ^previous_visitor_id)
    |> repo.update_all([inc: [total_sessions: -1]], prefix: GoodAnalytics.schema_name())

    increment_total_sessions(repo, current_visitor_id)

    :ok
  end

  defp apply_engagement(repo, live, attrs, ts) do
    added = attrs |> Maps.get_indifferent(:engaged_ms) |> engaged_seconds()
    engaged_seconds = (live.engaged_seconds || 0) + added
    duration_seconds = (live.duration_seconds || 0) + hop_seconds(live.last_event_at, ts)

    changes = %{
      last_event_at: max_datetime(live.last_event_at, ts),
      engaged_seconds: engaged_seconds,
      duration_seconds: duration_seconds,
      is_engaged: live.is_engaged == true || engaged_seconds >= 10 || (live.pageviews || 0) >= 2
    }

    live
    |> Session.changeset(changes)
    |> update_or_rollback(repo)
  end

  defp engaged_seconds(ms) when is_integer(ms) and ms > 0, do: div(ms, 1000)
  defp engaged_seconds(ms) when is_float(ms) and ms > 0, do: ms |> trunc() |> div(1000)
  defp engaged_seconds(_ms), do: 0

  defp hop_seconds(nil, _ts), do: 0

  defp hop_seconds(last_event_at, ts) do
    ts
    |> DateTime.diff(last_event_at, :second)
    |> max(0)
    |> min(@window_seconds)
  end

  defp max_datetime(nil, ts), do: ts

  defp max_datetime(current, ts) do
    if DateTime.compare(ts, current) == :lt, do: current, else: ts
  end

  defp event_timestamp(attrs) do
    Maps.get_indifferent(attrs, :__ts__) || DateTime.utc_now()
  end

  defp strip_internal_attrs(attrs) do
    attrs
    |> Map.delete(:__ts__)
    |> Map.delete("__ts__")
  end

  defp normalize_anonymous_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_anonymous_id(_value), do: nil

  defp acquire_locks(repo, ws, vid, anon) do
    ws
    |> lock_materials(vid, anon)
    |> Enum.map(&lock_key/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn key ->
      repo.query!("SELECT pg_advisory_xact_lock($1::bigint)", [key])
    end)
  end

  defp lock_materials(ws, vid, anon) when is_binary(anon) and anon != "" do
    [
      "#{GoodAnalytics.schema_name()}:visitor:#{ws}:#{vid}",
      "#{GoodAnalytics.schema_name()}:anonymous:#{ws}:#{anon}"
    ]
  end

  defp lock_materials(ws, vid, _anon) do
    ["#{GoodAnalytics.schema_name()}:visitor:#{ws}:#{vid}"]
  end

  defp lock_key(material) do
    <<unsigned::unsigned-64, _::binary>> = :crypto.hash(:sha256, material)
    Bitwise.band(unsigned, @advisory_lock_max)
  end
end
