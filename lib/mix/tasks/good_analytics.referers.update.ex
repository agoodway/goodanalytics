defmodule Mix.Tasks.GoodAnalytics.Referers.Update do
  @shortdoc "Regenerates the vendored referrer database (priv/referers/referers.yml)"

  @moduledoc """
  Rebuilds `priv/referers/referers.yml` from public referrer lists.

  Maintainer-only: it is run from a checkout of the library to refresh the data
  that ships with a release. Host apps never need it, since the data is compiled
  into the library.

  Merges, in precedence order:

    1. the hand-kept supplement, `priv/referers/good_analytics_referers.yml`
    2. the Snowplow referer-parser database (`resources/referers.yml`)
    3. the Matomo `searchengine-and-social-list` (`SearchEngines.yml`,
       `Socials.yml`, `AIAssistants.yml`)

  The result is Snowplow-format YAML whose first line records the upstream
  commits: `# snowplow: <sha>, matomo: <sha>, generated: <date>`. The library
  compiles it into `GoodAnalytics.Core.Tracking.Referers`, so refreshing the
  lists means running this task and releasing the library.

      mix good_analytics.referers.update [--snowplow-ref SHA] [--matomo-ref SHA] [--dry-run]

  ## Options

    * `--snowplow-ref` - Snowplow commit (default: current `master`)
    * `--matomo-ref` - Matomo commit (default: current `master`)
    * `--dry-run` - print the diff summary and write nothing
  """

  use Mix.Task

  alias Mix.GoodAnalytics.Referers.Builder

  @snowplow_repo "snowplow-referer-parser/referer-parser"
  @matomo_repo "matomo-org/searchengine-and-social-list"
  @switches [snowplow_ref: :string, matomo_ref: :string, dry_run: :boolean]

  @default_output Path.expand("../../../priv/referers/referers.yml", __DIR__)
  @default_supplement Path.expand("../../../priv/referers/good_analytics_referers.yml", __DIR__)

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:req)

    case update(args, []) do
      {:ok, _summary} -> :ok
      {:error, reason} -> Mix.raise("referers update failed: #{inspect(reason)}")
    end
  end

  @doc """
  Runs the update. Returns `{:ok, summary}` or `{:error, reason}`.

  ## Options (for tests)

    * `:fetch` - `(url -> {:ok, body} | {:error, reason})`, defaults to `Req`
    * `:output` - merged file path
    * `:supplement` - supplement file path
    * `:today` - `Date` used in the header
  """
  @spec update([String.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def update(args, opts) do
    {parsed, _rest, invalid} = OptionParser.parse(args, strict: @switches)
    reject_invalid!(invalid)
    fetch = Keyword.get(opts, :fetch, &http_get/1)
    output = Keyword.get(opts, :output, @default_output)
    supplement_path = Keyword.get(opts, :supplement, @default_supplement)
    today = Keyword.get_lazy(opts, :today, &Date.utc_today/0)

    with {:ok, snowplow_sha} <- resolve_ref(fetch, @snowplow_repo, parsed[:snowplow_ref]),
         {:ok, matomo_sha} <- resolve_ref(fetch, @matomo_repo, parsed[:matomo_ref]),
         {:ok, snowplow_yaml} <-
           fetch_raw(fetch, @snowplow_repo, snowplow_sha, "resources/referers.yml"),
         {:ok, matomo_docs} <- fetch_matomo(fetch, matomo_sha),
         {:ok, supplement_yaml} <- read_supplement(supplement_path) do
      built =
        Builder.build(
          Builder.parse!(supplement_yaml),
          Builder.parse!(snowplow_yaml),
          matomo_docs
        )

      rendered = Builder.render(built, snowplow_sha, matomo_sha, today)
      summary = Builder.diff_summary(previous_doc(output), built)

      report(summary, snowplow_sha, matomo_sha)
      write(rendered, output, parsed[:dry_run] || false, summary)
    end
  end

  defp reject_invalid!([]), do: :ok

  defp reject_invalid!(invalid) do
    flags = Enum.map_join(invalid, ", ", fn {flag, _} -> flag end)

    Mix.raise(
      "unknown or malformed option(s): #{flags}. " <>
        "Valid options: --snowplow-ref SHA, --matomo-ref SHA, --dry-run"
    )
  end

  defp write(_rendered, _output, true, summary) do
    Mix.shell().info("dry run: nothing written")
    {:ok, summary}
  end

  defp write(rendered, output, false, summary) do
    with :ok <- File.mkdir_p(Path.dirname(output)),
         :ok <- File.write(output, rendered) do
      Mix.shell().info("wrote #{output}")
      {:ok, summary}
    end
  end

  defp report(summary, snowplow_sha, matomo_sha) do
    Mix.shell().info(
      "snowplow #{snowplow_sha}, matomo #{matomo_sha}: " <>
        "#{summary.entries} entries, #{summary.hosts} hosts " <>
        "(+#{summary.added} / -#{summary.removed} hosts vs current)"
    )
  end

  defp previous_doc(output) do
    case File.read(output) do
      {:ok, yaml} -> Builder.parse!(yaml)
      {:error, _} -> nil
    end
  end

  defp read_supplement(path) do
    case File.read(path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, reason} -> {:error, {:supplement_unreadable, path, reason}}
    end
  end

  defp resolve_ref(_fetch, _repo, ref) when is_binary(ref), do: {:ok, ref}

  defp resolve_ref(fetch, repo, nil) do
    url = "https://api.github.com/repos/#{repo}/commits/master"

    with {:ok, body} <- fetch_url(fetch, url),
         {:ok, %{"sha" => sha}} <- Jason.decode(body) do
      {:ok, sha}
    else
      {:error, _} = error -> error
      other -> {:error, {:unexpected_ref_response, url, other}}
    end
  end

  defp fetch_raw(fetch, repo, sha, path) do
    fetch_url(fetch, "https://raw.githubusercontent.com/#{repo}/#{sha}/#{path}")
  end

  defp fetch_matomo(fetch, sha) do
    Enum.reduce_while(Builder.matomo_sections(), {:ok, []}, fn {file, section}, {:ok, acc} ->
      case fetch_raw(fetch, @matomo_repo, sha, file) do
        {:ok, yaml} -> {:cont, {:ok, [{section, Builder.parse!(yaml)} | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, docs} -> {:ok, Enum.reverse(docs)}
      error -> error
    end
  end

  defp fetch_url(fetch, url) do
    case fetch.(url) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:fetch_failed, url, reason}}
    end
  end

  defp http_get(url) do
    case Req.get(url, decode_body: false) do
      {:ok, %Req.Response{status: 200, body: body}} -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:http_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
