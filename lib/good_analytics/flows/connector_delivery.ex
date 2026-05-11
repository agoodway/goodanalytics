defmodule GoodAnalytics.Flows.ConnectorDelivery do
  @moduledoc """
  pgflow Flow for immediate connector dispatch delivery.

  Started after dispatch records are created. Loads the dispatch,
  delegates to the Delivery engine, and reports results.

  ## Usage

      PgFlow.start_flow(GoodAnalytics.Flows.ConnectorDelivery, %{
        "dispatch_id" => dispatch_id
      })

  """

  use PgFlow.Flow

  alias GoodAnalytics.Connectors.{Delivery, Dispatches}

  @flow slug: :ga_connector_delivery,
        max_attempts: 5,
        base_delay: 10,
        timeout: 60

  step :deliver do
    fn input, _ctx ->
      dispatch_id = Map.fetch!(input, "dispatch_id")

      case Dispatches.get_dispatch(dispatch_id) do
        nil ->
          %{"status" => "not_found", "dispatch_id" => dispatch_id}

        dispatch ->
          case Delivery.deliver(dispatch) do
            {:ok, updated} ->
              %{
                "status" => updated.status,
                "dispatch_id" => dispatch_id,
                "connector_type" => dispatch.connector_type
              }

            {:error, changeset} ->
              raise "Delivery DB update failed for dispatch #{dispatch_id}: #{inspect(changeset.errors)}"
          end
      end
    end
  end
end
