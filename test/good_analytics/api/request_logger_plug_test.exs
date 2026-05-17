defmodule GoodAnalytics.Api.RequestLoggerPlugTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias GoodAnalytics.Api.RequestLoggerPlug

  defmodule TestCallbacks do
    def workspace_id(_conn), do: "00000000-0000-0000-0000-000000000001"
    def identity(_conn), do: %{person_external_id: "mfa_user"}
  end

  defp base_opts do
    [
      paths: ["/api"],
      workspace_id: fn _conn -> "00000000-0000-0000-0000-000000000001" end,
      identity: fn _conn -> %{person_external_id: "user_123"} end,
      task_supervisor: __MODULE__.TaskSupervisor
    ]
  end

  defp valid_opts(overrides \\ []) do
    Keyword.merge(base_opts(), overrides)
  end

  setup do
    start_supervised!({Task.Supervisor, name: __MODULE__.TaskSupervisor})
    :ok
  end

  describe "init/1" do
    test "accepts valid required options" do
      opts = RequestLoggerPlug.init(valid_opts())
      assert opts.paths == ["/api"]
      assert is_function(opts.workspace_id, 1)
      assert is_function(opts.identity, 1)
    end

    test "raises ArgumentError when paths is missing" do
      assert_raise ArgumentError, ~r/paths/, fn ->
        RequestLoggerPlug.init(Keyword.delete(valid_opts(), :paths))
      end
    end

    test "raises ArgumentError when workspace_id is missing" do
      assert_raise ArgumentError, ~r/workspace_id/, fn ->
        RequestLoggerPlug.init(Keyword.delete(valid_opts(), :workspace_id))
      end
    end

    test "raises ArgumentError when identity is missing" do
      assert_raise ArgumentError, ~r/identity/, fn ->
        RequestLoggerPlug.init(Keyword.delete(valid_opts(), :identity))
      end
    end

    test "accepts optional path callback" do
      opts = RequestLoggerPlug.init(valid_opts(path: fn _conn -> "/redacted" end))
      assert is_function(opts.path, 1)
    end

    test "accepts optional properties callback" do
      opts = RequestLoggerPlug.init(valid_opts(properties: fn _conn -> %{"extra" => true} end))
      assert is_function(opts.properties, 1)
    end

    test "defaults task_supervisor to GoodAnalytics.TaskSupervisor" do
      opts = RequestLoggerPlug.init(Keyword.delete(valid_opts(), :task_supervisor))
      assert opts.task_supervisor == GoodAnalytics.TaskSupervisor
    end
  end

  describe "call/2 path matching" do
    test "registers before_send for matching path" do
      conn = build_conn("GET", "/api/v1/widgets")
      opts = RequestLoggerPlug.init(valid_opts())
      result = RequestLoggerPlug.call(conn, opts)
      assert length(result.private[:before_send]) > length(conn.private[:before_send] || [])
    end

    test "passes through non-matching path unchanged" do
      conn = build_conn("GET", "/dashboard/settings")
      opts = RequestLoggerPlug.init(valid_opts())
      result = RequestLoggerPlug.call(conn, opts)
      assert result.private[:before_send] == conn.private[:before_send]
    end

    test "matches multiple path prefixes" do
      opts = RequestLoggerPlug.init(valid_opts(paths: ["/api", "/internal"]))

      conn1 = build_conn("GET", "/api/v1/widgets")
      result1 = RequestLoggerPlug.call(conn1, opts)
      assert length(result1.private[:before_send]) > length(conn1.private[:before_send] || [])

      conn2 = build_conn("GET", "/internal/health")
      result2 = RequestLoggerPlug.call(conn2, opts)
      assert length(result2.private[:before_send]) > length(conn2.private[:before_send] || [])
    end

    test "does not match partial path prefix (segment boundary)" do
      conn = build_conn("GET", "/apiary/docs")
      opts = RequestLoggerPlug.init(valid_opts())
      result = RequestLoggerPlug.call(conn, opts)
      assert result.private[:before_send] == conn.private[:before_send]
    end

    test "matches exact path prefix" do
      conn = build_conn("GET", "/api")
      opts = RequestLoggerPlug.init(valid_opts())
      result = RequestLoggerPlug.call(conn, opts)
      assert length(result.private[:before_send]) > length(conn.private[:before_send] || [])
    end
  end

  describe "before_send callback — error handling" do
    test "task failure does not affect response" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(workspace_id: fn _conn -> raise "workspace boom" end)
        )

      conn = build_conn("POST", "/api/v1/widgets")

      log =
        capture_log(fn ->
          result_conn =
            conn
            |> RequestLoggerPlug.call(opts)
            |> run_before_send(201)

          assert result_conn.status == 201
          drain_tasks()
        end)

      assert log =~ "RequestLoggerPlug"
    end

    test "TaskSupervisor unavailable is logged gracefully" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(task_supervisor: :nonexistent_supervisor)
        )

      conn = build_conn("POST", "/api/v1/widgets")

      log =
        capture_log(fn ->
          result_conn =
            conn
            |> RequestLoggerPlug.call(opts)
            |> run_before_send(200)

          assert result_conn.status == 200
        end)

      assert log =~ "failed to start recording task"
    end

    test "workspace_id callback returning nil logs error" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(workspace_id: fn _conn -> nil end)
        )

      conn = build_conn("POST", "/api/v1/widgets")

      log =
        capture_log(fn ->
          conn
          |> RequestLoggerPlug.call(opts)
          |> run_before_send(200)

          drain_tasks()
        end)

      assert log =~ "workspace_id callback returned non-binary"
    end

    test "workspace_id callback returning non-UUID string logs error" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(workspace_id: fn _conn -> "not-a-uuid" end)
        )

      conn = build_conn("POST", "/api/v1/widgets")

      log =
        capture_log(fn ->
          conn
          |> RequestLoggerPlug.call(opts)
          |> run_before_send(200)

          drain_tasks()
        end)

      assert log =~ "invalid UUID"
    end

    test "identity callback returning invalid value logs error" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(identity: fn _conn -> "not_a_map" end)
        )

      conn = build_conn("GET", "/api/v1/widgets")

      log =
        capture_log(fn ->
          conn
          |> RequestLoggerPlug.call(opts)
          |> run_before_send(200)

          drain_tasks()
        end)

      assert log =~ "identity callback returned invalid value"
    end

    test "identity callback returning :skip still records with anonymous visitor" do
      test_pid = self()

      opts =
        RequestLoggerPlug.init(
          valid_opts(
            identity: fn _conn ->
              send(test_pid, :identity_called)
              :skip
            end
          )
        )

      conn = build_conn("GET", "/api/v1/widgets")

      conn
      |> RequestLoggerPlug.call(opts)
      |> run_before_send(200)

      drain_tasks()
      assert_received :identity_called
    end

    test "path callback returning non-binary logs error" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(path: fn _conn -> 42 end)
        )

      conn = build_conn("GET", "/api/v1/widgets/secret-123")

      log =
        capture_log(fn ->
          conn
          |> RequestLoggerPlug.call(opts)
          |> run_before_send(200)

          drain_tasks()
        end)

      assert log =~ "path callback returned invalid value"
    end

    test "properties callback returning non-map logs error" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(properties: fn _conn -> "not_a_map" end)
        )

      conn = build_conn("GET", "/api/v1/widgets")

      log =
        capture_log(fn ->
          conn
          |> RequestLoggerPlug.call(opts)
          |> run_before_send(200)

          drain_tasks()
        end)

      assert log =~ "properties callback returned invalid value"
    end

    test "MFA-style callback is invoked" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(
            workspace_id: {TestCallbacks, :workspace_id},
            identity: {TestCallbacks, :identity}
          )
        )

      conn = build_conn("GET", "/api/v1/test")
      result = RequestLoggerPlug.call(conn, opts)
      assert length(result.private[:before_send]) > length(conn.private[:before_send] || [])
    end

    test "optional path callback redacts path in event" do
      opts =
        RequestLoggerPlug.init(
          valid_opts(path: fn _conn -> "/api/v1/widgets/:id" end)
        )

      conn = build_conn("GET", "/api/v1/widgets/secret-123")
      result = RequestLoggerPlug.call(conn, opts)
      assert length(result.private[:before_send]) > length(conn.private[:before_send] || [])
    end
  end

  # -- Helpers --

  defp build_conn(method, path) do
    Plug.Test.conn(method, path)
  end

  defp run_before_send(conn, status) do
    conn = %{conn | status: status}

    (conn.private[:before_send] || [])
    |> Enum.reverse()
    |> Enum.reduce(conn, fn callback, acc ->
      callback.(acc)
    end)
  end

  defp drain_tasks do
    children = Task.Supervisor.children(__MODULE__.TaskSupervisor)

    for pid <- children do
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> :ok
      end
    end
  end
end
