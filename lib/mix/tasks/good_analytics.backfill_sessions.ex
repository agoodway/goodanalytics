defmodule Mix.Tasks.GoodAnalytics.BackfillSessions do
  @moduledoc """
  Local convenience wrapper for the temporary session backfill.

  Production/runtime callers should invoke
  `GoodAnalytics.Core.Sessions.Backfill.run/1` from compiled application code,
  a release, or a remote console. Mix is local-only and is not required by the
  runtime backfill API.

  This task is temporary maintenance code intended to be removed in a later
  cleanup after deployed environments have run the session backfill.

      mix good_analytics.backfill_sessions
      mix good_analytics.backfill_sessions --batch-size 1000
      mix good_analytics.backfill_sessions --since 2026-01-01
  """

  use Mix.Task

  alias GoodAnalytics.Core.Sessions.Backfill

  @shortdoc "Backfills ga_sessions from historical ga_events"

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)

    Mix.Task.run("app.start")

    {:ok, summary} = Backfill.run(opts)

    Mix.shell().info(
      "SessionBackfill complete: #{summary.events} events, #{summary.sessions} sessions"
    )
  end

  defp parse_args(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [batch_size: :integer, since: :string],
        aliases: [b: :batch_size]
      )

    case invalid do
      [] -> opts |> Keyword.take([:batch_size]) |> maybe_put_since(opts[:since])
      [{flag, _value} | _rest] -> Mix.raise("Invalid option: #{flag}")
    end
  end

  defp maybe_put_since(opts, nil), do: opts

  defp maybe_put_since(opts, date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} ->
        Keyword.put(opts, :since, DateTime.new!(date, ~T[00:00:00], "Etc/UTC"))

      {:error, _reason} ->
        Mix.raise("--since must be an ISO date, e.g. 2026-01-01")
    end
  end
end
