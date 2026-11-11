defmodule GoodAnalytics.Core.Tracking.Referers.Data do
  @moduledoc false
  # Compile-time loader for the vendored referrer database
  # (`priv/referers/referers.yml`). Used by `GoodAnalytics.Core.Tracking.Referers`
  # while compiling, and by the build-time update task, so the medium vocabulary
  # is defined exactly once, here. Not part of the runtime API.
  #
  # YAML syntax errors in the vendored file raise from `yamerl` (no rescue): a
  # corrupt data file should fail the build.

  # Snowplow-format medium sections, in the order they appear in the file, each
  # with the medium it maps to (Decision 4: search -> organic, chatbot -> ai,
  # unknown -> referral). `ignore` is a supplement medium for hand-offs that are
  # never an acquisition source.
  @section_mediums [
    {"ignore", :ignore},
    {"email", :email},
    {"social", :social},
    {"search", :organic},
    {"paid", :paid},
    {"chatbot", :ai},
    {"unknown", :referral}
  ]

  @type entry :: %{
          medium: String.t(),
          name: String.t(),
          platform: String.t(),
          domains: [String.t()],
          utm_sources: [String.t()]
        }

  @doc "Section names in file order."
  @spec sections() :: [String.t()]
  def sections, do: Enum.map(@section_mediums, &elem(&1, 0))

  @doc "Section name -> medium atom."
  @spec section_mediums() :: %{String.t() => atom()}
  def section_mediums, do: Map.new(@section_mediums)

  @doc """
  Reads a merged file into `%{aliases: map, entries: [entry]}`.

  Entries keep file order (supplement, then Snowplow, then Matomo within each
  medium), which decides display names, so this parses as ordered proplists.
  """
  @spec load_merged!(binary()) :: %{aliases: map(), entries: [entry()]}
  def load_merged!(yaml) do
    doc =
      case :yamerl_constr.string(yaml, [:str_node_as_binary]) do
        [doc | _] when is_list(doc) -> doc
        _ -> []
      end

    entries =
      for section <- sections(),
          {name, body} <- section(doc, section) do
        %{
          medium: section,
          name: name,
          platform: :proplists.get_value("platform", body),
          domains: :proplists.get_value("domains", body, []),
          utm_sources: []
        }
      end

    %{aliases: Map.new(section(doc, "aliases")), entries: entries}
  end

  defp section(doc, name) do
    case :proplists.get_value(name, doc, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end
end
