defmodule GoodAnalytics.Connectors.SettingsTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.Settings

  describe "key helpers" do
    test "enabled_key/1 formats correctly" do
      assert Settings.enabled_key(:meta) == "connector.meta.enabled"
      assert Settings.enabled_key(:google) == "connector.google.enabled"
    end

    test "credential_key/2 formats correctly" do
      assert Settings.credential_key(:meta, "access_token") ==
               "connector.meta.credential.access_token"
    end

    test "config_key/2 formats correctly" do
      assert Settings.config_key(:meta, "pixel_id") == "connector.meta.config.pixel_id"
    end
  end

  describe "sensitive_key?/1" do
    test "credential keys are sensitive" do
      assert Settings.sensitive_key?("connector.meta.credential.access_token")
      assert Settings.sensitive_key?("connector.google.credential.refresh_token")
    end

    test "non-credential keys are not sensitive" do
      refute Settings.sensitive_key?("connector.meta.enabled")
      refute Settings.sensitive_key?("connector.meta.config.pixel_id")
      refute Settings.sensitive_key?("tracking.cookie_name")
    end
  end

  describe "module exports" do
    test "exports expected functions" do
      Code.ensure_loaded!(Settings)
      assert function_exported?(Settings, :connector_enabled?, 2)
      assert function_exported?(Settings, :enable_connector, 2)
      assert function_exported?(Settings, :disable_connector, 2)
      assert function_exported?(Settings, :enabled_connectors, 2)
      assert function_exported?(Settings, :put_credential, 4)
      assert function_exported?(Settings, :get_credential, 3)
      assert function_exported?(Settings, :get_credentials, 3)
      assert function_exported?(Settings, :put_config, 4)
      assert function_exported?(Settings, :get_config, 3)
      assert function_exported?(Settings, :get_config, 4)
    end
  end
end
