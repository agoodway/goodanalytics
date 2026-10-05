defmodule GoodAnalytics.MixProject do
  use Mix.Project

  @version "0.1.2"
  @source_url "https://github.com/agoodway/goodanalytics"

  def project do
    [
      app: :good_analytics,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases(),

      # Hex
      description:
        "Visitor intelligence, link tracking, source attribution, and behavioral analytics for Phoenix",
      package: package(),

      # Docs
      name: "GoodAnalytics",
      source_url: @source_url,
      docs: docs(),

      # Test Coverage
      test_coverage: [tool: ExCoveralls],

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        ignore_warnings: ".dialyzer_ignore.exs"
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        quality: :test,
        precommit: :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {GoodAnalytics.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Database
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},

      # Phoenix
      {:phoenix, "~> 1.8.14"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_live_view, "~> 1.2.11", optional: true},
      {:plug_cowboy, "~> 2.5"},
      {:jason, "~> 1.4"},

      # Caching
      {:nebulex, "~> 3.0"},
      {:nebulex_local, "~> 3.0"},
      {:decorator, "~> 1.4"},

      # UUID
      {:uniq, "~> 0.6"},

      # Network types (PostgreSQL INET/CIDR)
      {:ecto_network, "~> 1.6"},

      # Encryption (connector credentials)
      {:cloak_ecto, "~> 1.3"},

      # HTTP client (connector delivery)
      {:req, "~> 0.5"},

      # OpenAPI spec generation
      {:open_api_spex, "~> 3.21"},

      # User agent parsing
      {:ua_inspector, "~> 3.0"},

      # GeoIP enrichment (optional; only loaded when host app declares :locus
      # and configures `:good_analytics, :geo`). See README for setup.
      {:locus, "~> 2.3", optional: true},

      # QR code generation
      {:qr_code, "~> 3.2"},

      # Infrastructure
      {:ecto_evolver, "~> 0.1.0"},
      {:pgflow, "~> 0.5.0"},
      # Required so PgFlow dashboard modules compile (optional dep of pgflow)
      {:livefilter, "~> 0.2.0"},

      # Dev/Test
      {:ex_doc, "~> 0.31", only: :dev, runtime: false},
      {:sobelow, "~> 0.15.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.23.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18.5", only: [:dev, :test], runtime: false},
      {:mimic, "~> 1.10", only: :test}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ua_inspector.download"],
      "test.setup": ["ecto.create --repo GoodAnalytics.TestRepo --quiet"],
      quality: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "sobelow --config",
        "ex_dna",
        "doctor",
        "credo --strict"
      ],
      # Full gate including ExUnit (runs node --test for good-analytics.js behavior suite).
      # Requires Node.js on PATH for tracking JS client tests.
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "test"
      ]
    ]
  end

  defp package do
    [
      maintainers: ["AGoodWay"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end
end
