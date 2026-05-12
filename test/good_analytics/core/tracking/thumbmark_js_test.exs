defmodule GoodAnalytics.Core.Tracking.ThumbmarkJsTest do
  use ExUnit.Case, async: true

  @thumbmark_path Path.join([
                    Application.compile_env(:good_analytics, :priv_dir, "priv"),
                    "static/js/thumbmark.js"
                  ])

  setup_all do
    path =
      case File.read(@thumbmark_path) do
        {:ok, content} ->
          content

        {:error, _} ->
          # Fall back to relative path from project root
          File.read!(Path.join(["priv", "static", "js", "thumbmark.js"]))
      end

    %{js: path}
  end

  describe "vendor URL resolution" do
    test "derives vendor path from script src, not hardcoded", %{js: js} do
      # Must NOT contain the old dead-code pattern where scriptPath was
      # computed then immediately overwritten with a hardcoded path
      refute js =~ "// Use the same base path as the GA script"

      # Must contain logic to find the script's own src
      assert js =~ "thumbmark"
      assert js =~ "vendor/thumbmark.umd.js"
    end

    test "falls back to same-origin /ga/js path", %{js: js} do
      assert js =~ "/ga/js/vendor/thumbmark.umd.js"
    end

    test "uses script src to derive cross-origin vendor URL", %{js: js} do
      assert js =~ "scripts[i].src"
      assert js =~ ~r{replace\(.+vendor/thumbmark\.umd\.js}
    end
  end
end
