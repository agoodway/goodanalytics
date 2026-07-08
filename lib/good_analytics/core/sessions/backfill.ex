defmodule GoodAnalytics.Core.Sessions.Backfill do
  @moduledoc """
  Runtime API for backfilling historical sessions.

  Walks `ga_events` rows with no `session_id`, ordered by
  `{visitor_id, inserted_at, id}`, builds `ga_sessions`, and stamps each event.
  It is resumable because each batch only selects unstamped events.

  For large historical tables, create a temporary partial index before the
  rollout and drop it after the backfill finishes:

      CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_ga_events_session_backfill
        ON good_analytics.ga_events (visitor_id, inserted_at, id)
        WHERE session_id IS NULL;

  This module does not depend on Mix, so compiled production releases can call
  it from application code, a release task, or a remote console.
  """

  import Ecto.Query

  require Logger

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Core.Sessions.{Acquisition, Session, SessionFields}
  alias GoodAnalytics.Repo

  @default_batch_size 5_000
  @session_window_seconds 30 * 60

  @doc """
  Runs batches until no eligible events remain.

  Options:

    * `:batch_size` - maximum events per batch. Defaults to `5000`.
    * `:since` - optional `DateTime` lower bound for `inserted_at`.

  Returns `{:ok, %{events: total_stamped, sessions: total_created}}`.
  """
  @spec run(keyword()) :: {:ok, %{events: non_neg_integer(), sessions: non_neg_integer()}}
  def run(opts \\ []) do
    opts = normalize_opts(opts)
    run(opts, %{events: 0, sessions: 0})
  end

  @doc """
  Processes one batch of unstamped historical events.
  """
  @spec run_batch(keyword()) :: {:ok, %{events: non_neg_integer(), sessions: non_neg_integer()}}
  def run_batch(opts \\ []) do
    opts = normalize_opts(opts)
    repo = Repo.repo()
    prefix = GoodAnalytics.schema_name()

    events =
      Event
      |> unstamped_events_query(opts)
      |> repo.all(prefix: prefix)

    summary =
      Enum.reduce(events, %{events: 0, sessions: 0}, fn event, acc ->
        result = backfill_event(repo, prefix, event)
        stamped? = result in [:created, :updated]

        %{
          events: acc.events + if(stamped?, do: 1, else: 0),
          sessions: acc.sessions + if(result == :created, do: 1, else: 0)
        }
      end)

    if summary.events > 0 do
      Logger.info(
        "SessionBackfill: stamped #{summary.events} events, created #{summary.sessions} sessions"
      )
    end

    {:ok, summary}
  end

  defp run(opts, acc) do
    case run_batch(opts) do
      {:ok, %{events: 0}} ->
        {:ok, acc}

      {:ok, summary} ->
        run(opts, %{
          events: acc.events + summary.events,
          sessions: acc.sessions + summary.sessions
        })
    end
  end

  defp backfill_event(repo, prefix, %Event{} = event) do
    case repo.transaction(fn -> lock_and_backfill_event(repo, prefix, event) end) do
      {:ok, result} -> result
      {:error, :skipped} -> :skipped
    end
  end

  defp lock_and_backfill_event(repo, prefix, %Event{} = event) do
    case lock_unstamped_event(repo, prefix, event) do
      nil -> :skipped
      %Event{} = event -> backfill_locked_event(repo, prefix, event)
    end
  end

  defp backfill_locked_event(repo, prefix, %Event{} = event) do
    attrs = event_attrs(event)

    case backfill_decision(repo, prefix, event, attrs) do
      :create ->
        session = create_session(repo, prefix, event, attrs)
        stamp_event_or_rollback(repo, prefix, event, session.id)
        :created

      {:update, live, decision} ->
        session = update_session(repo, prefix, live, event, attrs, decision)
        stamp_event_or_rollback(repo, prefix, event, session.id)
        :updated
    end
  end

  defp lock_unstamped_event(repo, prefix, %Event{} = event) do
    from(e in Event,
      where: e.id == ^event.id,
      where: e.inserted_at == ^event.inserted_at,
      where: is_nil(e.session_id),
      lock: "FOR UPDATE",
      limit: 1
    )
    |> repo.one(prefix: prefix)
  end

  defp backfill_decision(repo, prefix, %Event{} = event, attrs) do
    case find_historical_live_session(repo, prefix, event) do
      nil ->
        :create

      %Session{} = live ->
        case Acquisition.decision(live, attrs) do
          :new_session -> :create
          decision -> {:update, live, decision}
        end
    end
  end

  defp find_historical_live_session(repo, prefix, %Event{} = event) do
    cutoff = DateTime.add(event.inserted_at, -@session_window_seconds, :second)

    from(s in Session,
      where: s.workspace_id == ^event.workspace_id,
      where: s.visitor_id == ^event.visitor_id,
      where: s.last_event_at >= ^cutoff,
      where: s.last_event_at <= ^event.inserted_at,
      order_by: [desc: s.last_event_at],
      lock: "FOR UPDATE",
      limit: 1
    )
    |> repo.one(prefix: prefix)
  end

  defp create_session(repo, prefix, %Event{} = event, attrs) do
    attrs =
      event.event_type
      |> SessionFields.new_session_attrs(attrs, event.inserted_at)
      |> Map.merge(%{
        workspace_id: event.workspace_id,
        visitor_id: event.visitor_id
      })

    %Session{id: Uniq.UUID.uuid7()}
    |> Session.changeset(attrs)
    |> repo.insert!(prefix: prefix)
  end

  defp update_session(repo, prefix, %Session{} = live, %Event{} = event, attrs, decision) do
    changes = SessionFields.update_session_attrs(live, event.event_type, attrs, event.inserted_at)

    changes =
      if decision == :update_source do
        Map.merge(changes, Acquisition.to_session_acquisition(attrs))
      else
        changes
      end

    live
    |> Session.changeset(changes)
    |> repo.update!(prefix: prefix)
  end

  defp stamp_event_or_rollback(repo, prefix, %Event{} = event, session_id) do
    {count, _rows} =
      from(e in Event,
        where: e.id == ^event.id,
        where: e.inserted_at == ^event.inserted_at,
        where: is_nil(e.session_id)
      )
      |> repo.update_all([set: [session_id: session_id]], prefix: prefix)

    if count == 1, do: :ok, else: repo.rollback(:skipped)
  end

  defp unstamped_events_query(query, opts) do
    query
    |> where([e], is_nil(e.session_id))
    |> maybe_since(opts[:since])
    |> order_by([e], asc: e.visitor_id, asc: e.inserted_at, asc: e.id)
    |> limit(^opts[:batch_size])
  end

  defp maybe_since(query, nil), do: query
  defp maybe_since(query, %DateTime{} = since), do: where(query, [e], e.inserted_at >= ^since)

  defp event_attrs(%Event{} = event) do
    %{
      url: event.url,
      path: event.path,
      source_platform: event.source_platform,
      source_medium: event.source_medium,
      source_campaign: event.source_campaign,
      click_id: event.click_id,
      device_type: event.device_type,
      browser: event.browser,
      os: event.os
    }
  end

  defp normalize_opts(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    since = Keyword.get(opts, :since)

    unless is_integer(batch_size) and batch_size > 0 do
      raise ArgumentError, ":batch_size must be a positive integer"
    end

    unless is_nil(since) or match?(%DateTime{}, since) do
      raise ArgumentError, ":since must be a DateTime"
    end

    [batch_size: batch_size, since: since]
  end
end
