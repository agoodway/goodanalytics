defmodule GoodAnalytics.Core.Sessions.SessionFields do
  @moduledoc """
  Pure per-event session field computation.
  """

  alias GoodAnalytics.Core.Events.UrlNormalizer
  alias GoodAnalytics.Core.Sessions.Acquisition
  alias GoodAnalytics.Core.Sessions.Session
  alias GoodAnalytics.Maps

  @hop_cap_seconds 30 * 60
  @engaged_seconds_threshold 10
  @conversion_types ~w(lead sale)
  @interactive_event_types ~w(link_click identify lead sale share custom)

  @doc """
  Builds the attrs for a brand-new session's first event.
  """
  @spec new_session_attrs(String.t(), map(), DateTime.t()) :: map()
  def new_session_attrs(event_type, attrs, ts) do
    pageview? = pageview?(event_type)
    path = page_path(attrs)
    pageviews = if pageview?, do: 1, else: 0

    seed =
      %{
        started_at: ts,
        last_event_at: ts,
        entry_url: Maps.get_indifferent(attrs, :url),
        entry_page: path,
        exit_page: path,
        pageviews: pageviews,
        events: 1,
        duration_seconds: 0,
        engaged_seconds: 0,
        is_bounce: first_event_bounce?(event_type),
        device_type: Maps.get_indifferent(attrs, :device_type),
        browser: Maps.get_indifferent(attrs, :browser),
        os: Maps.get_indifferent(attrs, :os)
      }
      |> Map.merge(Acquisition.to_session_acquisition(attrs))

    Map.put(seed, :is_engaged, engaged?(seed, event_type))
  end

  @doc """
  Computes field changes for a subsequent event on a live session.
  """
  @spec update_session_attrs(Session.t(), String.t(), map(), DateTime.t()) :: map()
  def update_session_attrs(%Session{} = live, event_type, attrs, ts) do
    pageview? = pageview?(event_type)
    path = page_path(attrs)

    pageviews = count(live, :pageviews) + if(pageview?, do: 1, else: 0)
    events = count(live, :events) + 1
    duration_seconds = count(live, :duration_seconds) + hop_seconds(live.last_event_at, ts)
    engaged_seconds = count(live, :engaged_seconds)

    changes = %{
      last_event_at: ts,
      exit_page: exit_page(live, pageview?, path),
      pageviews: pageviews,
      events: events,
      duration_seconds: duration_seconds,
      engaged_seconds: engaged_seconds,
      is_bounce: bounce?(live, event_type, pageviews)
    }

    Map.put(changes, :is_engaged, live.is_engaged == true || engaged?(changes, event_type))
  end

  @doc """
  Returns true when a session meets the GA4 engaged-session thresholds.
  """
  @spec engaged?(Session.t() | map()) :: boolean()
  def engaged?(session_or_attrs), do: engaged?(session_or_attrs, nil)

  defp engaged?(session_or_attrs, event_type) do
    count(session_or_attrs, :engaged_seconds) >= @engaged_seconds_threshold ||
      count(session_or_attrs, :pageviews) >= 2 ||
      conversion?(event_type)
  end

  defp pageview?("pageview"), do: true
  defp pageview?(_event_type), do: false

  defp page_path(attrs) do
    case Maps.get_indifferent(attrs, :path) do
      path when is_binary(path) and path != "" ->
        path

      _ ->
        attrs
        |> Maps.get_indifferent(:url)
        |> path_from_url()
    end
  end

  defp path_from_url(url) when is_binary(url) and url != "", do: UrlNormalizer.path(url)
  defp path_from_url(_url), do: nil

  defp interactive?(event_type), do: event_type in @interactive_event_types

  defp first_event_bounce?(event_type), do: pageview?(event_type) or not interactive?(event_type)

  defp exit_page(_live, true, path) when is_binary(path), do: path
  defp exit_page(%Session{} = live, _pageview?, _path), do: live.exit_page

  defp bounce?(%Session{} = live, event_type, pageviews) do
    live.is_bounce == true && !unbounces?(event_type, pageviews)
  end

  defp unbounces?("pageview", pageviews), do: pageviews >= 2
  defp unbounces?(event_type, _pageviews), do: interactive?(event_type)

  defp hop_seconds(nil, _ts), do: 0

  defp hop_seconds(last_event_at, ts) do
    ts
    |> DateTime.diff(last_event_at, :second)
    |> max(0)
    |> min(@hop_cap_seconds)
  end

  defp conversion?(event_type), do: event_type in @conversion_types

  defp count(%Session{} = session, key), do: Map.get(session, key) || 0

  defp count(map, key) when is_map(map) do
    Maps.get_indifferent(map, key) || 0
  end
end
