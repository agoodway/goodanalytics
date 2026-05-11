defmodule GoodAnalytics.Flows.CreatePartitions do
  @moduledoc """
  pgflow Flow that creates monthly partitions for `ga_events`.

  Ensures partitions exist for the current month and 2 months ahead.
  Can be triggered on demand or scheduled via cron.

  ## Usage

  Add this flow to your PgFlow configuration:

      {PgFlow,
       repo: MyApp.Repo,
       flows: [GoodAnalytics.Flows.CreatePartitions]}

  Then generate and run the flow migration:

      mix pgflow.gen.flow GoodAnalytics.Flows.CreatePartitions
      mix ecto.migrate

  To trigger manually:

      PgFlow.start_flow(GoodAnalytics.Flows.CreatePartitions, %{})

  """

  use PgFlow.Flow

  alias GoodAnalytics.PartitionManager

  @flow slug: :ga_create_partitions,
        max_attempts: 3,
        base_delay: 5,
        timeout: 120

  step :create_partitions do
    fn _input, _ctx ->
      results =
        PartitionManager.process_partitions()
        |> Enum.map(&format_result/1)

      %{"partitions" => results, "months_ahead" => PartitionManager.months_ahead()}
    end
  end

  defp format_result(%{partition_name: name, status: :error, error: error}) do
    %{"partition" => name, "status" => "error", "error" => error}
  end

  defp format_result(%{partition_name: name, status: status}) do
    %{"partition" => name, "status" => Atom.to_string(status)}
  end
end
