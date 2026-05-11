defmodule GoodAnalytics.Connectors.Delivery do
  @moduledoc """
  Connector dispatch delivery engine.

  Executes delivery for pending dispatches: loads credentials, builds
  the payload via the connector adapter, delivers it, classifies errors,
  and updates the dispatch record with results.
  """

  alias GoodAnalytics.Connectors.{Config, Dispatches, Settings}
  require Logger

  @telemetry_attempt [:good_analytics, :connector, :delivery, :attempt]
  @telemetry_success [:good_analytics, :connector, :delivery, :success]
  @telemetry_failure [:good_analytics, :connector, :delivery, :failure]

  # Base retry delay in seconds for transient connector delivery failures.
  @default_backoff_base_seconds 5
  # Base retry delay in seconds for rate-limited connector deliveries.
  @rate_limited_backoff_base_seconds 60
  # Maximum connector retry backoff in seconds.
  @max_backoff_seconds 3_600
  # Divisor used to calculate exponential-backoff jitter.
  @backoff_jitter_divisor 5

  @doc """
  Delivers a single dispatch record.

  Returns `{:ok, dispatch}` on success or `{:error, dispatch, reason}` on failure.
  """
  def deliver(dispatch) do
    start_time = System.monotonic_time()
    connector_type_str = dispatch.connector_type

    :telemetry.execute(@telemetry_attempt, %{count: 1}, %{
      connector_type: connector_type_str,
      workspace_id: dispatch.workspace_id,
      attempt: dispatch.attempts + 1
    })

    with {:connector, connector_mod} when not is_nil(connector_mod) <-
           {:connector, Config.get_connector(connector_type_str)},
         connector_type = connector_mod.connector_type(),
         {:enabled, true} <-
           {:enabled, Settings.connector_enabled?(dispatch.workspace_id, connector_type)},
         {:credentials, creds} when is_map(creds) <-
           {:credentials, load_credentials(dispatch.workspace_id, connector_mod)},
         {:payload, {:ok, payload}} <-
           {:payload, connector_mod.build_payload(dispatch, creds)},
         {:size, :ok} <- {:size, validate_size(connector_mod, payload)},
         {:deliver, {:ok, response}} <-
           {:deliver, connector_mod.deliver(payload, creds)} do
      duration = System.monotonic_time() - start_time

      :telemetry.execute(@telemetry_success, %{duration: duration}, %{
        connector_type: connector_type,
        workspace_id: dispatch.workspace_id
      })

      Dispatches.update_delivery(dispatch, %{
        status: "delivered",
        attempts: dispatch.attempts + 1,
        last_attempted_at: DateTime.utc_now(),
        response_status: Map.get(response, :status),
        response_body: Map.get(response, :body)
      })
    else
      {:enabled, false} ->
        Dispatches.update_delivery(dispatch, %{
          status: "skipped_disabled",
          last_attempted_at: DateTime.utc_now()
        })

      {:size, {:error, :payload_too_large}} ->
        handle_permanent_failure(
          dispatch,
          connector_type_str,
          "payload_too_large",
          "Payload exceeds platform size limit"
        )

      {:deliver, {:error, error}} ->
        handle_delivery_error(dispatch, connector_type_str, error)

      {:payload, {:error, reason}} ->
        handle_permanent_failure(
          dispatch,
          connector_type_str,
          "payload_build_error",
          inspect(reason)
        )

      {:connector, nil} ->
        handle_permanent_failure(
          dispatch,
          connector_type_str,
          "unknown_connector",
          "Connector not registered"
        )

      {:credentials, _} ->
        handle_permanent_failure(
          dispatch,
          connector_type_str,
          "credential_load_error",
          "Failed to load credentials"
        )
    end
  end

  defp load_credentials(workspace_id, connector_mod) do
    credential_keys = connector_mod.credential_keys()
    Settings.get_credentials(workspace_id, connector_mod.connector_type(), credential_keys)
  rescue
    _ -> nil
  end

  defp validate_size(connector_mod, payload) do
    if function_exported?(connector_mod, :validate_payload_size, 1) do
      connector_mod.validate_payload_size(payload)
    else
      :ok
    end
  end

  defp handle_delivery_error(dispatch, connector_type, error) do
    connector_mod = Config.get_connector(connector_type)
    error_class = if connector_mod, do: connector_mod.classify_error(error), else: :transient

    :telemetry.execute(@telemetry_failure, %{count: 1}, %{
      connector_type: connector_type,
      workspace_id: dispatch.workspace_id,
      error_class: error_class,
      attempt: dispatch.attempts + 1
    })

    case error_class do
      :permanent ->
        handle_permanent_failure(dispatch, connector_type, "permanent", sanitize_error(error))

      :credential ->
        Dispatches.update_delivery(dispatch, %{
          status: "credential_error",
          attempts: dispatch.attempts + 1,
          last_attempted_at: DateTime.utc_now(),
          error_type: "credential",
          error_message: sanitize_error(error)
        })

      :rate_limited ->
        backoff =
          exponential_backoff(dispatch.attempts + 1, base: @rate_limited_backoff_base_seconds)

        Dispatches.update_delivery(dispatch, %{
          status: "rate_limited",
          attempts: dispatch.attempts + 1,
          last_attempted_at: DateTime.utc_now(),
          next_retry_at: DateTime.add(DateTime.utc_now(), backoff, :second),
          error_type: "rate_limited",
          error_message: sanitize_error(error)
        })

      :transient ->
        backoff = exponential_backoff(dispatch.attempts + 1)

        Dispatches.update_delivery(dispatch, %{
          status: "failed",
          attempts: dispatch.attempts + 1,
          last_attempted_at: DateTime.utc_now(),
          next_retry_at: DateTime.add(DateTime.utc_now(), backoff, :second),
          error_type: "transient",
          error_message: sanitize_error(error)
        })
    end
  end

  defp handle_permanent_failure(dispatch, connector_type, error_type, message) do
    :telemetry.execute(@telemetry_failure, %{count: 1}, %{
      connector_type: connector_type,
      workspace_id: dispatch.workspace_id,
      error_class: :permanent,
      attempt: dispatch.attempts + 1
    })

    Dispatches.update_delivery(dispatch, %{
      status: "permanently_failed",
      attempts: dispatch.attempts + 1,
      last_attempted_at: DateTime.utc_now(),
      error_type: error_type,
      error_message: message
    })
  end

  defp sanitize_error(error) when is_map(error) do
    error
    |> Map.drop([:headers, :request, "headers", "request"])
    |> inspect()
  end

  defp sanitize_error(error), do: inspect(error)

  defp exponential_backoff(attempt, opts \\ []) do
    base = Keyword.get(opts, :base, @default_backoff_base_seconds)
    max_backoff = Keyword.get(opts, :max, @max_backoff_seconds)
    jitter = :rand.uniform(max(div(base, @backoff_jitter_divisor), 1))
    min(base * trunc(:math.pow(2, attempt - 1)) + jitter, max_backoff)
  end
end
