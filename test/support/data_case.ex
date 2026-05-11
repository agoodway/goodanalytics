defmodule GoodAnalytics.DataCase do
  @moduledoc """
  Test case for tests requiring database access.

  Sets up SQL Sandbox for transaction isolation per test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias GoodAnalytics.TestRepo
      import Ecto.Query
      import GoodAnalytics.DataCase
      import GoodAnalytics.TestHelpers
    end
  end

  setup tags do
    alias Ecto.Adapters.SQL.Sandbox

    pid = Sandbox.start_owner!(GoodAnalytics.TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc """
  Transforms changeset errors into a map of messages.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
