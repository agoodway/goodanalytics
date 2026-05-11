# GoodAnalytics Core

Visitor intelligence, link tracking, source attribution, and behavioral analytics for Phoenix.

GoodAnalytics is a pluggable Elixir/Phoenix library that adds a visitor identity graph to any existing Phoenix application. Every tracking event enriches the same visitor record — anonymous visits, clicks, leads, and sales build a complete attribution picture over time. Short links act as identity bridges, connecting marketing channels to real visitors across sessions and devices.

## Features

- **No extra infrastructure** — All data lives in PostgreSQL in a `good_analytics` schema managed via ecto_evolver
- **Visitor identity graph** — Anonymous visitors progressively enrich into identified leads and customers
- **Click-to-conversion attribution** — Short link clicks, pageviews, leads, and sales all tie back to the same visitor
- **Source classification** — Automatic detection of UTMs, ad platform click IDs (gclid, fbclid, li_fat_id, ttclid), referrers, and GA params
- **Server-side conversion dispatch** — Built-in connectors for Meta CAPI, Google Ads, LinkedIn, and TikTok
- **Event hooks** — Sync and async hooks let downstream consumers react to clicks, sales, and identity changes
- **Library pattern** — Borrows your app's Ecto repo. No separate database

## Prerequisites

- Elixir 1.17+
- PostgreSQL 14+
- An existing Phoenix application with an Ecto repository

## Installation

### As a Git Dependency

Add `good_analytics` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:good_analytics, github: "agoodway/goodanalytics_core"}
  ]
end
```

### As a Path Dependency (Monorepo)

If you're working within the goodanalytics monorepo:

```elixir
def deps do
  [
    {:good_analytics, path: "../core"}
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

## Quick Start

### 1. Configure the Library

Add the minimum required configuration to your Phoenix app:

```elixir
# config/config.exs
config :good_analytics,
  repo: MyApp.Repo,
  api_key_secret: System.get_env("GA_API_KEY_SECRET")
```

**Configuration options:**

| Key | Required | Default | Description |
|-----|----------|---------|-------------|
| `:repo` | Yes | — | Your app's Ecto repo module |
| `:api_key_secret` | Yes | — | Secret key for API key encryption |
| `:schema_prefix` | No | `"good_analytics"` | PostgreSQL schema name for all `ga_` tables |
| `:connectors` | No | `[]` | List of connector adapter modules |
| `:connectors_enabled` | No | `true` | Global kill switch for connector dispatch |
| `:dispatch_policy` | No | — | `{Module, :function}` tuple for dispatch gating |
| `:auto_create_partitions` | No | `true` | Whether to auto-create time partitions |
| `:links` | No | `[]` | Link configuration, e.g. `[domains: ["mybrand.link"]]` |

**Cache configuration** (optional):

```elixir
config :good_analytics, GoodAnalytics.Cache,
  gc_interval: :timer.hours(1),
  max_size: 10_000
```

### 2. Run Database Setup

Generate the Ecto migration that creates the `good_analytics` schema and all `ga_` tables:

```bash
mix good_analytics.setup
mix ecto.migrate
```

This creates tables for visitors, events, links, link clicks, connectors, and settings — all namespaced under the `good_analytics` PostgreSQL schema.

### 3. Download UA Inspector Databases

GoodAnalytics uses [ua_inspector](https://hex.pm/packages/ua_inspector) to parse user-agent strings into device, browser, and OS details. Download the detection databases:

```bash
mix ua_inspector.download
```

Or run both setup steps at once:

```bash
mix setup
```

The UA databases persist in `_build` and only need to be downloaded once.

### 4. Mount Routes

Add GoodAnalytics routes to your Phoenix router:

```elixir
# lib/my_app_web/router.ex
defmodule MyAppWeb.Router do
  use MyAppWeb, :router

  # Tracking beacon endpoints (POST /ga/t/event, POST /ga/t/click)
  forward "/ga/t", GoodAnalytics.Core.Tracking.Router

  pipeline :browser do
    # ... your existing plugs ...

    # Add the tracking plug — classifies traffic source, manages identity
    # cookies (_ga_good, _ga_anon), and assigns tracking signals
    plug GoodAnalytics.Core.Tracking.Plug
  end

  # Short link QR code endpoint
  pipeline :short_link_qr do
    plug :fetch_query_params
  end

  # Short link redirect endpoint
  pipeline :short_link do
    plug :accepts, ["html"]
    plug :fetch_query_params
  end

  scope "/" do
    pipe_through :short_link_qr
    get "/:key/qr", GoodAnalytics.Core.Links.QRController, :show
  end

  scope "/" do
    pipe_through :short_link
    get "/:key", GoodAnalytics.Core.Links.RedirectController, :show
  end
end
```

**Important:** Place the short link catch-all routes (`/:key`) last in your router to avoid intercepting other routes.

### 5. Serve the JavaScript Client

Configure your endpoint to serve the JS tracking client:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/ga/js",
  from: {:good_analytics, "priv/static/js"},
  gzip: false
```

Include it in your root layout:

```html
<script src="/ga/js/good-analytics.js"></script>
<script>GoodAnalytics.init({ endpoint: "/ga/t" });</script>
```

**JS Client options:**

| Option | Default | Description |
|--------|---------|-------------|
| `endpoint` | — | Path to the tracking beacon endpoint |
| `autoSpaNavigation` | `true` | Automatically track SPA navigation (pushState, popstate, hashchange) |

Disable automatic SPA tracking if your app sends manual pageviews:

```html
<script>GoodAnalytics.init({ endpoint: "/ga/t", autoSpaNavigation: false });</script>
```

Every beacon payload includes a UUIDv4 `event_id` idempotency key that host applications can use for retry deduplication.

## API Reference

### Identity Resolution

```elixir
# Resolve tracking signals to a visitor
{:ok, visitor} = GoodAnalytics.resolve_visitor(signals, workspace_id: ws_id)

# Associate a visitor with known person attributes
{:ok, visitor} = GoodAnalytics.identify(visitor, %{
  person_external_id: "cust_123",
  person_email: "alice@example.com",
  person_name: "Alice"
})

# GDPR: Remove all PII and events for a visitor
:ok = GoodAnalytics.forget_visitor(visitor_id)
```

Identity resolution progressively merges visitor records as signals accumulate:
- **Strong signals** (external ID, email, `ga_id` cookie) can trigger merges on their own
- **Weak signals** (fingerprint, anonymous cookie) require corroboration from other signals

### Event Tracking

```elixir
# Record a pageview
GoodAnalytics.track(visitor, "pageview", %{url: "/pricing"})

# Record a lead conversion
GoodAnalytics.track_lead(visitor, %{person_external_id: "cust_123"})

# Record a sale
GoodAnalytics.track_sale(visitor, %{amount_cents: 4900, currency: "USD"})
```

### Server-Side Conversions

Submit conversions that also trigger connector dispatch (Meta CAPI, Google Ads, etc.):

```elixir
# Lead conversion with connector signals
{:ok, event} = GoodAnalytics.submit_lead(visitor, %{
  properties: %{"form" => "contact"}
}, connector_signals: %{"_fbp" => "fb.1.123", "gclid" => "abc"})

# Sale conversion with connector signals
{:ok, event} = GoodAnalytics.submit_sale(visitor, %{
  amount_cents: 4900,
  currency: "USD"
}, connector_signals: %{"_fbp" => "fb.1.123"})
```

Both functions record a canonical internal event first, then trigger connector dispatch planning for all enabled connectors that have the required signals.

### Link Management

```elixir
# Create a short link
{:ok, link} = GoodAnalytics.create_link(%{
  workspace_id: "00000000-0000-0000-0000-000000000000",
  domain: "mybrand.link",
  key: "gw-launch",
  url: "https://example.com/pricing",

  # Optional
  link_type: "campaign",          # "short", "referral", or "campaign"
  utm_source: "twitter",
  utm_medium: "social",
  utm_campaign: "launch-2026",
  utm_content: "hero-link",
  utm_term: "analytics",
  ios_url: "myapp://pricing",
  android_url: "myapp://pricing",
  expires_at: ~U[2026-12-31 23:59:59Z],
  tags: ["launch", "social"],
  external_id: "campaign_123",
  metadata: %{"owner" => "growth"}
})

# List links for a workspace
GoodAnalytics.list_links(workspace_id, limit: 50, offset: 0)

# Get link stats (aggregate counters)
GoodAnalytics.link_stats(link_id)

# Get recent click events for a link
GoodAnalytics.link_clicks(link_id, limit: 10)

# Soft-delete a link (frees domain+key for reuse)
GoodAnalytics.archive_link(link_id)
```

**Required link attributes:** `:workspace_id`, `:domain`, `:key`, `:url`

**PubSub topics:** Click events broadcast `{:link_click, link_id, unique?}` on:
- `"good_analytics:link_clicks"` — global topic
- `"good_analytics:link_clicks:#{workspace_id}"` — workspace-scoped

Recorded events broadcast `{:event_recorded, event}` on:
- `"good_analytics:events:#{workspace_id}"` — workspace-scoped

### Visitors

```elixir
GoodAnalytics.get_visitor(id)
GoodAnalytics.get_visitor_by_external_id(workspace_id, "cust_123")
GoodAnalytics.visitor_timeline(visitor_id)
GoodAnalytics.visitor_attribution(visitor_id)
```

### Event Hooks

Register callbacks that fire on specific event types:

```elixir
# Sync hook — runs during redirect (50ms timeout)
GoodAnalytics.register_hook(:link_click, fn event, visitor ->
  {:ok, %{set_cookies: [{"partner_id", "abc", 30}]}}
end)
```

### Share URLs

Generate social sharing URLs for a link:

```elixir
GoodAnalytics.share_urls("https://mybrand.link/gw-launch",
  title: "Check this out",
  text: "GoodAnalytics launch"
)
# => %{twitter: "https://twitter.com/intent/tweet?...", facebook: "https://www.facebook.com/sharer/...", ...}
```

## Connector Configuration

### Enabling Connectors

Register connector adapters at compile time:

```elixir
# config/config.exs
config :good_analytics,
  connectors: [
    GoodAnalytics.Connectors.Adapters.Meta,
    GoodAnalytics.Connectors.Adapters.Google,
    GoodAnalytics.Connectors.Adapters.LinkedIn,
    GoodAnalytics.Connectors.Adapters.TikTok
  ],
  dispatch_policy: {MyApp.ConnectorPolicy, :evaluate}

# runtime.exs — global kill switch
config :good_analytics, :connectors_enabled, true
```

### Per-Workspace Credentials

Enable connectors and store encrypted credentials per workspace:

```elixir
alias GoodAnalytics.Connectors.Settings

# Enable Meta for a workspace
Settings.enable_connector(workspace_id, :meta)

# Store encrypted credentials
Settings.put_credential(workspace_id, :meta, "access_token", "EAAx...")
Settings.put_credential(workspace_id, :meta, "pixel_id", "123456")
```

### Built-in Connectors

| Connector | Required Signals | Credential Keys |
|-----------|-----------------|-----------------|
| Meta CAPI | `_fbp`, `_fbc`, or `fbclid` | `access_token`, `pixel_id` |
| Google Ads | `gclid`, `gbraid`, or `wbraid` | `customer_id`, `conversion_action_id`, `access_token` |
| LinkedIn | `li_fat_id` | `access_token`, `conversion_rule_id`, `ad_account_id` |
| TikTok | `ttclid` | `access_token`, `pixel_code` |

### Custom Connectors

Implement the `GoodAnalytics.Connectors.Connector` behaviour:

```elixir
defmodule MyApp.Connectors.Custom do
  @behaviour GoodAnalytics.Connectors.Connector

  @impl true
  def connector_type, do: :custom

  @impl true
  def supported_event_types, do: [:lead, :sale]

  @impl true
  def required_signals, do: [["my_signal"]]

  @impl true
  def credential_keys, do: ["api_key"]

  @impl true
  def build_payload(dispatch, credentials), do: {:ok, %{}}

  @impl true
  def deliver(payload, credentials), do: {:ok, %{status: 200}}

  @impl true
  def classify_error(%{status: 429}), do: :rate_limited
  def classify_error(%{status: 401}), do: :credential
  def classify_error(_), do: :transient
end
```

## Mix Tasks

| Task | Description |
|------|-------------|
| `mix good_analytics.setup` | Generate Ecto migration for all GoodAnalytics tables |
| `mix good_analytics.gen.migration` | Generate a new migration file |
| `mix ua_inspector.download` | Download UA detection databases |
| `mix setup` | Run `deps.get` + `ua_inspector.download` |

## Testing

### Running the Core Test Suite

```bash
cd core
mix deps.get
mix test.setup     # creates the test database
mix test
```

### Test Configuration

Tests use a dedicated `GoodAnalytics.TestRepo` pointing at a local PostgreSQL database:

```elixir
# config/test.exs
config :good_analytics, GoodAnalytics.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "good_analytics_test",
  pool: Ecto.Adapters.SQL.Sandbox
```

Background partition creation is disabled in tests to avoid sandbox conflicts. Suites that need partitions call `PartitionManager.create_partitions_direct/0` explicitly.

### Quality Checks

```bash
mix quality
```

This runs: `compile --warnings-as-errors`, `deps.unlock --unused`, `format --check-formatted`, `sobelow`, `ex_dna`, `doctor`, and `credo --strict`.

## Repository Structure

This package lives in the `core/` directory of the [goodanalytics monorepo](https://github.com/agoodway/goodanalytics). The monorepo also contains:

- **`pro/`** — GoodAnalytics Pro, a full Phoenix application with dashboard UI, team management, and workspace administration
- **`docs/`** — Architecture documentation and data model reference
- **`openspec/`** — Feature specifications

## Documentation

- [Architecture](../docs/architecture.md) — System design, identity resolution algorithm, hook system, module structure, and data flows
- [Data Model](../docs/data_model.md) — Complete column-level schema reference for all `ga_` tables

## License

MIT
