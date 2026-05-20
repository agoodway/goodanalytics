defmodule GoodAnalytics.Api.PartnerController do
  use Phoenix.Controller, formats: [:json]

  alias GoodAnalytics.Api.Schemas
  alias GoodAnalytics.Core.Partners

  alias OpenApiSpex.Operation

  plug(OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true)

  # ── OpenApiSpex Operations ──

  def open_api_operation(:create) do
    %Operation{
      tags: ["Partners"],
      summary: "Create a referral partner",
      operationId: "createPartner",
      requestBody:
        Operation.request_body("Partner attributes", "application/json", Schemas.PartnerParams,
          required: true
        ),
      responses: %{
        201 => Operation.response("Created", "application/json", Schemas.PartnerResponse),
        409 => Operation.response("Conflict", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:index) do
    %Operation{
      tags: ["Partners"],
      summary: "List partners",
      operationId: "listPartners",
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
          Operation.response("Partner list", "application/json", %OpenApiSpex.Schema{
            type: :array,
            items: Schemas.PartnerResponse
          })
      }
    }
  end

  def open_api_operation(:show) do
    %Operation{
      tags: ["Partners"],
      summary: "Get a partner",
      operationId: "getPartner",
      parameters: [
        Operation.parameter(:id, :path, :string, "Partner ID", required: true)
      ],
      responses: %{
        200 => Operation.response("Partner", "application/json", Schemas.PartnerResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:update) do
    %Operation{
      tags: ["Partners"],
      summary: "Update a partner",
      operationId: "updatePartner",
      parameters: [
        Operation.parameter(:id, :path, :string, "Partner ID", required: true)
      ],
      requestBody:
        Operation.request_body(
          "Partner attributes to update",
          "application/json",
          Schemas.PartnerUpdateParams,
          required: true
        ),
      responses: %{
        200 => Operation.response("Updated", "application/json", Schemas.PartnerResponse),
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse),
        422 => Operation.response("Validation error", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  def open_api_operation(:delete) do
    %Operation{
      tags: ["Partners"],
      summary: "Archive a partner",
      operationId: "archivePartner",
      parameters: [
        Operation.parameter(:id, :path, :string, "Partner ID", required: true)
      ],
      responses: %{
        204 => %OpenApiSpex.Response{description: "Archived"},
        404 => Operation.response("Not found", "application/json", Schemas.ErrorResponse)
      }
    }
  end

  # ── Actions ──

  @max_limit 200

  def create(conn, _params) do
    workspace_id = conn.assigns.workspace_id
    attrs = conn.body_params |> to_plain_map() |> Map.put(:workspace_id, workspace_id)

    case Partners.create_partner(attrs) do
      {:ok, partner} ->
        conn |> put_status(201) |> json(serialize_partner(partner))

      {:error, %Ecto.Changeset{errors: errors}} ->
        cond do
          has_constraint_error?(errors, :key) ->
            conn |> put_status(409) |> json(%{error: "A partner with this key already exists"})

          has_constraint_error?(errors, :external_id) ->
            conn
            |> put_status(409)
            |> json(%{error: "A partner with this external_id already exists"})

          true ->
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

    partners = Partners.list_partners(workspace_id, limit: limit, offset: offset)
    json(conn, Enum.map(partners, &serialize_partner/1))
  end

  def show(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Partners.get_partner(workspace_id, id) do
      nil -> conn |> put_status(404) |> json(%{error: "Partner not found"})
      partner -> json(conn, serialize_partner(partner))
    end
  end

  def update(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    attrs =
      conn.body_params |> to_plain_map() |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()

    case Partners.update_partner(workspace_id, id, attrs) do
      {:ok, partner} ->
        json(conn, serialize_partner(partner))

      {:error, :not_found} ->
        conn |> put_status(404) |> json(%{error: "Partner not found"})

      {:error, %Ecto.Changeset{errors: errors}} ->
        conn
        |> put_status(422)
        |> json(%{error: "Validation failed", errors: format_errors(errors)})
    end
  end

  def delete(conn, %{id: id}) do
    workspace_id = conn.assigns.workspace_id

    case Partners.archive_partner(workspace_id, id) do
      {:ok, _partner} -> send_resp(conn, 204, "")
      {:error, :not_found} -> conn |> put_status(404) |> json(%{error: "Partner not found"})
    end
  end

  # ── Serialization ──

  defp serialize_partner(partner) do
    %{
      id: partner.id,
      workspace_id: partner.workspace_id,
      key: partner.key,
      name: partner.name,
      status: partner.status,
      external_id: partner.external_id,
      metadata: partner.metadata,
      archived_at: partner.archived_at,
      inserted_at: partner.inserted_at,
      updated_at: partner.updated_at
    }
  end

  @key_constraint "idx_ga_partners_workspace_key"
  @external_id_constraint "idx_ga_partners_workspace_external_id"

  defp has_constraint_error?(errors, :key) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) == @key_constraint

      _ ->
        false
    end)
  end

  defp has_constraint_error?(errors, :external_id) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) == @external_id_constraint

      _ ->
        false
    end)
  end

  defp format_errors(errors) do
    Map.new(errors, fn {field, {message, _opts}} -> {field, message} end)
  end

  defp to_plain_map(%_{} = struct), do: Map.from_struct(struct)
  defp to_plain_map(%{} = map), do: map
end
