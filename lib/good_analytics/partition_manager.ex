defmodule GoodAnalytics.PartitionManager do
  @moduledoc """
  Manages monthly partition creation for `ga_events`.

  On startup, ensures partitions exist for the current month and 2 months
  ahead. Uses pgflow when available (preferred), falling back to direct SQL.

  ## With pgflow (recommended)

  Add `GoodAnalytics.Flows.CreatePartitions` to your PgFlow configuration:

      {PgFlow,
       repo: MyApp.Repo,
       flows: [GoodAnalytics.Flows.CreatePartitions]}

  The flow provides retry logic, execution history, and optional cron scheduling.

  ## Without pgflow

  The PartitionManager will create partitions directly via SQL on startup
  and every 24 hours.

  ## Recovery from a polluted default partition

  When a fresh deploy receives traffic before the manager's first tick, those
  rows land in `ga_events_default` because no monthly partition exists for
  the current period. A naïve `CREATE TABLE … PARTITION OF …` then raises
  `check_violation` because Postgres re-validates the default partition's
  implicit "no rows belong to a sibling" invariant.

  The manager detects this case and recovers without detaching the default
  partition (which would briefly leave inserts with no routing target):

  1. Acquire a Postgres advisory lock so a single node performs DDL.
  2. Take an `ACCESS EXCLUSIVE` lock on `ga_events`.
  3. Stage the offending rows from `ga_events_default` into an unlogged
     temp table, then `DELETE` them from default.
  4. `CREATE TABLE … PARTITION OF …` (now succeeds because default is
     clean for that range).
  5. `INSERT INTO ga_events SELECT * FROM staged` so the rows route into
     the new monthly child via the parent's partition tree.

  All of (2)–(5) run in one transaction. If the manager crashes between
  (2) and (5) the transaction rolls back; default keeps its rows.
  """

  use GenServer

  alias GoodAnalytics.Flows.CreatePartitions
  alias GoodAnalytics.Repo

  require Logger

  @check_interval :timer.hours(24)
  @ready_retry_delay :timer.seconds(1)
  @months_ahead 2

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if auto_create_partitions?() do
      schedule_check(@ready_retry_delay)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:create_partitions, state) do
    case attempt_partitions() do
      :ok ->
        schedule_check(@check_interval)

      :not_ready ->
        schedule_check(@ready_retry_delay)
    end

    {:noreply, state}
  end

  defp schedule_check(delay) do
    Process.send_after(self(), :create_partitions, delay)
  end

  defp attempt_partitions do
    cond do
      not repo_configured?() ->
        Logger.debug("GoodAnalytics: Skipping partition check (no repo configured)")
        :ok

      not repo_alive?() ->
        Logger.debug("GoodAnalytics: Repo not started yet, retrying soon")
        :not_ready

      true ->
        ensure_partitions()
        :ok
    end
  end

  @doc """
  Ensures partitions exist, using pgflow if available.

  When pgflow is running and the `ga_create_partitions` flow is registered,
  starts a flow run. Otherwise falls back to direct SQL creation.
  """
  def ensure_partitions do
    cond do
      not repo_configured?() ->
        Logger.debug("GoodAnalytics: Skipping partition check (no repo configured)")

      not repo_alive?() ->
        Logger.debug("GoodAnalytics: Skipping partition check (repo not started)")

      pgflow_available?() ->
        Logger.info("GoodAnalytics: Triggering partition creation via pgflow")

        case PgFlow.start_flow(CreatePartitions, %{}) do
          {:ok, run_id} ->
            Logger.info("GoodAnalytics: Partition flow started (run_id: #{run_id})")

          {:error, reason} ->
            Logger.warning(
              "GoodAnalytics: pgflow failed, falling back to direct SQL: #{inspect(reason)}"
            )

            create_partitions_direct()
        end

      true ->
        create_partitions_direct()
    end
  end

  @typedoc """
  Per-month outcome from `process_partitions/0`. `:ok` means the partition
  already existed or was created cleanly. `:recovered` means the partition
  was created after draining offending rows from `ga_events_default`.
  `:error` means the operation failed and the partition was not created.
  """
  @type partition_result :: %{
          required(:partition_name) => String.t(),
          required(:month_start) => Date.t(),
          required(:status) => :ok | :recovered | :error,
          optional(:error) => String.t()
        }

  @doc """
  Returns the configured number of future months pre-created on each tick.
  """
  @spec months_ahead() :: non_neg_integer()
  def months_ahead, do: @months_ahead

  @doc """
  Ensures monthly partitions exist for the current month and the next
  `months_ahead/0` months. Returns one `partition_result/0` map per month
  processed, suitable for pgflow run history or operator dashboards.

  If a `check_violation` is raised while creating one of the upcoming
  months (because traffic landed in `ga_events_default` for that range
  before the partition existed), the offending rows are drained into
  the new monthly child as part of the same call. Broad scans of
  `ga_events_default` for older polluted months are NOT performed here —
  use `mix good_analytics.recover_default` for that.

  Wraps the work in a transaction-scoped Postgres advisory lock so a
  single node performs DDL across a multi-node deploy. If another node
  holds the lock, returns an empty list.
  """
  @spec process_partitions() :: [partition_result()]
  def process_partitions do
    with_advisory_lock(fn ->
      Enum.map(upcoming_months(), &month_result/1)
    end) || []
  end

  @doc """
  Pre-creates the initial set of monthly partitions during installation.

  Called from the migration generated by `mix good_analytics.setup` so
  that current + next-`months_ahead/0` partitions exist before traffic
  arrives. Equivalent to `process_partitions/0`; named separately for
  callsite clarity.
  """
  @spec ensure_initial_partitions() :: [partition_result()]
  def ensure_initial_partitions, do: process_partitions()

  defp month_result(month_start) do
    base = %{partition_name: partition_name(month_start), month_start: month_start}

    case ensure_month_partition(month_start) do
      {:ok, status} -> Map.put(base, :status, status)
      {:error, reason} -> base |> Map.put(:status, :error) |> Map.put(:error, inspect(reason))
    end
  end

  @doc """
  Creates partitions directly via SQL (bypasses pgflow). Returns `:ok` for
  legacy callers; use `process_partitions/0` if you need per-month results.
  """
  @spec create_partitions_direct() :: :ok
  def create_partitions_direct do
    _ = process_partitions()
    :ok
  end

  defp upcoming_months do
    today = Date.utc_today()

    for offset <- 0..@months_ahead do
      Date.new!(today.year, today.month, 1) |> Date.shift(month: offset)
    end
  end

  defp ensure_month_partition(month_start) do
    case Repo.repo().query(create_partition_sql(month_start)) do
      {:ok, _} ->
        {:ok, :ok}

      {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} ->
        recover_polluted_partition(month_start)

      {:error, err} ->
        Logger.warning(
          "Failed to create partition #{partition_name(month_start)}: #{inspect(err)}"
        )

        {:error, err}
    end
  rescue
    e ->
      Logger.warning(
        "Unexpected exception creating partition #{partition_name(month_start)}: #{inspect(e)}"
      )

      {:error, e}
  end

  defp recover_polluted_partition(month_start) do
    schema = GoodAnalytics.schema_name()
    name = partition_name(month_start)
    month_end = Date.shift(month_start, month: 1)
    repo = Repo.repo()

    Logger.info(
      "GoodAnalytics: draining default partition into #{name} (#{month_start}..#{month_end})"
    )

    start_at = DateTime.new!(month_start, ~T[00:00:00], "Etc/UTC")
    end_at = DateTime.new!(month_end, ~T[00:00:00], "Etc/UTC")

    try do
      repo.transaction(fn ->
        # Pin session timezone to UTC for the duration of the transaction so
        # the partition bounds in `create_partition_sql/1` parse identically
        # to the `$1::timestamptz` UTC bounds used by the staging/delete
        # queries below.
        repo.query!("SET LOCAL TIME ZONE 'UTC'")
        repo.query!(~s|LOCK TABLE "#{schema}".ga_events IN ACCESS EXCLUSIVE MODE|)

        repo.query!(
          ~s|
          CREATE TEMP TABLE _ga_partition_drain ON COMMIT DROP AS
            SELECT * FROM "#{schema}".ga_events_default
            WHERE inserted_at >= $1::timestamptz AND inserted_at < $2::timestamptz
        |,
          [start_at, end_at]
        )

        repo.query!(
          ~s|
          DELETE FROM "#{schema}".ga_events_default
          WHERE inserted_at >= $1::timestamptz AND inserted_at < $2::timestamptz
        |,
          [start_at, end_at]
        )

        repo.query!(create_partition_sql(month_start))

        repo.query!(~s|
          INSERT INTO "#{schema}".ga_events SELECT * FROM _ga_partition_drain
        |)
      end)
    rescue
      e ->
        Logger.warning("Failed to drain default into #{name}: #{inspect(e)}")
        {:error, e}
    else
      {:ok, _} ->
        Logger.info("GoodAnalytics: drained default into #{name}")
        {:ok, :recovered}

      {:error, reason} ->
        Logger.warning("Failed to drain default into #{name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Acquires a Postgres session-level advisory lock so a single node
  # performs DDL across a multi-node deploy. `repo.checkout/1` pins one
  # connection for the duration of the work, so lock and unlock are
  # guaranteed to hit the same backend — no risk of session-level lock
  # leaks across pool-returned connections.
  #
  # We can't use `pg_try_advisory_xact_lock` here because the work
  # callback (notably `recover_polluted_partition/1`) runs its own
  # transactional recovery, which would become a savepoint inside an
  # already-failed outer transaction whenever `CREATE TABLE … PARTITION OF`
  # raises `check_violation`.
  #
  # The lock key is namespaced by the configured schema prefix so two
  # GoodAnalytics installs sharing a database do not collide.
  defp with_advisory_lock(fun) do
    repo = Repo.repo()
    key = advisory_lock_key()

    repo.checkout(fn ->
      case repo.query("SELECT pg_try_advisory_lock($1)", [key]) do
        {:ok, %{rows: [[true]]}} ->
          try do
            fun.()
          after
            repo.query("SELECT pg_advisory_unlock($1)", [key])
          end

        _ ->
          Logger.debug("GoodAnalytics: another node holds partition advisory lock; skipping")

          nil
      end
    end)
  end

  @doc """
  Returns the advisory lock key for partition management, namespaced by
  the configured schema prefix.
  """
  @spec advisory_lock_key() :: integer()
  def advisory_lock_key do
    :erlang.phash2({:ga_partitions, GoodAnalytics.schema_name()})
  end

  @doc "Generates the partition table name for a given month."
  def partition_name(%Date{year: year, month: month}) do
    "ga_events_#{year}_#{String.pad_leading(Integer.to_string(month), 2, "0")}"
  end

  @doc """
  Returns the SQL to create a partition if it doesn't exist.

  Bounds are emitted as `TIMESTAMP WITH TIME ZONE` literals with an explicit
  `+00` offset so the partition range is always interpreted in UTC,
  regardless of the session timezone.
  """
  def create_partition_sql(month_start) do
    month_end = Date.shift(month_start, month: 1)
    partition_name = partition_name(month_start)
    schema = GoodAnalytics.schema_name()

    """
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema}' AND c.relname = '#{partition_name}'
      ) THEN
        CREATE TABLE "#{schema}"."#{partition_name}"
          PARTITION OF "#{schema}"."ga_events"
          FOR VALUES
            FROM (TIMESTAMP WITH TIME ZONE '#{month_start} 00:00:00+00')
            TO (TIMESTAMP WITH TIME ZONE '#{month_end} 00:00:00+00');
      END IF;
    END $$;
    """
  end

  defp auto_create_partitions? do
    Application.get_env(:good_analytics, :auto_create_partitions, true)
  end

  defp repo_configured? do
    Application.get_env(:good_analytics, :repo) != nil
  end

  defp repo_alive? do
    repo = Application.get_env(:good_analytics, :repo)
    repo && Process.whereis(repo) != nil
  end

  defp pgflow_available? do
    Process.whereis(PgFlow.Supervisor) != nil
  end
end
