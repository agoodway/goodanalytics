defmodule GoodAnalytics.Sources do
  @moduledoc """
  The shared source and channel vocabulary.

  A *source* is the `{platform, medium}` pair recorded on an event or visitor.
  This module turns it into a GA4-aligned *channel* (`channel/1`, `channel/2`),
  a human label (`label/1`) and a static SQL CASE for grouping events
  (`channel_sql/1`).

  Channels follow the GA4 default channel group: `:organic_search`,
  `:organic_social`, `:paid_search`, `:paid_social`, `:email`, `:referral`,
  `:direct`, `:ai_assistant`, `:affiliates`, `:sms`, `:organic_video`,
  `:display`, plus `:other`. `channel_name/1` gives the GA4 display name.

  A paid medium (`paid`, `cpc`, `ppc`) is `:paid_search` unless the platform is
  a social network, which makes it `:paid_social`. That needs the platform, so
  use `channel/2` or pass a source map to `channel/1`. A UTM medium of
  `messaging` counts as social and `sms` as `:sms`.
  """

  import Ecto.Query, only: [dynamic: 2]

  alias GoodAnalytics.Core.Tracking.Referers
  alias GoodAnalytics.{Maps, Text}

  @channels ~w(organic_search organic_social paid_search paid_social email referral
               direct ai_assistant affiliates sms organic_video display other)a

  @channel_names %{
    organic_search: "Organic Search",
    organic_social: "Organic Social",
    paid_search: "Paid Search",
    paid_social: "Paid Social",
    email: "Email",
    referral: "Referral",
    direct: "Direct",
    ai_assistant: "AI Assistant",
    affiliates: "Affiliates",
    sms: "SMS",
    organic_video: "Organic Video",
    display: "Display",
    other: "Other"
  }

  # Lowercased medium -> channel. Paid mediums are listed separately because
  # they split by platform.
  @medium_channels %{
    "organic" => :organic_search,
    "search" => :organic_search,
    "organic_search" => :organic_search,
    "social" => :organic_social,
    "messaging" => :organic_social,
    "organic_social" => :organic_social,
    "paid_social" => :paid_social,
    "paid_search" => :paid_search,
    "email" => :email,
    "newsletter" => :email,
    "referral" => :referral,
    "ai" => :ai_assistant,
    "ai_assistant" => :ai_assistant,
    "affiliate" => :affiliates,
    "affiliates" => :affiliates,
    "sms" => :sms,
    "video" => :organic_video,
    "organic_video" => :organic_video,
    "display" => :display,
    "direct" => :direct,
    "" => :direct,
    "none" => :direct,
    "(none)" => :direct
  }

  @paid_mediums ~w(paid cpc ppc)

  @social_platform_keys Referers.social_platform_keys()

  # The historical medium "unknown" is read from the platform, in this fixed
  # order, by the platform's primary medium; anything else is a referral. Only
  # plain-word keys are used: a few vendored slugs are non-ASCII (`abcsøk`) and
  # have no place in the static SQL, so they read as a referral in Elixir and
  # SQL alike.
  @unknown_channels for {medium, channel} <- [
                          ai: :ai_assistant,
                          social: :organic_social,
                          organic: :organic_search,
                          email: :email,
                          paid: :paid_search
                        ],
                        do:
                          {channel,
                           Enum.filter(
                             Referers.primary_platform_keys(medium),
                             &(&1 =~ ~r/\A[a-z0-9_]+\z/)
                           )}

  @alias_regex ~r/^[a-z_][a-z0-9_]*$/

  @medium_key_sql "coalesce(nullif(lower(btrim(?)), ''), 'direct')"

  @type channel ::
          :organic_search
          | :organic_social
          | :paid_search
          | :paid_social
          | :email
          | :referral
          | :direct
          | :ai_assistant
          | :affiliates
          | :sms
          | :organic_video
          | :display
          | :other

  unknown_channel_keys = Enum.map(@unknown_channels, &elem(&1, 0))

  if length(Enum.uniq(unknown_channel_keys)) != length(unknown_channel_keys) do
    raise ArgumentError,
          "duplicate @unknown_channels keys: #{inspect(unknown_channel_keys)}"
  end

  # Everything interpolated into the static SQL CASE must be a plain word, so a
  # data or table change can never produce broken (or injectable) SQL.
  # `""` and `"(none)"` are the two literal "no medium" spellings.
  for value <-
        (Map.keys(@medium_channels) -- ["", "(none)"]) ++
          @paid_mediums ++
          @social_platform_keys ++
          Enum.flat_map(@unknown_channels, &elem(&1, 1)) ++
          Enum.map(@channels, &Atom.to_string/1),
      not (value =~ ~r/\A[a-z0-9_]+\z/) do
    raise ArgumentError, "unsafe value for the Sources SQL CASE: #{inspect(value)}"
  end

  @doc "All channel atoms."
  @spec channels() :: [channel()]
  def channels, do: @channels

  @doc "GA4 display name for a channel atom (`:ai_assistant` -> `\"AI Assistant\"`)."
  @spec channel_name(channel()) :: String.t()
  def channel_name(channel), do: Map.fetch!(@channel_names, channel)

  @doc """
  Channel for a medium, or for a source map (`platform`/`medium` or
  `source_platform`/`source_medium`, atom or string keys).

  The medium may be an atom, a string (case-insensitive) or `nil`, which is
  `:direct`. Paid mediums are `:paid_search`; use `channel/2` or a map to get
  `:paid_social` for social platforms. Unrecognized mediums are `:other`.

  A source map with no medium has its medium inferred from the platform, the
  same as `label/1`. That inference applies only to maps: event rows never carry
  a NULL medium together with a platform, and `channel/2` and the SQL treat a
  NULL medium as `:direct`. The historical medium `"unknown"` is read from the
  platform's primary medium by `channel/2`, `channel_sql/1`, `channel_fragment/2`
  and the map form alike.
  """
  @spec channel(map() | atom() | String.t() | nil) :: channel()
  def channel(%{} = source) do
    platform = platform_of(source)
    channel(effective_medium(source, platform), platform)
  end

  def channel(medium), do: channel(medium, nil)

  @doc """
  Channel for a medium and platform. The platform matters for paid mediums,
  where a social network makes the channel `:paid_social`, and for the
  historical medium `"unknown"`: the platform's primary medium decides the
  channel (AI assistant, social, search, email, paid search), anything else is
  `:referral`.
  """
  @spec channel(atom() | String.t() | nil, atom() | String.t() | nil) :: channel()
  def channel(medium, platform) do
    key = medium_key(medium)

    cond do
      key in @paid_mediums -> if social_platform?(platform), do: :paid_social, else: :paid_search
      key == "unknown" -> unknown_channel(platform)
      true -> Map.get(@medium_channels, key, :other)
    end
  end

  @doc """
  Human label for a source: `"<Channel> · <Platform>"`, for example
  `"Organic Search · Google"` or `"Referral · example.com"`.

  Accepts a visitor source map (`platform`, `medium`, `referer_domain`; atom or
  string keys) or event columns (`source_platform`, `source_medium`,
  `referrer`). A missing medium is inferred from a known platform. The channel
  alone is shown when there is no platform or it repeats the channel name.
  `nil`, `%{}` and direct sources are `"Direct"`.
  """
  @spec label(map() | nil) :: String.t()
  def label(%{} = source) do
    case channel(source) do
      :direct -> channel_name(:direct)
      channel -> compose(channel, detail_name(channel, platform_of(source), source))
    end
  end

  def label(_), do: channel_name(:direct)

  @doc """
  Display name for a platform: the vendored list name (`"LinkedIn"`,
  `"ChatGPT"`) or `String.capitalize/1` for an unknown one.
  """
  @spec platform_name(atom() | String.t()) :: String.t()
  def platform_name(platform) do
    Referers.name(platform) || platform |> to_string() |> String.capitalize()
  end

  @doc """
  Static SQL CASE expression producing the channel key (`'organic_search'`, ...)
  for events aliased `table_alias`, for hosts that write raw SQL. It reads
  `<alias>.source_medium` and `<alias>.source_platform`. Ecto hosts should use
  `channel_fragment/2`; both are built from the same tables as `channel/2`.

  Raises `ArgumentError` unless the alias matches `#{inspect(@alias_regex)}`.
  """
  @spec channel_sql(String.t()) :: String.t()
  def channel_sql(table_alias) when is_binary(table_alias) do
    unless table_alias =~ @alias_regex do
      raise ArgumentError, "invalid SQL alias: #{inspect(table_alias)}"
    end

    medium = "#{table_alias}.source_medium"
    platform = "#{table_alias}.source_platform"
    columns = [medium, platform, medium] ++ unknown_platforms(platform) ++ [medium]

    Enum.reduce(columns, case_sql(), fn column, sql ->
      String.replace(sql, "?", column, global: false)
    end)
  end

  @doc """
  Ecto query expression for the channel key, the `fragment/1` counterpart of
  `channel_sql/1`. `medium` and `platform` are query expressions:

      require GoodAnalytics.Sources

      from e in Event,
        select: %{
          channel:
            selected_as(
              GoodAnalytics.Sources.channel_fragment(e.source_medium, e.source_platform),
              :channel
            ),
          count: count(e.id)
        },
        group_by: selected_as(:channel)

  The CASE is a compile-time literal; the expressions are its only
  parameters (medium, platform, medium, the platform once per `unknown` branch,
  medium). It is
  built from the same tables as `channel/2`, so the Elixir and SQL answers
  agree.
  """
  defmacro channel_fragment(medium, platform) do
    sql = case_sql()

    args = [medium, platform, medium] ++ unknown_platforms(platform) ++ [medium]

    quote do
      fragment(unquote(sql), unquote_splicing(args))
    end
  end

  @doc """
  Ecto `dynamic/2` condition for filtering events (first query binding) by
  `source_medium` with an operator (`:eq`, `:neq`, `:in`, `:not_in`), or `nil`
  when the operator or value is not filterable.

  A missing or blank medium counts as `"direct"`, the same as the `:direct`
  channel, so a filter on `direct` matches events with no medium at all (which
  is what internal navigation records). Use it in place of a plain column
  comparison for the `source_medium` field.
  """
  @spec medium_filter(atom(), term()) :: Ecto.Query.dynamic_expr() | nil
  def medium_filter(:eq, value) when is_binary(value) and value != "" do
    value = normalize_medium(value)
    dynamic([e], fragment(@medium_key_sql, e.source_medium) == ^value)
  end

  def medium_filter(:neq, value) when is_binary(value) and value != "" do
    value = normalize_medium(value)
    dynamic([e], fragment(@medium_key_sql, e.source_medium) != ^value)
  end

  def medium_filter(:in, values) when is_list(values) and values != [] do
    values = Enum.map(values, &normalize_medium/1)
    dynamic([e], fragment(@medium_key_sql, e.source_medium) in ^values)
  end

  def medium_filter(:not_in, values) when is_list(values) and values != [] do
    values = Enum.map(values, &normalize_medium/1)
    dynamic([e], fragment(@medium_key_sql, e.source_medium) not in ^values)
  end

  def medium_filter(_operator, _value), do: nil

  @doc "The SQL behind `medium_filter/2` for a column such as `\"e.source_medium\"`."
  @spec medium_filter_sql(String.t()) :: String.t()
  def medium_filter_sql(column) when is_binary(column),
    do: String.replace(@medium_key_sql, "?", column)

  @doc """
  The mediums that make up a channel: the inverse of the medium table behind
  `channel/2`. Paid search and paid social both return the paid mediums, since
  the split needs a platform condition. `:direct` includes the blank and
  `"none"` spellings; `:other` has no fixed mediums.
  """
  @spec mediums(channel()) :: [String.t()]
  def mediums(channel) when channel in @channels do
    listed = for {medium, ^channel} <- @medium_channels, do: medium
    paid = if channel in [:paid_search, :paid_social], do: @paid_mediums, else: []
    Enum.sort(paid ++ listed)
  end

  @doc """
  Parses a channel key string (`"organic_search"`) into its atom, or `:error`.
  Safe for untrusted input: it never creates atoms.
  """
  @spec parse_channel(term()) :: {:ok, channel()} | :error
  def parse_channel(key) when is_binary(key) do
    case Enum.find(@channels, &(Atom.to_string(&1) == key)) do
      nil -> :error
      channel -> {:ok, channel}
    end
  end

  def parse_channel(_), do: :error

  # -- Private --

  # One CASE template shared by `channel_sql/1` and `channel_fragment/2`. Its
  # `?` placeholders are, in order: medium, platform, medium, then the
  # platform once per `@unknown_channels` entry, then medium.
  defp case_sql do
    simple =
      Enum.map_join(Enum.sort(@medium_channels), " ", fn {medium, channel} ->
        "WHEN '#{medium}' THEN '#{channel}'"
      end)

    unknown_whens =
      Enum.map_join(@unknown_channels, " ", fn {channel, keys} ->
        "WHEN lower(coalesce(?, '')) IN (#{quote_list(keys)}) THEN '#{channel}'"
      end)

    "CASE WHEN lower(btrim(coalesce(?, ''))) IN (#{quote_list(@paid_mediums)}) THEN " <>
      "CASE WHEN lower(coalesce(?, '')) IN (#{quote_list(@social_platform_keys)}) " <>
      "THEN 'paid_social' ELSE 'paid_search' END " <>
      "WHEN lower(btrim(coalesce(?, ''))) = 'unknown' THEN CASE #{unknown_whens} " <>
      "ELSE 'referral' END " <>
      "ELSE CASE lower(btrim(coalesce(?, ''))) #{simple} ELSE 'other' END END"
  end

  defp unknown_platforms(platform), do: List.duplicate(platform, length(@unknown_channels))

  defp quote_list(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp unknown_channel(platform) do
    key = platform_key(platform)

    Enum.find_value(@unknown_channels, :referral, fn {channel, keys} ->
      if key in keys, do: channel
    end)
  end

  defp social_platform?(platform), do: platform_key(platform) in @social_platform_keys

  defp platform_key(nil), do: nil
  defp platform_key(platform), do: platform |> to_string() |> String.downcase()

  defp medium_key(nil), do: ""
  defp medium_key(medium), do: normalize_medium(medium)

  # The same trim and lowercase the SQL key applies, for filter values.
  # to_string/1 keeps atoms and nil safe: nil becomes "", which matches no key.
  defp normalize_medium(medium), do: medium |> to_string() |> String.trim() |> String.downcase()

  defp medium_of(source), do: fetch(source, [:medium, :source_medium])
  defp platform_of(source), do: fetch(source, [:platform, :source_platform])

  defp fetch(source, keys) do
    Enum.find_value(keys, fn key ->
      source |> Maps.get_indifferent(key) |> Text.blank_to_nil()
    end)
  end

  # No medium but a platform: use the platform's primary medium. `channel/1`
  # and `label/1` both go through this. A medium of "unknown" is passed on to
  # `channel/2`, which reads it from the platform's key lists.
  defp effective_medium(source, nil), do: medium_of(source)

  defp effective_medium(source, platform),
    do: medium_of(source) || infer_medium(to_string(platform))

  defp infer_medium(generic) when generic in ["direct", "referral"], do: generic

  defp infer_medium(platform) do
    case Referers.resolve(platform) do
      %{medium: medium} -> medium
      nil -> :unknown
    end
  end

  defp detail_name(_channel, nil, source), do: domain_of(source)

  defp detail_name(:referral, platform, source) do
    cond do
      generic_platform?(platform) -> domain_of(source)
      # A list entry that is only a referral (docs.google.com): the host says
      # more than the platform name.
      Referers.name(platform) -> domain_of(source) || Referers.name(platform)
      true -> to_string(platform)
    end
  end

  defp detail_name(_channel, platform, _source) do
    if generic_platform?(platform), do: nil, else: platform_name(platform)
  end

  defp generic_platform?(platform), do: to_string(platform) in ["referral", "direct", ""]

  defp domain_of(source) do
    Referers.bare_host(fetch(source, [:referer_domain])) ||
      Referers.bare_host(fetch(source, [:referrer, :referer_url]))
  end

  defp compose(channel, nil), do: channel_name(channel)

  defp compose(channel, name) do
    channel_name = channel_name(channel)

    if String.downcase(name) == String.downcase(channel_name) do
      channel_name
    else
      "#{channel_name} · #{name}"
    end
  end
end
