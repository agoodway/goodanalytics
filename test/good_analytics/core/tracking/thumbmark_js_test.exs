defmodule GoodAnalytics.Core.Tracking.ThumbmarkJsTest do
  use ExUnit.Case, async: true

  @thumbmark_path (case :code.priv_dir(:good_analytics) do
                     dir when is_list(dir) or is_binary(dir) ->
                       Path.join([to_string(dir), "static/js", "thumbmark.js"])

                     _ ->
                       Path.expand("priv/static/js/thumbmark.js")
                   end)

  setup_all do
    path =
      cond do
        File.exists?(@thumbmark_path) ->
          @thumbmark_path

        File.exists?(Path.expand("priv/static/js/thumbmark.js")) ->
          Path.expand("priv/static/js/thumbmark.js")

        true ->
          flunk("thumbmark.js not found")
      end

    %{js: File.read!(path)}
  end

  describe "vendor URL resolution" do
    test "derives vendor path from currentScript or thumbmark.js src", %{js: js} do
      refute js =~ "// Use the same base path as the GA script"
      assert js =~ "currentScript"
      assert js =~ "thumbmark"
      assert js =~ "vendor/thumbmark.umd.js"
      assert js =~ ~s[/thumbmark\\.js]
    end

    test "falls back to same-origin /ga/js path", %{js: js} do
      assert js =~ "/ga/js/vendor/thumbmark.umd.js"
    end

    test "reuses existing ThumbmarkJS when present", %{js: js} do
      assert js =~ "window.ThumbmarkJS"
      assert js =~ "getFingerprint"
    end

    test "uses script src to derive cross-origin vendor URL", %{js: js} do
      assert js =~ ~r{replace\(.+vendor/thumbmark\.umd\.js}
    end
  end
end
