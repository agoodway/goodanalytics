defmodule GoodAnalytics.Connectors.EventId do
  @moduledoc """
  Derives stable connector event IDs deterministically.

  Each connector dispatch uses a stable `connector_event_id` derived from
  the source event identity and `connector_type`, rather than a random ID.
  This ensures retries and replays remain semantically tied to the same
  conversion event and prepares for future browser/server dedup.

  ## Format

      {connector_type}_{sha256_hex_prefix}

  The hash is computed from `{event_id}:{event_inserted_at_iso8601}:{connector_type}`.

  ## Collision Risk

  Uses a 32-hex-character (128-bit) prefix of the SHA-256 hash. Birthday
  paradox collision probability reaches ~1e-18 at 10 billion events per
  connector type, which is well beyond expected scale. At 100M events the
  probability is negligible (~1e-22). If collision risk becomes a concern
  at extreme scale, increase `@hash_prefix_length` to 64 (full SHA-256).
  """

  @hash_prefix_length 32

  @doc """
  Derives a stable connector event ID from the source event and connector type.

  ## Examples

      iex> derive("evt-uuid", ~U[2026-04-21 12:00:00Z], :meta)
      "meta_a1b2c3d4e5f6g7h8"

  """
  def derive(event_id, event_inserted_at, connector_type) do
    timestamp = DateTime.to_iso8601(event_inserted_at)
    input = "#{event_id}:#{timestamp}:#{connector_type}"

    hash =
      :crypto.hash(:sha256, input)
      |> Base.encode16(case: :lower)
      |> binary_part(0, @hash_prefix_length)

    "#{connector_type}_#{hash}"
  end

  @doc """
  Generates a fresh connector event ID for a replayed dispatch.

  Replays must not reuse the original `connector_event_id`, because replay
  rows need to coexist with the original dispatch record and downstream
  platforms should see the replay as a new delivery attempt.
  """
  def replay(connector_type) do
    "#{connector_type}_replay_#{Uniq.UUID.uuid7()}"
  end
end
