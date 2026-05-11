defmodule GoodAnalytics.Connectors.Connector do
  @moduledoc """
  Behavior contract for outbound connectors.

  Built-in and third-party connectors implement this behavior to participate
  in the connector registry, dispatch planning, and delivery framework.

  ## Required Callbacks

  - `connector_type/0` — unique atom identifying this connector (e.g., `:meta`, `:google`)
  - `supported_event_types/0` — list of event types this connector handles
  - `required_signals/0` — signal groups needed for dispatch (AND of ORs)
  - `credential_keys/0` — list of credential setting names for this connector
  - `build_payload/2` — builds the outbound API payload from dispatch + source context
  - `deliver/2` — sends the payload to the external platform
  - `classify_error/1` — classifies an error for retry/alerting behavior

  ## Example

      defmodule MyApp.Connectors.Meta do
        @behaviour GoodAnalytics.Connectors.Connector

        @impl true
        def connector_type, do: :meta

        @impl true
        def supported_event_types, do: [:lead, :sale]

        @impl true
        def required_signals, do: [["_fbp", "_fbc", "fbclid"]]

        @impl true
        def credential_keys, do: ["access_token", "pixel_id"]

        @impl true
        def build_payload(dispatch, credentials), do: {:ok, %{...}}

        @impl true
        def deliver(payload, credentials), do: {:ok, %{status: 200}}

        @impl true
        def classify_error(%{status: 429}), do: :rate_limited
        def classify_error(%{status: 401}), do: :credential
        def classify_error(_), do: :transient
      end
  """

  @type connector_type :: atom()
  @type event_type :: atom() | String.t()
  @type signal_group :: [String.t()]
  @type credentials :: map()
  @type payload :: map()
  @type error_class :: :transient | :permanent | :credential | :rate_limited

  @doc "Returns the unique connector type atom."
  @callback connector_type() :: connector_type()

  @doc "Returns the event types this connector supports."
  @callback supported_event_types() :: [event_type()]

  @doc """
  Returns the required signal groups for this connector.

  Each group is a list of signal keys — at least one signal from each
  group must be present for a dispatch to be created (AND of ORs).
  """
  @callback required_signals() :: [signal_group()]

  @doc "Returns the credential key names needed by this connector."
  @callback credential_keys() :: [String.t()]

  @doc """
  Builds the outbound API payload from a dispatch record and credentials.

  Returns `{:ok, payload}` or `{:error, reason}`.
  """
  @callback build_payload(dispatch :: map(), credentials :: credentials()) ::
              {:ok, payload()} | {:error, term()}

  @doc """
  Delivers a payload to the external platform.

  Returns `{:ok, response}` or `{:error, error}`.
  """
  @callback deliver(payload :: payload(), credentials :: credentials()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Classifies an error for retry and alerting behavior.

  - `:transient` — retry with standard backoff
  - `:permanent` — do not retry, mark as permanently failed
  - `:credential` — pause retries for this workspace+connector
  - `:rate_limited` — retry with exponential backoff
  """
  @callback classify_error(error :: term()) :: error_class()

  @doc """
  Optional callback for validating payload size before delivery.

  Returns `:ok` or `{:error, :payload_too_large}`.
  Defaults to `:ok` if not implemented.
  """
  @callback validate_payload_size(payload :: payload()) :: :ok | {:error, :payload_too_large}

  @optional_callbacks [validate_payload_size: 1]
end
