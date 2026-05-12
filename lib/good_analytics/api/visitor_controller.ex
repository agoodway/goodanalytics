defmodule GoodAnalytics.Api.VisitorController do
  use Phoenix.Controller, formats: [:json]

  alias GoodAnalytics.Api.Schemas
  alias GoodAnalytics.Core.Visitors

  alias OpenApiSpex.Operation

  plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true

  @max_limit 200

  # ── OpenApiSpex Operations ──

  def open_api_operation(:index) do
    %Operation{
      tags: ["Visitors"],
      summary: "List visitors",
      operationId: "listVisitors",
      parameters: [
        Operation.parameter(:limit, :query, %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 20}, "Page size"),
        Operation.parameter(:offset, :query, %OpenApiSpex.Schema{type: :integer, minimum: 0, default: 0}, "Offset")
      ],
      responses: %{
        200 => Operation.response("Visitors list", "application/json", %OpenApiSpex.Schema{type: :array, items: Schemas.VisitorResponse})
      }
    }
  end

  def open_api_operation(:show) do
    %Operation{
      tags: ["Visitors"],
      summary: "Get a visitor",
      operationId: "getVisitor",
      parameters: [Operation.parameter(:id, :path, :string, "Visitor ID", required: true)],
      responses: %{
        200 => Operation.response("Visitor", "application/json", Schemas.VisitorResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:lookup) do
    %Operation{
      tags: ["Visitors"],
      summary: "Lookup visitor by external ID",
      operationId: "lookupVisitor",
      parameters: [Operation.parameter(:external_id, :path, :string, "External person ID", required: true)],
      responses: %{
        200 => Operation.response("Visitor", "application/json", Schemas.VisitorResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:timeline) do
    %Operation{
      tags: ["Visitors"],
      summary: "Get visitor timeline",
      operationId: "getVisitorTimeline",
      parameters: [Operation.parameter(:id, :path, :string, "Visitor ID", required: true)],
      responses: %{
        200 => Operation.response("Timeline events", "application/json", %OpenApiSpex.Schema{type: :array, items: Schemas.TimelineResponse}),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:attribution) do
    %Operation{
      tags: ["Visitors"],
      summary: "Get visitor attribution",
      operationId: "getVisitorAttribution",
      parameters: [Operation.parameter(:id, :path, :string, "Visitor ID", required: true)],
      responses: %{
        200 => Operation.response("Attribution data", "application/json", Schemas.AttributionResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  # ── Actions ──

  def index(conn, params) do
    workspace_id = conn.assigns.workspace_id
    limit = min(Map.get(params, :limit, 20), @max_limit)
    offset = Map.get(params, :offset, 0)

    visitors = Visitors.list_visitors(workspace_id, limit: limit, offset: offset)
    json(conn, Enum.map(visitors, &serialize_visitor/1))
  end

  def show(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Visitors.get_visitor(workspace_id, id) do
      nil -> conn |> put_status(404) |> json(%{error: "Visitor not found"})
      visitor -> json(conn, serialize_visitor(visitor))
    end
  end

  def lookup(conn, %{external_id: external_id}) do
    workspace_id = conn.assigns.workspace_id

    case Visitors.get_by_external_id(workspace_id, external_id) do
      nil -> conn |> put_status(404) |> json(%{error: "Visitor not found"})
      visitor -> json(conn, serialize_visitor(visitor))
    end
  end

  def timeline(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Visitors.get_visitor(workspace_id, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Visitor not found"})

      _visitor ->
        events = Visitors.timeline(id)
        json(conn, Enum.map(events, &serialize_timeline_event/1))
    end
  end

  def attribution(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Visitors.get_visitor(workspace_id, id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Visitor not found"})

      visitor ->
        json(conn, %{
          attribution_path: visitor.attribution_path || [],
          first_source: visitor.first_source,
          last_source: visitor.last_source,
          first_seen_at: visitor.first_seen_at,
          last_seen_at: visitor.last_seen_at
        })
    end
  end

  # ── Serialization ──

  defp serialize_visitor(visitor) do
    %{
      id: visitor.id,
      workspace_id: visitor.workspace_id,
      status: visitor.status,
      person_external_id: visitor.person_external_id,
      person_email: visitor.person_email,
      person_name: visitor.person_name,
      person_metadata: visitor.person_metadata,
      first_source: visitor.first_source,
      last_source: visitor.last_source,
      first_seen_at: visitor.first_seen_at,
      last_seen_at: visitor.last_seen_at,
      geo: visitor.geo,
      device: visitor.device,
      total_sessions: visitor.total_sessions,
      total_pageviews: visitor.total_pageviews,
      total_events: visitor.total_events,
      ltv_cents: visitor.ltv_cents,
      inserted_at: visitor.inserted_at,
      updated_at: visitor.updated_at
    }
  end

  defp serialize_timeline_event(event) do
    %{
      id: event.id,
      event_type: event.event_type,
      event_name: event.event_name,
      url: event.url,
      referrer: event.referrer,
      source_platform: event.source_platform,
      source_medium: event.source_medium,
      source_campaign: event.source_campaign,
      amount_cents: event.amount_cents,
      currency: event.currency,
      properties: event.properties,
      inserted_at: event.inserted_at
    }
  end
end
