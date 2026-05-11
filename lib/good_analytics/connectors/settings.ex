defmodule GoodAnalytics.Connectors.Settings do
  @moduledoc """
  Connector setting keys and configuration helpers.

  Provides per-workspace connector enablement and encrypted credential
  storage through the existing `GoodAnalytics.Settings` system.

  ## Setting Key Conventions

  Connector settings use a dotted key namespace:

      connector.<type>.enabled    — boolean, whether the connector is active
      connector.<type>.credential.<name> — encrypted credential value
      connector.<type>.config.<name>     — non-sensitive connector config

  ## Encryption

  Credential settings are stored encrypted via `Cloak.Ecto`. The host app
  must configure a Cloak vault and set it in the GoodAnalytics config:

      config :good_analytics, :cloak_vault, MyApp.Vault

  """

  alias GoodAnalytics.Settings

  @sensitive_pattern ~r/\.credential\./

  # ── Enablement ──

  @doc "Returns `true` if the given connector type is enabled for the workspace."
  def connector_enabled?(workspace_id, connector_type) do
    Settings.get(workspace_id, enabled_key(connector_type), false) == true
  end

  @doc "Enables a connector for a workspace."
  def enable_connector(workspace_id, connector_type) do
    Settings.put(workspace_id, enabled_key(connector_type), true)
  end

  @doc "Disables a connector for a workspace."
  def disable_connector(workspace_id, connector_type) do
    Settings.put(workspace_id, enabled_key(connector_type), false)
  end

  @doc "Returns a list of enabled connector types for a workspace."
  def enabled_connectors(workspace_id, registered_types) do
    Enum.filter(registered_types, &connector_enabled?(workspace_id, &1))
  end

  # ── Credentials ──

  @doc """
  Stores an encrypted credential for a connector.

  The value is encrypted at rest using the configured Cloak vault.
  Raises if no vault is configured.
  """
  def put_credential(workspace_id, connector_type, credential_name, value) do
    ensure_vault_configured!()
    encrypted = encrypt(value)
    Settings.put(workspace_id, credential_key(connector_type, credential_name), encrypted)
  end

  @doc """
  Retrieves and decrypts a credential for a connector.

  Returns `nil` if the credential is not set.
  """
  def get_credential(workspace_id, connector_type, credential_name) do
    case Settings.get(workspace_id, credential_key(connector_type, credential_name)) do
      nil -> nil
      encrypted -> decrypt(encrypted)
    end
  end

  @doc "Returns all credentials for a connector as a map of name => decrypted value."
  def get_credentials(workspace_id, connector_type, credential_names) do
    Map.new(credential_names, fn name ->
      {name, get_credential(workspace_id, connector_type, name)}
    end)
  end

  # ── Config (non-sensitive) ──

  @doc "Stores a non-sensitive config value for a connector."
  def put_config(workspace_id, connector_type, config_name, value) do
    Settings.put(workspace_id, config_key(connector_type, config_name), value)
  end

  @doc "Retrieves a non-sensitive config value for a connector."
  def get_config(workspace_id, connector_type, config_name, default \\ nil) do
    Settings.get(workspace_id, config_key(connector_type, config_name), default)
  end

  # ── Key Helpers ──

  @doc "Returns the setting key for connector enablement."
  def enabled_key(connector_type), do: "connector.#{connector_type}.enabled"

  @doc "Returns the setting key for a connector credential."
  def credential_key(connector_type, name), do: "connector.#{connector_type}.credential.#{name}"

  @doc "Returns the setting key for a connector config value."
  def config_key(connector_type, name), do: "connector.#{connector_type}.config.#{name}"

  @doc "Returns `true` if the given setting key is a sensitive credential key."
  def sensitive_key?(key), do: Regex.match?(@sensitive_pattern, key)

  # ── Encryption Helpers ──

  defp encrypt(value) do
    vault = vault()

    case vault.encrypt(to_string(value)) do
      {:ok, encrypted} -> Base.encode64(encrypted)
      {:error, reason} -> raise "Cloak encryption failed: #{inspect(reason)}"
    end
  end

  defp decrypt(encoded) do
    vault = vault()

    case vault.decrypt(Base.decode64!(encoded)) do
      {:ok, decrypted} -> decrypted
      {:error, reason} -> raise "Cloak decryption failed: #{inspect(reason)}"
    end
  end

  defp vault do
    Application.get_env(:good_analytics, :cloak_vault) ||
      raise """
      No Cloak vault configured for GoodAnalytics connector credentials.

      Add to your config:

          config :good_analytics, :cloak_vault, MyApp.Vault

      See https://hexdocs.pm/cloak/readme.html for Cloak vault setup.
      """
  end

  defp ensure_vault_configured! do
    vault()
    :ok
  end
end
