defmodule GoodAnalytics.Api.EventController do
  use Phoenix.Controller, formats: [:json]

  alias GoodAnalytics.Api.Schemas
  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Geo

  alias OpenApiSpex.Operation

  plug(OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true)

  @max_properties_keys 50

  # ── OpenApiSpex Operations ──

  def open_api_operation(:create) do
    %Operation{
      tags: ["Events"],
      summary: "Record a single event",
      description:
        "Record a server-side event for a visitor identified by visitor_id or person_external_id.",
      operationId: "createEvent",
      requestBody:
        Operation.request_body("Event parameters", "application/json", Schemas.EventParams,
          required: true
        ),
      responses: %{
        200 =>
          Operation.response("Idempotent duplicate", "application/json", Schemas.EventResponse),
        201 => Operation.response("Event recorded", "application/json", Schemas.EventResponse),
        404 => Operation.response("Visitor not found", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:batch) do
    %Operation{
      tags: ["Events"],
      summary: "Record multiple events",
      description: "Record up to 100 events in a single request. Returns per-event results.",
      operationId: "batchEvents",
      requestBody:
        Operation.request_body(
          "Batch event parameters",
          "application/json",
          Schemas.BatchEventParams,
          required: true
        ),
      responses: %{
        201 =>
          Operation.response(
            "All events recorded",
            "application/json",
            Schemas.BatchEventResponse
          ),
        207 =>
          Operation.response("Partial success", "application/json", Schemas.BatchEventResponse),
        422 =>
          Operation.response("Invalid batch envelope", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  # ── Actions ──

  def create(conn, _params) do
    workspace_id = conn.assigns.workspace_id
    body = to_plain_map(conn.body_params)

    with :ok <- validate_properties_count(body),
         {:ok, visitor} <- resolve_visitor(workspace_id, body),
         {:ok, status, event} <- maybe_idempotent_record(workspace_id, visitor, body) do
      Geo.enqueue_enrichment(visitor.id, conn.remote_ip)

      conn
      |> put_status(status)
      |> json(%{event_id: event.id})
    else
      {:error, status, message} ->
        conn |> put_status(status) |> json(%{error: message})
    end
  end

  def batch(conn, _params) do
    workspace_id = conn.assigns.workspace_id
    %{events: events} = to_plain_map(conn.body_params)

    remote_ip = conn.remote_ip

    {results, visitor_ids} =
      events
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {event_params, index}, acc ->
        case process_single_event(workspace_id, event_params) do
          {:ok, _status, event, visitor_id} ->
            {%{index: index, status: "ok", event_id: event.id}, MapSet.put(acc, visitor_id)}

          {:error, status, message} when status in [404, 422] ->
            {%{index: index, status: "error", error: message}, acc}
        end
      end)

    Enum.each(visitor_ids, &Geo.enqueue_enrichment(&1, remote_ip))

    all_ok? = Enum.all?(results, &(&1.status == "ok"))
    status = if all_ok?, do: 201, else: 207

    conn
    |> put_status(status)
    |> json(%{results: results})
  end

  # ── Helpers ──

  defp process_single_event(workspace_id, params) do
    params = to_plain_map(params)

    with :ok <- validate_properties_count(params),
         {:ok, visitor} <- resolve_visitor(workspace_id, params),
         {:ok, status, event} <- maybe_idempotent_record(workspace_id, visitor, params) do
      {:ok, status, event, visitor.id}
    end
  end

  defp resolve_visitor(workspace_id, %{visitor_id: visitor_id}) when is_binary(visitor_id) do
    case Visitors.get_visitor(visitor_id) do
      nil ->
        {:error, 404, "Visitor not found"}

      %{workspace_id: ^workspace_id} = visitor ->
        {:ok, visitor}

      _wrong_workspace ->
        {:error, 404, "Visitor not found"}
    end
  end

  defp resolve_visitor(workspace_id, %{person_external_id: external_id})
       when is_binary(external_id) do
    case Visitors.get_by_external_id(workspace_id, external_id) do
      nil -> {:error, 404, "Visitor not found"}
      visitor -> {:ok, visitor}
    end
  end

  defp resolve_visitor(_workspace_id, _params) do
    {:error, 422, "Either visitor_id or person_external_id is required"}
  end

  defp maybe_idempotent_record(workspace_id, visitor, params) do
    idempotency_key = Map.get(params, :idempotency_key)

    if idempotency_key do
      case Events.get_by_idempotency_key(workspace_id, idempotency_key) do
        nil -> do_record(visitor, params, idempotency_key)
        existing -> {:ok, 200, existing}
      end
    else
      do_record(visitor, params, nil)
    end
  end

  defp do_record(visitor, params, idempotency_key) do
    event_type = Map.fetch!(params, :event_type)

    properties =
      (Map.get(params, :properties) || %{})
      |> then(fn props ->
        if idempotency_key, do: Map.put(props, "_idempotency_key", idempotency_key), else: props
      end)

    attrs = %{
      event_name: Map.get(params, :event_name),
      amount_cents: Map.get(params, :amount_cents),
      currency: Map.get(params, :currency),
      url: Map.get(params, :url),
      referrer: Map.get(params, :referrer),
      properties: properties
    }

    case Recorder.record(visitor, event_type, attrs) do
      {:ok, event} -> {:ok, 201, event}
      {:error, _changeset} -> {:error, 422, "Failed to record event"}
    end
  end

  defp to_plain_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_plain_map(%{} = map), do: map

  defp validate_properties_count(%{properties: props}) when is_map(props) do
    if map_size(props) > @max_properties_keys do
      {:error, 422, "Properties cannot exceed #{@max_properties_keys} keys"}
    else
      :ok
    end
  end

  defp validate_properties_count(_), do: :ok
end
