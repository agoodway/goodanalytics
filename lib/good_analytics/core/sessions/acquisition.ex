defmodule GoodAnalytics.Core.Sessions.Acquisition do
  @moduledoc """
  Acquisition-change boundary rule for sessionization.

  A session is split when the normalized acquisition tuple
  `{source_platform, source_medium, source_campaign, click_id}` meaningfully
  differs from the live session and the new event's acquisition is not direct.
  Only acquisition signals are compared; raw referrer changes do not split a
  session.

  When a live session is direct and a later event carries a real acquisition
  signal, the session source is updated in place instead of splitting.
  """

  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Maps

  @acquisition_keys [:source_platform, :source_medium, :source_campaign, :click_id]
  @source_keys [:source_platform, :source_medium]

  @typedoc "Continue the live session, start a new one, or update the live source in place."
  @type decision :: :continue | :new_session | :update_source
  @type acquisition_attrs :: %{
          source_platform: String.t() | nil,
          source_medium: String.t() | nil,
          source_campaign: String.t() | nil,
          click_id: Ecto.UUID.t() | nil
        }

  @doc "True when attrs carry no real acquisition signal."
  @spec direct?(map()) :: boolean()
  def direct?(attrs) do
    attrs
    |> acquisition_tuple(&Maps.get_indifferent/2)
    |> Map.values()
    |> Enum.all?(&is_nil/1)
  end

  @doc """
  Decides how a new event's acquisition attrs affect a live session.
  """
  @spec decision(Session.t(), map()) :: decision()
  def decision(%Session{} = live, attrs) do
    cond do
      direct?(attrs) -> :continue
      live_direct?(live) -> :update_source
      same_acquisition?(live, attrs) -> :continue
      true -> :new_session
    end
  end

  @doc """
  Extracts normalized acquisition attrs for a session and drops all other keys.
  """
  @spec to_session_acquisition(map()) :: acquisition_attrs()
  def to_session_acquisition(attrs) do
    acquisition_tuple(attrs, &Maps.get_indifferent/2)
  end

  defp live_direct?(%Session{} = live) do
    live
    |> acquisition_tuple(&Map.get/2)
    |> Map.values()
    |> Enum.all?(&is_nil/1)
  end

  defp same_acquisition?(%Session{} = live, attrs) do
    acquisition_tuple(live, &Map.get/2) == acquisition_tuple(attrs, &Maps.get_indifferent/2)
  end

  defp acquisition_tuple(source, getter) do
    Map.new(@acquisition_keys, fn key ->
      {key, normalize(key, getter.(source, key))}
    end)
  end

  defp normalize(key, value) when key in @source_keys do
    value
    |> normalize_string()
    |> direct_to_nil()
  end

  defp normalize(:click_id, value) do
    value
    |> normalize_string()
    |> cast_click_id()
  end

  defp normalize(_key, value), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(value), do: value

  defp direct_to_nil(value) when is_binary(value) do
    if String.downcase(value) == "direct", do: nil, else: value
  end

  defp direct_to_nil(:direct), do: nil
  defp direct_to_nil(value), do: value

  defp cast_click_id(nil), do: nil

  defp cast_click_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end
end
