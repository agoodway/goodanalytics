defmodule GoodAnalytics.Connectors.Signals do
  @moduledoc """
  Shared signal normalization layer for connector identifiers.

  Normalizes connector-relevant identifiers from multiple input sources
  (request cookies, query params, JS-supplied values) into a canonical
  signal map used by the tracking plug, beacon controller, event recorder,
  and connector planner.

  ## Recognized Signals

  | Signal     | Source              | Connector    |
  |------------|---------------------|--------------|
  | `_fbp`     | Cookie / JS         | Meta         |
  | `_fbc`     | Cookie / JS         | Meta         |
  | `fbclid`   | Query param         | Meta         |
  | `gclid`    | Query param         | Google       |
  | `gbraid`   | Query param         | Google       |
  | `wbraid`   | Query param         | Google       |
  | `li_fat_id`| Query param         | LinkedIn     |
  | `ttclid`   | Query param         | TikTok       |
  """

  @click_id_signals ~w(fbclid gclid gbraid wbraid li_fat_id ttclid)
  @browser_signals ~w(_fbp _fbc)
  @all_signals @click_id_signals ++ @browser_signals
  @max_signal_length 512
  # Alphanumeric, dots, dashes, underscores — covers all known platform ID formats
  @signal_value_pattern ~r/\A[a-zA-Z0-9._\-]+\z/

  @doc "Returns the list of all recognized connector signal keys."
  def all_signal_keys, do: @all_signals

  @doc "Returns the list of click ID signal keys (from query params)."
  def click_id_signal_keys, do: @click_id_signals

  @doc "Returns the list of browser signal keys (from cookies/JS)."
  def browser_signal_keys, do: @browser_signals

  @doc """
  Extracts connector signals from a `Plug.Conn`.

  Reads click IDs from query params and browser identifiers from cookies.
  Returns a map with only the signals that are present.
  """
  def extract_from_conn(%Plug.Conn{} = conn) do
    click_ids = extract_click_ids(conn.query_params)
    browser_ids = extract_browser_ids_from_cookies(conn)
    Map.merge(click_ids, browser_ids)
  end

  @doc """
  Extracts connector signals from a beacon/JS payload map.

  The JS client may forward `_fbp`, `_fbc`, and click IDs explicitly.
  Returns a map with only the signals that are present.
  """
  def extract_from_payload(payload) when is_map(payload) do
    collect_signals(@all_signals, payload)
  end

  @doc """
  Merges connector signals from multiple sources.

  Later sources take precedence (JS-supplied values override server-captured).
  Nil/empty values are filtered out.
  """
  def merge(signals_list) when is_list(signals_list) do
    signals_list
    |> Enum.reduce(%{}, fn signals, acc ->
      signals
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
      |> Map.new()
      |> Map.merge(acc, fn _k, new, _old -> new end)
    end)
  end

  @doc """
  Builds a connector source context snapshot from signals, visitor, and event data.

  This context is persisted on the event and used for deterministic
  payload rebuilds during replay.
  """
  def build_source_context(signals, opts \\ []) do
    visitor_id = Keyword.get(opts, :visitor_id)
    source = Keyword.get(opts, :source, %{})
    event_type = Keyword.get(opts, :event_type)
    amount_cents = Keyword.get(opts, :amount_cents)
    currency = Keyword.get(opts, :currency)

    %{
      "signals" => signals,
      "visitor_id" => visitor_id,
      "source" => source,
      "event_type" => event_type,
      "amount_cents" => amount_cents,
      "currency" => currency,
      "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    |> reject_nil_values()
  end

  @doc """
  Checks if a signal map contains the required signals for a connector.

  `required` is a list of signal key lists — at least one signal from each
  inner list must be present (AND of ORs).

  ## Examples

      # Meta requires at least one of _fbp, _fbc, or fbclid
      has_required_signals?(%{"_fbp" => "fb.1..."}, [["_fbp", "_fbc", "fbclid"]])
      #=> true

      # Google requires gclid OR (gbraid | wbraid)
      has_required_signals?(%{"gclid" => "abc"}, [["gclid", "gbraid", "wbraid"]])
      #=> true
  """
  def has_required_signals?(signals, required_groups) when is_map(signals) do
    Enum.all?(required_groups, fn group ->
      Enum.any?(group, &signal_present?(signals, &1))
    end)
  end

  # ── Private ──

  defp extract_click_ids(params) when is_map(params) do
    collect_signals(@click_id_signals, params)
  end

  defp extract_browser_ids_from_cookies(%Plug.Conn{} = conn) do
    collect_signals(@browser_signals, conn.cookies)
  end

  defp collect_signals(keys, source) when is_list(keys) and is_map(source) do
    Enum.reduce(keys, %{}, fn key, acc ->
      put_valid_signal(acc, key, Map.get(source, key))
    end)
  end

  defp put_valid_signal(acc, _key, nil), do: acc
  defp put_valid_signal(acc, _key, ""), do: acc

  defp put_valid_signal(acc, key, value) when is_binary(value) do
    if valid_signal_value?(value), do: Map.put(acc, key, value), else: acc
  end

  defp put_valid_signal(acc, _key, _), do: acc

  defp signal_present?(signals, key) do
    case Map.get(signals, key) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp valid_signal_value?(value) do
    byte_size(value) <= @max_signal_length and Regex.match?(@signal_value_pattern, value)
  end

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end
end
