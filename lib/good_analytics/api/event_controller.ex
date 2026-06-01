defmodule GoodAnalytics.Api.EventController do
  use Phoenix.Controller, formats: [:json]

  alias GoodAnalytics.Api.Schemas
  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.IdentityResolver
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
        "Record a server-side event. Visitor resolution priority: visitor_id > person_external_id > ga_id > anonymous_id.",
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

    auth_context = conn.assigns[:auth_context] || %{}

    with :ok <- validate_properties_count(body),
         {:ok, visitor} <- resolve_visitor(workspace_id, body),
         {:ok, status, event} <- maybe_idempotent_record(workspace_id, visitor, body, auth_context) do
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
    auth_context = conn.assigns[:auth_context] || %{}

    remote_ip = conn.remote_ip

    {results, visitor_ids} =
      events
      |> Enum.with_index()
      |> Enum.map_reduce(MapSet.new(), fn {event_params, index}, acc ->
        case process_single_event(workspace_id, event_params, auth_context) do
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

  defp process_single_event(workspace_id, params, auth_context) do
    params = to_plain_map(params)

    with :ok <- validate_properties_count(params),
         {:ok, visitor} <- resolve_visitor(workspace_id, params),
         {:ok, status, event} <- maybe_idempotent_record(workspace_id, visitor, params, auth_context) do
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

  defp resolve_visitor(workspace_id, params) do
    with nil <- try_signals(workspace_id, params) do
      if has_any_identifier?(params) do
        {:error, 404, "Visitor not found"}
      else
        {:error, 422, "One of visitor_id, person_external_id, ga_id, or anonymous_id is required"}
      end
    end
  end

  defp try_signals(workspace_id, params) do
    signals = %{
      ga_id: Map.get(params, :ga_id),
      anonymous_id: Map.get(params, :anonymous_id)
    }

    if signals.ga_id || signals.anonymous_id do
      case IdentityResolver.find_candidates(signals, workspace_id) do
        [visitor | _] -> maybe_identify(visitor, params)
        [] -> nil
      end
    end
  end

  defp maybe_identify(visitor, params) do
    person_attrs =
      params
      |> Map.take([
        :person_external_id,
        :person_email,
        :person_phone,
        :person_name,
        :person_metadata
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if map_size(person_attrs) > 0 do
      case IdentityResolver.identify(visitor, person_attrs) do
        {:ok, visitor} -> {:ok, visitor}
        _other -> {:error, 422, "Invalid identity attributes"}
      end
    else
      {:ok, visitor}
    end
  end

  defp has_any_identifier?(params) do
    Enum.any?([:person_external_id, :ga_id, :anonymous_id], &Map.get(params, &1))
  end

  defp maybe_idempotent_record(workspace_id, visitor, params, auth_context) do
    idempotency_key = Map.get(params, :idempotency_key)

    if idempotency_key do
      case Events.get_by_idempotency_key(workspace_id, idempotency_key) do
        nil -> do_record(visitor, params, idempotency_key, auth_context)
        existing -> {:ok, 200, existing}
      end
    else
      do_record(visitor, params, nil, auth_context)
    end
  end

  defp do_record(visitor, params, idempotency_key, auth_context) do
    event_type = Map.fetch!(params, :event_type)

    properties =
      (Map.get(params, :properties) || %{})
      |> then(fn props ->
        if idempotency_key, do: Map.put(props, "_idempotency_key", idempotency_key), else: props
      end)

    referral_attrs = extract_referral_attrs(params, auth_context)

    attrs =
      %{
        event_name: Map.get(params, :event_name),
        amount_cents: Map.get(params, :amount_cents),
        currency: Map.get(params, :currency),
        url: Map.get(params, :url),
        referrer: Map.get(params, :referrer),
        properties: properties
      }
      |> Map.merge(referral_attrs)

    case Recorder.record(visitor, event_type, attrs) do
      {:ok, event} -> {:ok, 201, event}
      {:error, _changeset} -> {:error, 422, "Failed to record event"}
    end
  end

  # Explicit partner_id is accepted only from secret key auth.
  # Publishable key callers can only derive attribution from visitor state.
  defp extract_referral_attrs(params, auth_context) do
    trusted? = Map.get(auth_context, :key_type) == "secret"

    if trusted? do
      %{}
      |> maybe_put(:partner_id, Map.get(params, :partner_id))
      |> maybe_put(:referral_link_id, Map.get(params, :referral_link_id))
      |> maybe_put(:referral_click_id, Map.get(params, :referral_click_id))
    else
      %{}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
