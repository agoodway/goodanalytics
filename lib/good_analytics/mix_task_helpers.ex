defmodule GoodAnalytics.MixTaskHelpers do
  @moduledoc false

  # Shared helpers for GoodAnalytics Mix tasks.

  @doc "Returns the Ecto repo configured for the host app, or raises."
  def get_repo do
    app = Mix.Project.config()[:app]

    case Application.get_env(app, :ecto_repos, []) do
      [repo | _] -> repo
      [] -> Mix.raise("No Ecto repos configured. Add :ecto_repos to your app config.")
    end
  end

  @doc "Returns the migrations directory path for the given repo."
  def migrations_dir(repo) do
    repo_underscored =
      repo
      |> Module.split()
      |> List.last()
      |> Macro.underscore()

    Path.join(["priv", repo_underscored, "migrations"])
  end

  @doc "Ensures the migrations directory for the given repo exists."
  def ensure_migrations_dir(repo) do
    dir = migrations_dir(repo)
    File.mkdir_p!(dir)
  end

  @doc "Returns a UTC timestamp string suitable for Ecto migration filenames."
  def timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(i) when i < 10, do: "0#{i}"
  defp pad(i), do: "#{i}"
end
