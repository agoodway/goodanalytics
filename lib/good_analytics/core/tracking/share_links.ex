defmodule GoodAnalytics.Core.Tracking.ShareLinks do
  @moduledoc """
  Generates social share URLs for all major platforms.

  The short link IS the tracking mechanism — when someone clicks the
  shared link, the redirect handler sees the HTTP Referer and classifies
  the source platform.
  """

  @doc """
  Generates share URLs for all supported platforms.

  Returns a map of platform -> share URL.
  """
  def all_share_urls(short_link, opts \\ []) do
    %{
      twitter: share_url(short_link, :twitter, opts),
      facebook: share_url(short_link, :facebook, opts),
      linkedin: share_url(short_link, :linkedin, opts),
      whatsapp: share_url(short_link, :whatsapp, opts),
      telegram: share_url(short_link, :telegram, opts),
      reddit: share_url(short_link, :reddit, opts),
      email: share_url(short_link, :email, opts),
      copy: short_link
    }
  end

  @doc "Generates a share URL for the given platform."
  def share_url(link, :twitter, opts) do
    params =
      %{url: link}
      |> maybe_put(:text, opts[:text])
      |> maybe_put(:via, opts[:via])
      |> maybe_put(:hashtags, opts[:hashtags])

    "https://twitter.com/intent/tweet?" <> URI.encode_query(params)
  end

  def share_url(link, :facebook, _opts) do
    "https://www.facebook.com/sharer/sharer.php?" <> URI.encode_query(%{u: link})
  end

  def share_url(link, :linkedin, _opts) do
    "https://www.linkedin.com/sharing/share-offsite/?" <> URI.encode_query(%{url: link})
  end

  def share_url(link, :whatsapp, opts) do
    text = if opts[:text], do: "#{opts[:text]} #{link}", else: link
    "https://api.whatsapp.com/send?" <> URI.encode_query(%{text: text})
  end

  def share_url(link, :telegram, opts) do
    params =
      %{url: link}
      |> maybe_put(:text, opts[:text])

    "https://t.me/share/url?" <> URI.encode_query(params)
  end

  def share_url(link, :reddit, opts) do
    params =
      %{url: link}
      |> maybe_put(:title, opts[:title] || opts[:text])

    "https://reddit.com/submit?" <> URI.encode_query(params)
  end

  def share_url(link, :email, opts) do
    subject = opts[:subject] || opts[:text] || "Check this out"
    body = opts[:body] || link

    "mailto:?" <>
      URI.encode_query(%{subject: subject, body: body})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
