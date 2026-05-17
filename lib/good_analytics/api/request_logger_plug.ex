defmodule GoodAnalytics.Api.RequestLoggerPlug do
  @moduledoc """
  Plug that records API requests as `api_request` events.

  Add to a host app's API pipeline to automatically track API activity.
  Uses `register_before_send` to invoke callbacks synchronously (while the
  conn is still available), then spawns a fire-and-forget task for identity
  resolution and event recording using only scalar data.

  ## Required options

    * `:paths` - list of path prefixes to match (e.g., `["/api"]`)
    * `:workspace_id` - `(conn -> uuid)` or `{Module, :function}` callback
    * `:identity` - `(conn -> map | :skip)` or `{Module, :function}` callback

  ## Optional options

    * `:path` - `(conn -> binary)` callback to redact the recorded path
    * `:properties` - `(conn -> map)` callback to merge extra properties
    * `:task_supervisor` - supervisor name (default: `GoodAnalytics.TaskSupervisor`)
  """

  @behaviour Plug

  require Logger

  alias GoodAnalytics.Core.{Events.Recorder, IdentityResolver}

  @required_opts [:paths, :workspace_id, :identity]
  @max_url_length 2083
  @max_properties 50

  @impl true
  def init(opts) do
    for key <- @required_opts do
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "#{inspect(__MODULE__)} requires the #{inspect(key)} option"
      end
    end

    %{
      paths: Keyword.fetch!(opts, :paths),
      workspace_id: Keyword.fetch!(opts, :workspace_id),
      identity: Keyword.fetch!(opts, :identity),
      path: Keyword.get(opts, :path),
      properties: Keyword.get(opts, :properties),
      task_supervisor: Keyword.get(opts, :task_supervisor, GoodAnalytics.TaskSupervisor)
    }
  end

  @impl true
  def call(conn, opts) do
    if path_matches?(conn.request_path, opts.paths) do
      method = conn.method
      request_path = conn.request_path

      Plug.Conn.register_before_send(conn, fn conn ->
        try do
          status = conn.status

          callback_results = %{
            workspace_id: invoke_workspace_id(conn, opts.workspace_id),
            identity: invoke_identity(conn, opts.identity),
            path: resolve_path(conn, request_path, opts.path),
            properties: resolve_properties(conn, opts.properties)
          }

          spawn_recording_task(method, request_path, status, callback_results, opts)
        rescue
          error ->
            Logger.error(
              "RequestLoggerPlug: callback error in before_send: #{Exception.message(error)}"
            )
        end

        conn
      end)
    else
      conn
    end
  end

  defp path_matches?(request_path, prefixes) do
    Enum.any?(prefixes, fn prefix ->
      request_path == prefix or String.starts_with?(request_path, prefix <> "/")
    end)
  end

  defp spawn_recording_task(method, request_path, status, callback_results, opts) do
    case Task.Supervisor.start_child(opts.task_supervisor, fn ->
           record_event(method, request_path, status, callback_results)
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "RequestLoggerPlug: failed to start recording task: #{inspect(reason, limit: 3)}"
        )
    end
  catch
    :exit, reason ->
      Logger.error(
        "RequestLoggerPlug: failed to start recording task: #{inspect(reason, limit: 3)}"
      )
  end

  defp record_event(method, request_path, status, callback_results) do
    with {:ok, workspace_id} <- callback_results.workspace_id,
         {:ok, identity_signals} <- callback_results.identity,
         {:ok, recorded_path} <- callback_results.path,
         {:ok, extra_props} <- callback_results.properties do
      resolved_signals = if identity_signals == :skip, do: %{}, else: identity_signals
      recorded_path = sanitize_path(recorded_path)
      event_name = "#{method} #{recorded_path}"
      url = build_url(request_path, recorded_path)

      base_props = %{
        "method" => method,
        "path" => recorded_path,
        "status" => status
      }

      sanitized_extra_props =
        sanitize_properties(extra_props, @max_properties - map_size(base_props))

      properties = Map.merge(sanitized_extra_props, base_props)

      case IdentityResolver.resolve(resolved_signals, workspace_id: workspace_id) do
        {:ok, visitor} ->
          case Recorder.record(visitor, "api_request", %{
                 event_name: event_name,
                 url: url,
                 properties: properties
               }) do
            {:ok, _event} ->
              :ok

            {:error, changeset} ->
              Logger.error(
                "RequestLoggerPlug: failed to record event: #{inspect(changeset.errors, limit: 3)}"
              )
          end

        {:error, reason} ->
          Logger.error(
            "RequestLoggerPlug: identity resolution failed: #{inspect(reason, limit: 3)}"
          )
      end
    else
      {:error, callback_name} ->
        Logger.error(
          "RequestLoggerPlug: aborting record due to #{callback_name} callback failure"
        )
    end
  rescue
    error ->
      Logger.error(
        "RequestLoggerPlug: unexpected error in recording task: #{Exception.message(error)}"
      )
  end

  defp sanitize_path(path) do
    path
    |> String.replace(~r/[\x00-\x1f\x7f]/, "")
    |> String.slice(0, @max_url_length)
  end

  defp build_url(request_path, recorded_path) do
    if recorded_path == request_path do
      request_path
    else
      recorded_path
    end
  end

  defp sanitize_properties(props, limit) do
    props
    |> Enum.filter(fn {k, v} ->
      is_binary(k) and (is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v))
    end)
    |> Enum.take(max(limit, 0))
    |> Map.new()
  end

  defp invoke_workspace_id(conn, callback) do
    case invoke_callback(conn, callback) do
      result when is_binary(result) ->
        case Ecto.UUID.cast(result) do
          {:ok, uuid} ->
            {:ok, uuid}

          :error ->
            Logger.error("RequestLoggerPlug: workspace_id callback returned invalid UUID")
            {:error, :workspace_id}
        end

      _other ->
        Logger.error("RequestLoggerPlug: workspace_id callback returned non-binary value")
        {:error, :workspace_id}
    end
  end

  defp invoke_identity(conn, callback) do
    case invoke_callback(conn, callback) do
      :skip ->
        {:ok, :skip}

      result when is_map(result) ->
        {:ok, result}

      _other ->
        Logger.error("RequestLoggerPlug: identity callback returned invalid value")
        {:error, :identity}
    end
  end

  defp resolve_path(_conn, default_path, nil), do: {:ok, default_path}

  defp resolve_path(conn, _default_path, callback) do
    case invoke_callback(conn, callback) do
      result when is_binary(result) ->
        {:ok, result}

      _other ->
        Logger.error("RequestLoggerPlug: path callback returned invalid value")
        {:error, :path}
    end
  end

  defp resolve_properties(_conn, nil), do: {:ok, %{}}

  defp resolve_properties(conn, callback) do
    case invoke_callback(conn, callback) do
      result when is_map(result) ->
        {:ok, result}

      _other ->
        Logger.error("RequestLoggerPlug: properties callback returned invalid value")
        {:error, :properties}
    end
  end

  defp invoke_callback(conn, {mod, fun}) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [conn])
  end

  defp invoke_callback(conn, fun) when is_function(fun, 1) do
    fun.(conn)
  end
end
