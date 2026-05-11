defmodule GoodAnalytics.Core.Links.SlugTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Core.Links.Slug

  describe "generate/1" do
    test "generates slug of default length" do
      slug = Slug.generate()
      assert String.length(slug) == 7
    end

    test "generates slug of custom length" do
      slug = Slug.generate(12)
      assert String.length(slug) == 12
    end

    test "generates unique slugs" do
      slugs = for _ <- 1..100, do: Slug.generate()
      assert length(Enum.uniq(slugs)) == 100
    end

    test "only contains URL-safe characters" do
      for _ <- 1..100 do
        slug = Slug.generate()
        assert Regex.match?(~r/^[a-zA-Z0-9]+$/, slug)
      end
    end
  end

  describe "valid?/1" do
    test "accepts alphanumeric keys" do
      assert Slug.valid?("promo2026")
    end

    test "accepts hyphens and underscores" do
      assert Slug.valid?("winter-promo")
      assert Slug.valid?("winter_promo")
    end

    test "rejects empty string" do
      refute Slug.valid?("")
    end

    test "rejects special characters" do
      refute Slug.valid?("hello world")
      refute Slug.valid?("hello/world")
      refute Slug.valid?("hello?world")
    end

    test "rejects non-strings" do
      refute Slug.valid?(nil)
      refute Slug.valid?(123)
    end
  end
end
