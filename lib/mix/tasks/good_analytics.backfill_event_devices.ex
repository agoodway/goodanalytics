defmodule Mix.Tasks.GoodAnalytics.BackfillEventDevices do
  @moduledoc """
  Local convenience wrapper for the temporary event device backfill.

  Production/runtime callers should invoke
  `GoodAnalytics.Core.Events.DeviceBackfill.run/1` from compiled application
  code, a release, or a remote console. Mix is local-only and is not required by
  the runtime backfill API.

  This task is temporary maintenance code intended to be removed in a later
  cleanup after deployed environments have run the event device backfill.

      mix good_analytics.backfill_event_devices
      mix good_analytics.backfill_event_devices --batch-size 1000
  """

  use Mix.Task

  alias GoodAnalytics.Core.Events.DeviceBackfill

  @shortdoc "Backfills ga_events device columns from stored user agents"

  @impl Mix.Task
  def run(args) do
    opts = parse_args(args)

    Mix.Task.run("app.start")

    {:ok, total_updated} = DeviceBackfill.run(opts)

    Mix.shell().info("Backfilled device columns for #{total_updated} ga_events rows")
  end

  defp parse_args(args) do
    {opts, _argv, invalid} =
      OptionParser.parse(args,
        strict: [batch_size: :integer],
        aliases: [b: :batch_size]
      )

    case invalid do
      [] -> opts
      [{flag, _value} | _rest] -> Mix.raise("Invalid option: #{flag}")
    end
  end
end
