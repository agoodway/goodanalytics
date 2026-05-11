defmodule GoodAnalytics.RepoTest do
  use ExUnit.Case

  describe "repo/0" do
    test "raises when no repo is configured" do
      original = Application.get_env(:good_analytics, :repo)
      Application.delete_env(:good_analytics, :repo)

      assert_raise RuntimeError, ~r/requires a repo to be configured/, fn ->
        GoodAnalytics.Repo.repo()
      end

      if original, do: Application.put_env(:good_analytics, :repo, original)
    end

    test "returns configured repo module" do
      original = Application.get_env(:good_analytics, :repo)
      Application.put_env(:good_analytics, :repo, FakeRepo)

      try do
        assert GoodAnalytics.Repo.repo() == FakeRepo
      after
        if original do
          Application.put_env(:good_analytics, :repo, original)
        else
          Application.delete_env(:good_analytics, :repo)
        end
      end
    end
  end
end
