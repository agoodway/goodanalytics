defmodule GoodAnalytics.Connectors.EventMapping do
  @moduledoc """
  Workspace-scoped mapping from a custom GoodAnalytics event to a connector event.

  `workspace_id`, `event_name`, and `connector_type` form the immutable identity
  of a mapping — they are settable only at creation. Use `update_changeset/2` to
  mutate the delivery configuration (`connector_event_name`, `config`, `enabled`)
  so a mapping can never be reparented into another workspace.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias GoodAnalytics.Connectors.Config

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @schema_prefix Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @built_in_connector_types ~w(meta google linkedin tiktok)

  # Guards against unbounded free-form config and against connector-config values
  # being interpolated into outbound API resource paths (Google/LinkedIn).
  @max_config_keys 20
  @max_config_bytes 4_096
  @max_id_value_length 64
  @id_value_pattern ~r/\A[A-Za-z0-9_-]+\z/
  @connector_event_name_max 50
  @connector_event_name_pattern ~r/\A[A-Za-z0-9 _]+\z/

  # Config keys accepted for the built-in connectors. Keeps secrets and unknown
  # fields out of the persisted config (and the dispatch snapshots derived from it).
  @config_allowlist %{
    "google" => ["conversion_action_id"],
    "linkedin" => ["conversion_rule_id"],
    "meta" => [],
    "tiktok" => []
  }

  schema "ga_connector_event_mappings" do
    field(:workspace_id, Ecto.UUID)
    field(:event_name, :string)
    field(:connector_type, :string)
    field(:connector_event_name, :string)
    field(:config, :map, default: %{})
    field(:enabled, :boolean, default: true)

    timestamps()
  end

  @identity_fields [:workspace_id, :event_name, :connector_type]
  @config_fields [:connector_event_name, :config, :enabled]

  @doc """
  Changeset for creating a custom event connector mapping.

  Casts the immutable identity fields plus the delivery configuration.
  """
  def changeset(mapping, attrs) do
    attrs = normalize_attrs(attrs)

    mapping
    |> cast(attrs, @identity_fields ++ @config_fields)
    |> normalize_event_name()
    |> normalize_connector_type()
    |> normalize_connector_event_name()
    |> validate_required(@identity_fields)
    |> validate_length(:event_name, min: 1)
    |> validate_connector_type()
    |> shared_validations()
  end

  @doc """
  Changeset for updating a mapping's delivery configuration.

  Only `connector_event_name`, `config`, and `enabled` are mutable — the
  identity fields (`workspace_id`, `event_name`, `connector_type`) are frozen so
  a mapping cannot be moved to another workspace or silently retargeted.
  """
  def update_changeset(%__MODULE__{} = mapping, attrs) do
    attrs = normalize_attrs(attrs)

    mapping
    |> cast(attrs, @config_fields)
    |> normalize_connector_event_name()
    |> shared_validations()
  end

  @doc """
  Builds the deterministic mapping snapshot embedded in a dispatch's
  `source_context`. This is the single source of truth for the snapshot shape
  shared by the planner, reconciliation, and the built-in adapters.
  """
  def to_snapshot(%__MODULE__{} = mapping) do
    %{
      "id" => mapping.id,
      "event_type" => "custom",
      "event_name" => mapping.event_name,
      "connector_event_name" => mapping.connector_event_name,
      "config" => mapping.config || %{}
    }
  end

  defp shared_validations(changeset) do
    changeset
    |> validate_mapping_requirements()
    |> validate_connector_event_name_format()
    |> validate_config_size()
    |> validate_config_keys()
    |> unique_constraint(:event_name,
      name: :idx_ga_connector_event_mappings_workspace_event_connector
    )
    |> check_constraint(:event_name,
      name: :chk_ga_connector_event_mappings_event_name_nonblank,
      message: "can't be blank"
    )
    |> check_constraint(:connector_event_name,
      name: :chk_ga_connector_event_mappings_connector_event_name_nonblank,
      message: "can't be blank"
    )
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> normalize_attr(:connector_type)
    |> normalize_attr("connector_type")
  end

  defp normalize_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> Map.put(attrs, key, normalize_connector_type_value(value))
      :error -> attrs
    end
  end

  defp normalize_event_name(changeset) do
    update_change(changeset, :event_name, &trim_string/1)
  end

  defp normalize_connector_type(changeset) do
    update_change(changeset, :connector_type, &normalize_connector_type_value/1)
  end

  defp normalize_connector_type_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.trim()

  defp normalize_connector_type_value(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_connector_type_value(value), do: value

  defp normalize_connector_event_name(changeset) do
    # Coerce a whitespace-only name to nil so optional-field connectors
    # (google/linkedin/generic) don't persist a blank string that would trip the
    # DB non-blank check as a raw Postgrex error. meta/tiktok still fail cleanly
    # via validate_required on the resulting nil.
    update_change(changeset, :connector_event_name, &blank_to_nil/1)
  end

  defp validate_connector_type(changeset) do
    validate_change(changeset, :connector_type, fn :connector_type, connector_type ->
      if connector_type in allowed_connector_types() do
        []
      else
        [connector_type: "is not a registered connector type"]
      end
    end)
  end

  defp allowed_connector_types do
    Config.registered_types()
    |> Enum.map(&to_string/1)
    |> Kernel.++(@built_in_connector_types)
    |> Enum.uniq()
  end

  defp validate_mapping_requirements(changeset) do
    case get_field(changeset, :connector_type) do
      connector_type when connector_type in ["meta", "tiktok"] ->
        validate_required(changeset, [:connector_event_name])

      "google" ->
        validate_config_value(changeset, "conversion_action_id")

      "linkedin" ->
        validate_config_value(changeset, "conversion_rule_id")

      nil ->
        changeset

      _other ->
        validate_generic_mapping(changeset)
    end
  end

  defp validate_config_value(changeset, key) do
    config = get_field(changeset, :config) || %{}

    case Map.get(config, key) do
      value when is_binary(value) ->
        cond do
          String.trim(value) == "" ->
            add_error(changeset, :config, "must include #{key}")

          String.length(value) > @max_id_value_length ->
            add_error(changeset, :config, "#{key} is too long")

          not Regex.match?(@id_value_pattern, value) ->
            add_error(changeset, :config, "#{key} has an invalid format")

          true ->
            changeset
        end

      _ ->
        add_error(changeset, :config, "must include #{key}")
    end
  end

  defp validate_generic_mapping(changeset) do
    connector_event_name = get_field(changeset, :connector_event_name)
    config = get_field(changeset, :config) || %{}

    if present?(connector_event_name) or map_size(config) > 0 do
      changeset
    else
      add_error(changeset, :connector_event_name, "or config is required")
    end
  end

  defp validate_connector_event_name_format(changeset) do
    case get_field(changeset, :connector_event_name) do
      value when is_binary(value) and value != "" ->
        changeset
        |> validate_length(:connector_event_name, max: @connector_event_name_max)
        |> validate_format(:connector_event_name, @connector_event_name_pattern,
          message: "has an invalid format"
        )

      _ ->
        changeset
    end
  end

  defp validate_config_size(changeset) do
    config = get_field(changeset, :config) || %{}

    cond do
      map_size(config) > @max_config_keys ->
        add_error(changeset, :config, "has too many keys")

      config_byte_size(config) > @max_config_bytes ->
        add_error(changeset, :config, "is too large")

      true ->
        changeset
    end
  end

  # Built-in connectors have a fixed set of config keys, so anything else (a
  # stray secret, a typo) is rejected before it can be persisted and snapshotted.
  # Generic/host-registered connectors are not in the allowlist and intentionally
  # accept host-defined config keys — those remain bounded by validate_config_size/1.
  # A `config_keys/0` callback on the connector behaviour would let generic
  # connectors declare their own allowlist; deferred until such a connector exists.
  defp validate_config_keys(changeset) do
    with connector_type when is_binary(connector_type) <- get_field(changeset, :connector_type),
         {:ok, allowed} <- Map.fetch(@config_allowlist, connector_type) do
      config = get_field(changeset, :config) || %{}
      unknown = Map.keys(config) -- allowed

      case unknown do
        [] -> changeset
        keys -> add_error(changeset, :config, "has unsupported keys: #{Enum.join(keys, ", ")}")
      end
    else
      _ -> changeset
    end
  end

  defp config_byte_size(config) do
    case Jason.encode(config) do
      {:ok, encoded} -> byte_size(encoded)
      _ -> @max_config_bytes + 1
    end
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false
end
