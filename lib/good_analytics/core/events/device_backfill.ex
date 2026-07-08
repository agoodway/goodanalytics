defmodule GoodAnalytics.Core.Events.DeviceBackfill do
  @moduledoc """
  Runtime API for backfilling event-grain device columns from stored user agents.

  This module is safe to call from compiled application code, releases, remote
  consoles, or local maintenance tooling. It intentionally does not depend on
  Mix so deployed environments can run the backfill directly.
  """

  import Ecto.Query

  require Logger

  alias GoodAnalytics.Core.Events.Event
  alias GoodAnalytics.Devices
  alias GoodAnalytics.Repo

  @default_batch_size 5_000

  @type cursor :: %{id: Ecto.UUID.t(), inserted_at: DateTime.t()}

  @doc """
  Backfills all remaining events in batches.

  Options:

    * `:batch_size` - maximum rows to process per batch. Defaults to `5000`.

  Returns `{:ok, total_updated}` after all currently eligible rows have been
  processed. Eligible rows have `device_type IS NULL` and a non-NULL
  `user_agent`.
  """
  @spec run(keyword()) :: {:ok, non_neg_integer()}
  def run(opts \\ []) do
    opts = normalize_opts(opts)
    run(opts, 0)
  end

  @doc """
  Backfills one batch of events.

  Returns `{:updated, count, cursor}` when rows were updated, or `{:done, 0}`
  when no eligible rows remain.
  """
  @spec run_batch(keyword()) :: {:updated, non_neg_integer(), cursor()} | {:done, 0}
  def run_batch(opts \\ []) do
    opts = normalize_opts(opts)
    repo = Repo.repo()
    prefix = GoodAnalytics.schema_name()

    rows =
      Event
      |> eligible_events_query(opts[:batch_size])
      |> repo.all(prefix: prefix)

    case rows do
      [] ->
        {:done, 0}

      rows ->
        updated =
          Enum.reduce(rows, 0, fn event, total ->
            attrs = event.user_agent |> Devices.parse() |> Devices.to_event_attrs()
            set = attrs |> ensure_terminal_device_type() |> Map.to_list()

            {count, _} =
              from(e in Event,
                where: e.id == ^event.id,
                where: e.inserted_at == ^event.inserted_at,
                where: is_nil(e.device_type)
              )
              |> repo.update_all([set: set], prefix: prefix)

            total + count
          end)

        cursor_event = List.last(rows)
        cursor = %{id: cursor_event.id, inserted_at: cursor_event.inserted_at}

        Logger.info("Backfilled device columns for #{updated} ga_events rows")

        {:updated, updated, cursor}
    end
  end

  defp run(opts, total_updated) do
    case run_batch(opts) do
      {:updated, 0, _cursor} ->
        {:ok, total_updated}

      {:updated, count, _cursor} ->
        run(opts, total_updated + count)

      {:done, 0} ->
        {:ok, total_updated}
    end
  end

  defp eligible_events_query(query, batch_size) do
    from(e in query,
      where: is_nil(e.device_type),
      where: not is_nil(e.user_agent),
      order_by: [asc: e.inserted_at, asc: e.id],
      select: %{id: e.id, inserted_at: e.inserted_at, user_agent: e.user_agent},
      limit: ^batch_size
    )
  end

  defp ensure_terminal_device_type(%{} = attrs) do
    Map.put_new(attrs, :device_type, "unknown")
  end

  defp normalize_opts(opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    if is_integer(batch_size) and batch_size > 0 do
      [batch_size: batch_size]
    else
      raise ArgumentError, ":batch_size must be a positive integer"
    end
  end
end
