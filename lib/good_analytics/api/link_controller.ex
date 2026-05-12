defmodule GoodAnalytics.Api.LinkController do
  use Phoenix.Controller, formats: [:json]

  alias GoodAnalytics.Api.Schemas
  alias GoodAnalytics.Core.Links

  alias OpenApiSpex.Operation

  plug(OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true)

  @max_limit 200

  # ── OpenApiSpex Operations ──

  def open_api_operation(:create) do
    %Operation{
      tags: ["Links"],
      summary: "Create a link",
      operationId: "createLink",
      requestBody:
        Operation.request_body("Link parameters", "application/json", Schemas.LinkParams,
          required: true
        ),
      responses: %{
        201 => Operation.response("Link created", "application/json", Schemas.LinkResponse),
        409 => Operation.response("Conflict", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:index) do
    %Operation{
      tags: ["Links"],
      summary: "List links",
      operationId: "listLinks",
      parameters: [
        Operation.parameter(
          :limit,
          :query,
          %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
          "Page size"
        ),
        Operation.parameter(
          :offset,
          :query,
          %OpenApiSpex.Schema{type: :integer, minimum: 0, default: 0},
          "Offset"
        )
      ],
      responses: %{
        200 =>
          Operation.response("Links list", "application/json", %OpenApiSpex.Schema{
            type: :array,
            items: Schemas.LinkResponse
          })
      }
    }
  end

  def open_api_operation(:show) do
    %Operation{
      tags: ["Links"],
      summary: "Get a link",
      operationId: "getLink",
      parameters: [Operation.parameter(:id, :path, :string, "Link ID", required: true)],
      responses: %{
        200 => Operation.response("Link", "application/json", Schemas.LinkResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:update) do
    %Operation{
      tags: ["Links"],
      summary: "Update a link",
      operationId: "updateLink",
      parameters: [Operation.parameter(:id, :path, :string, "Link ID", required: true)],
      requestBody:
        Operation.request_body(
          "Link attributes to update",
          "application/json",
          Schemas.LinkUpdateParams
        ),
      responses: %{
        200 => Operation.response("Updated link", "application/json", Schemas.LinkResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:delete) do
    %Operation{
      tags: ["Links"],
      summary: "Archive a link",
      operationId: "archiveLink",
      parameters: [Operation.parameter(:id, :path, :string, "Link ID", required: true)],
      responses: %{
        204 => %OpenApiSpex.Response{description: "No content"},
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:stats) do
    %Operation{
      tags: ["Links"],
      summary: "Get link stats",
      operationId: "getLinkStats",
      parameters: [Operation.parameter(:link_id, :path, :string, "Link ID", required: true)],
      responses: %{
        200 => Operation.response("Link stats", "application/json", Schemas.LinkStatsResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:clicks) do
    %Operation{
      tags: ["Links"],
      summary: "Get link clicks",
      operationId: "getLinkClicks",
      parameters: [
        Operation.parameter(:link_id, :path, :string, "Link ID", required: true),
        Operation.parameter(
          :limit,
          :query,
          %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 200, default: 50},
          "Page size"
        ),
        Operation.parameter(
          :offset,
          :query,
          %OpenApiSpex.Schema{type: :integer, minimum: 0, default: 0},
          "Offset"
        )
      ],
      responses: %{
        200 =>
          Operation.response("Click events", "application/json", %OpenApiSpex.Schema{
            type: :array,
            items: Schemas.ClickResponse
          }),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  # ── Actions ──

  def create(conn, _params) do
    workspace_id = conn.assigns.workspace_id
    attrs = conn.body_params |> to_plain_map() |> Map.put(:workspace_id, workspace_id)

    case Links.create_link(attrs) do
      {:ok, link} ->
        conn |> put_status(201) |> json(serialize_link(link))

      {:error, %Ecto.Changeset{errors: errors}} ->
        if has_unique_constraint_error?(errors) do
          conn |> put_status(409) |> json(%{error: "A link with this domain/key already exists"})
        else
          conn
          |> put_status(422)
          |> json(%{error: "Validation failed", errors: format_errors(errors)})
        end
    end
  end

  def index(conn, params) do
    workspace_id = conn.assigns.workspace_id
    limit = min(Map.get(params, :limit, 50), @max_limit)
    offset = Map.get(params, :offset, 0)

    links = Links.list_links(workspace_id, limit: limit, offset: offset)
    json(conn, Enum.map(links, &serialize_link/1))
  end

  def show(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Links.get_link(workspace_id, id) do
      nil -> conn |> put_status(404) |> json(%{error: "Link not found"})
      link -> json(conn, serialize_link(link))
    end
  end

  def update(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    attrs =
      conn.body_params |> to_plain_map() |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case Links.update_link(workspace_id, id, attrs) do
      {:ok, link} ->
        json(conn, serialize_link(link))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Link not found"})

      {:error, %Ecto.Changeset{errors: errors}} ->
        conn
        |> put_status(422)
        |> json(%{error: "Validation failed", errors: format_errors(errors)})
    end
  end

  def delete(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Links.archive_link(workspace_id, id) do
      {:ok, _link} -> send_resp(conn, 204, "")
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Link not found"})
    end
  end

  def stats(conn, %{link_id: link_id}) do
    workspace_id = conn.assigns.workspace_id

    case Links.get_link(workspace_id, link_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "Link not found"})

      link ->
        json(conn, %{
          total_clicks: link.total_clicks,
          unique_clicks: link.unique_clicks,
          total_leads: link.total_leads,
          total_sales: link.total_sales,
          total_revenue_cents: link.total_revenue_cents
        })
    end
  end

  def clicks(conn, %{link_id: link_id} = params) do
    workspace_id = conn.assigns.workspace_id
    limit = min(Map.get(params, :limit, 50), @max_limit)
    offset = Map.get(params, :offset, 0)

    case Links.link_clicks(workspace_id, link_id, limit: limit, offset: offset) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Link not found"})

      clicks ->
        json(conn, Enum.map(clicks, &serialize_click/1))
    end
  end

  # ── Serialization ──

  defp serialize_link(link) do
    %{
      id: link.id,
      domain: link.domain,
      key: link.key,
      url: link.url,
      link_type: link.link_type,
      utm_source: link.utm_source,
      utm_medium: link.utm_medium,
      utm_campaign: link.utm_campaign,
      utm_content: link.utm_content,
      utm_term: link.utm_term,
      expires_at: link.expires_at,
      ios_url: link.ios_url,
      android_url: link.android_url,
      geo_targeting: link.geo_targeting,
      og_title: link.og_title,
      og_description: link.og_description,
      og_image: link.og_image,
      total_clicks: link.total_clicks,
      unique_clicks: link.unique_clicks,
      total_leads: link.total_leads,
      total_sales: link.total_sales,
      total_revenue_cents: link.total_revenue_cents,
      tags: link.tags,
      external_id: link.external_id,
      metadata: link.metadata,
      inserted_at: link.inserted_at,
      updated_at: link.updated_at
    }
  end

  defp serialize_click(event) do
    %{
      id: event.id,
      visitor_id: event.visitor_id,
      url: event.url,
      referrer: event.referrer,
      ip_address: if(event.ip_address, do: to_string(event.ip_address)),
      user_agent: event.user_agent,
      properties: event.properties,
      inserted_at: event.inserted_at
    }
  end

  defp has_unique_constraint_error?(errors) do
    Enum.any?(errors, fn {_field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique end)
  end

  defp to_plain_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_plain_map(%{} = map), do: map

  defp format_errors(errors) do
    Map.new(errors, fn {field, {msg, opts}} ->
      message =
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)

      {field, [message]}
    end)
  end
end
