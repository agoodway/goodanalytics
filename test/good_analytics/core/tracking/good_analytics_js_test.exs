defmodule GoodAnalytics.Core.Tracking.GoodAnalyticsJsTest do
  use ExUnit.Case, async: true

  @js_dir (case :code.priv_dir(:good_analytics) do
             dir when is_list(dir) or is_binary(dir) ->
               Path.join(to_string(dir), "static/js")

             _ ->
               Path.expand("priv/static/js")
           end)

  @js_path Path.join(@js_dir, "good-analytics.js")
  @behavior_test Path.join([@js_dir, "test", "good-analytics.behavior.mjs"])

  setup_all do
    js_path =
      cond do
        File.exists?(@js_path) ->
          @js_path

        File.exists?(Path.expand("priv/static/js/good-analytics.js")) ->
          Path.expand("priv/static/js/good-analytics.js")

        true ->
          flunk("good-analytics.js not found at #{@js_path}")
      end

    behavior =
      cond do
        File.exists?(@behavior_test) ->
          @behavior_test

        File.exists?(Path.expand("priv/static/js/test/good-analytics.behavior.mjs")) ->
          Path.expand("priv/static/js/test/good-analytics.behavior.mjs")

        true ->
          flunk("behavior test not found")
      end

    js = File.read!(js_path)
    %{js: js, behavior: behavior, js_path: js_path}
  end

  describe "source: privacy forget" do
    test "clears fingerprint, client-anon, identity, click dedup, and resets reconcile", %{js: js} do
      assert js =~ "forget: function()"
      assert js =~ "fingerprintStorageKey"
      assert js =~ "clientAnonCookieName"
      assert js =~ "anonStorageKey"
      assert js =~ "_clearClickDedup"
      assert js =~ "_ga_click_"
      assert js =~ "this._fingerprint = null"
      assert js =~ "this._anonymousId = null"
      assert js =~ "this._fingerprintReconcileSent = false"
      assert js =~ "this._suppressFingerprint = true"
    end

    test "does not delete server-owned anon cookie from forget", %{js: js} do
      # Extract forget function body and assert it never deletes anonCookieName
      assert js =~ "Intentionally do not touch anonCookieName"
      forget_start = :binary.match(js, "forget: function()")
      assert forget_start
      {idx, _} = forget_start
      slice = binary_part(js, idx, min(800, byte_size(js) - idx))
      refute slice =~ "deleteCookie(this.config.anonCookieName)"
    end

    test "deleteCookie mirrors Secure and SameSite from setCookie", %{js: js} do
      assert js =~ "deleteCookie: function(n)"
      assert js =~ ~s[path=/;SameSite=Lax]
      assert js =~ "if (this._suppressFingerprint) return;"
    end
  end

  describe "source: module system" do
    test "tracks inited modules and supports late use", %{js: js} do
      assert js =~ "_initedModules"
      assert js =~ "_initModule"
      assert js =~ "if (this._initialized)"
    end
  end

  describe "source: fingerprint self-load" do
    test "distinguishes boolean true from string precomputed fingerprint", %{js: js} do
      assert js =~ "this.config.fingerprint === true"
      assert js =~ ~s[typeof this.config.fingerprint === 'string']
      assert js =~ "_ensureFingerprintModule"
      assert js =~ "_scriptBaseUrl"
      assert js =~ "_isCoreScriptSrc"
      assert js =~ "_isThumbmarkScriptSrc"
    end

    test "applies string fingerprint before pageview; self-load after", %{js: js} do
      # Ordering contract: setFingerprint for string config appears before track('pageview')
      # in init, while fingerprint === true appears after.
      string_idx =
        case :binary.match(js, "typeof this.config.fingerprint === 'string'") do
          {i, _} -> i
          :nomatch -> flunk("string fingerprint branch missing")
        end

      pageview_idx =
        case :binary.match(js, "this.track('pageview')") do
          {i, _} -> i
          :nomatch -> flunk("pageview track missing")
        end

      true_idx =
        case :binary.match(js, "this.config.fingerprint === true") do
          {i, _} -> i
          :nomatch -> flunk("boolean fingerprint branch missing")
        end

      assert string_idx < pageview_idx
      assert pageview_idx < true_idx
    end

    test "uses strict script filename matching and loading recovery", %{js: js} do
      assert js =~ ~s[/good-analytics(?:\\.min)?\\.js]
      assert js =~ ~s[/thumbmark\\.js]
      assert js =~ "_thumbmarkLoading = false"
      assert js =~ "injectFromBase"
    end
  end

  describe "behavior harness" do
    test "node is available" do
      assert System.find_executable("node"),
             "node is required for good-analytics.js behavior tests (install Node.js)"
    end

    test "node syntax check passes", %{js_path: js_path} do
      {output, status} = System.cmd("node", ["--check", js_path], stderr_to_stdout: true)
      assert status == 0, "node --check failed: #{output}"
    end

    test "behavioral suite passes", %{behavior: behavior} do
      assert File.exists?(behavior), "missing behavior test: #{behavior}"

      {output, status} =
        System.cmd("node", ["--test", behavior], stderr_to_stdout: true)

      assert status == 0, "behavior tests failed:\n#{output}"
    end
  end
end
