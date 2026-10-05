# GoodAnalytics

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

- Elixir 1.18+
- PostgreSQL 14+
- An existing Phoenix application with an Ecto repository
- PgFlow 0.5 (installed as a dependency; its database schema is needed only if your app supervises PgFlow — see [Background flows (PgFlow)](#background-flows-pgflow))

## Installation

### From Hex

```elixir
def deps do
  [
    {:good_analytics, "~> 0.1.1"}
  ]
end
```

### As a Git Dependency

Add `good_analytics` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:good_analytics, github: "agoodway/goodanalytics"}
  ]
end
```

### As a Path Dependency

For local development against a checkout of this repo:

```elixir
def deps do
  [
    {:good_analytics, path: "../goodanalytics"}
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
| `:api_authenticate` | No | — | Auth callback for REST API (`{Module, :function}` or fn/2) |

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

See [Database Migrations](#database-migrations) for the full host-app workflow, including upgrades after library updates.

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

### 4. (Optional) Set Up Geo Enrichment

Populates `visitor.geo` with country/region/city/timezone/coordinates and enables country-routed redirects via `link.geo_targeting`. Off by default; `Geo.lookup/1` returns `{:error, :geo_disabled}` until configured.

Add `:locus` to your host app:

```elixir
{:locus, "~> 2.3"}
```

Get a MaxMind license key (free signup at https://www.maxmind.com/en/geolite2/signup) and configure:

```elixir
config :good_analytics, :geo,
  provider: GoodAnalytics.Geo.Locus,
  loader: {:maxmind, "GeoLite2-City"}

config :locus, license_key: System.get_env("MAXMIND_LICENSE_KEY")
```

Locus auto-downloads the MMDB on boot and caches it in `~/.cache/locus_erlang`. Lookups are `:persistent_term`-backed and sub-millisecond. Look for `GoodAnalytics.Geo loader registered` in the logs to confirm; use `:ok = GoodAnalytics.Geo.Loader.await(30_000)` to block in release tasks.

To use a non-MaxMind MMDB (DB-IP Lite, IPLocate, IP2Location LITE), configure a custom `:loader` and implement `GoodAnalytics.Geo.Normalizer` for that provider's fields. Only the MaxMind normalizer ships.

### 5. Mount Routes

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

### 6. Mount the REST API (Optional)

GoodAnalytics includes a server-side REST API for event tracking, link management, and visitor queries. To enable it, configure an authentication callback and mount the API router.

**Configure authentication:**

```elixir
# config/config.exs
config :good_analytics, :api_authenticate, {MyApp.Auth, :authenticate_ga_api}
```

The callback receives `(token, type)` where `type` is `:bearer` or `:api_key`, and must return `{:ok, %{workspace_id: uuid}}` on success or `{:error, reason}` on failure:

```elixir
# lib/my_app/auth.ex
defmodule MyApp.Auth do
  def authenticate_ga_api(token, _type) do
    case MyApp.ApiKeys.verify(token) do
      {:ok, api_key} -> {:ok, %{workspace_id: api_key.workspace_id}}
      :error -> {:error, :unauthorized}
    end
  end
end
```

**Mount the router:**

```elixir
# lib/my_app_web/router.ex
forward "/ga/api", GoodAnalytics.Api.Router
```

**Serve the OpenAPI spec and Swagger UI** (optional):

```elixir
forward "/api/docs", GoodAnalytics.ApiSpec.Router
```

### 7. Serve the JavaScript Client

Configure your endpoint to serve the JS tracking client:

```elixir
# lib/my_app_web/endpoint.ex
plug Plug.Static,
  at: "/ga/js",
  from: {:good_analytics, "priv/static/js"},
  gzip: false
```

Include it in your root layout (recommended install — core script + fingerprint self-load):

```html
<script src="/ga/js/good-analytics.js"></script>
<script>
  GoodAnalytics.init({
    endpoint: "/ga/t",
    fingerprint: true
  });
</script>
```

`fingerprint: true` self-loads `thumbmark.js` from the same tracking-host JS base path as `good-analytics.js` (derived from the script `src`, so cross-origin embeds work). Self-load is non-blocking: the initial pageview is not delayed for Thumbmark or vendor fingerprint generation. If the Thumbmark script fails to load (CSP, network, or host policy), the client logs a warning and continues without a live fingerprint.

**CSP:** hosts that use `fingerprint: true` must allow scripts from the tracking host in `script-src` (same host as `good-analytics.js`), because the client may inject `thumbmark.js` and the Thumbmark module may inject `vendor/thumbmark.umd.js`.

**Advanced (explicit two-script install):** the two-script + `.use(ThumbmarkModule)` path remains supported and is idempotent with `fingerprint: true` (no double-init):

```html
<script src="/ga/js/good-analytics.js"></script>
<script src="/ga/js/thumbmark.js"></script>
<script>
  GoodAnalytics.use(ThumbmarkModule).init({ endpoint: "/ga/t" });
</script>
```

**JS Client options:**

| Option | Default | Description |
|--------|---------|-------------|
| `endpoint` | — | Path to the tracking beacon endpoint |
| `fingerprint` | — | `true` self-loads Thumbmark from the tracking host (non-blocking, after first pageview); a string is a precomputed fingerprint applied **before** the first pageview (no self-load) |
| `clientAnonymousId` | `false` | Mint and persist a durable client-side anonymous id (non-HttpOnly cookie + localStorage) |
| `autoSpaNavigation` | `true` | Automatically track SPA navigation (pushState, popstate, hashchange) |

Disable automatic SPA tracking if your app sends manual pageviews:

```html
<script>GoodAnalytics.init({ endpoint: "/ga/t", autoSpaNavigation: false });</script>
```

Every beacon payload includes a UUIDv4 `event_id` idempotency key that host applications can use for retry deduplication.

### Privacy: `GoodAnalytics.forget()`

Call `GoodAnalytics.forget()` on the client to purge all **client-accessible, library-owned** identity state. It best-effort expires non-HttpOnly cookies the library can write and clears matching localStorage keys and in-memory fields:

| Surface | Cleared? |
|---------|----------|
| Identity cookie (`_ga_good`) | Yes (best-effort; expires with `path=/;SameSite=Lax` and `Secure` on HTTPS) |
| Referral cookie (`_ga_ref`) | Yes |
| Identity localStorage (`_ga_good_id`) | Yes |
| Fingerprint localStorage (`_ga_good_fp`) + in-memory fingerprint | Yes |
| Client-anon cookie (`_ga_good_anon`) + storage (`_ga_good_anon_id`) + memory | Yes |
| Click dedup sessionStorage (`_ga_click_*`) | Yes |
| Server-owned HttpOnly `_ga_anon` | **No** — not readable/deletable from JS |

After `forget()`, `setFingerprint` no-ops for the rest of the page lifecycle (in-memory suppress only; a full page reload lifts it). Client `forget()` is complementary to server `GoodAnalytics.forget_visitor/1` (which clears server-side visitor fingerprints and related state). On same-origin installs, post-forget beacons may still include HttpOnly `_ga_anon` until the server cookie is expired or rotated — call server `forget_visitor/1` for a full continuity break. Client `forget()` does not permanently prevent browser fingerprint recomputation after reload when a fingerprint module remains installed.

## Database Migrations

GoodAnalytics owns its schema. Versioned SQL lives in the library at `priv/good_analytics/sql/versions/` and is applied through [EctoEvolver](https://hex.pm/packages/ecto_evolver). Your host app does not copy or edit that SQL — it adds thin Ecto migrations that delegate to `GoodAnalytics.Migration.up/0` and `GoodAnalytics.Migration.down/0`.

All `ga_*` tables live in a dedicated PostgreSQL schema (default `good_analytics`, configurable via `:schema_prefix`). EctoEvolver tracks which library versions have been applied via a comment on the `ga_version` view, so each migration only runs pending versions.

### Prerequisites

The Mix tasks read your host app's first configured Ecto repo from `:ecto_repos`:

```elixir
# config/config.exs
config :my_app, ecto_repos: [MyApp.Repo]

config :good_analytics,
  repo: MyApp.Repo
```

Migrations are written to `priv/<repo_underscored>/migrations/` (for `MyApp.Repo`, that is `priv/repo/migrations/`).

### First-time setup

Generate the bootstrap migration:

```bash
mix good_analytics.setup
mix ecto.migrate
```

`mix good_analytics.setup` creates a single `*_setup_good_analytics.exs` file:

```elixir
defmodule MyApp.Repo.Migrations.SetupGoodAnalytics do
  use Ecto.Migration

  def up do
    GoodAnalytics.Migration.up()
    GoodAnalytics.PartitionManager.ensure_initial_partitions()
  end

  def down, do: GoodAnalytics.Migration.down()
end
```

The setup task is idempotent — re-running it skips generation if a setup migration already exists. If you accidentally have more than one `*_setup_good_analytics.exs` file, delete the extras and re-run `mix ecto.migrate`.

`PartitionManager.ensure_initial_partitions/0` pre-creates the current and upcoming monthly partitions for `ga_events` so ingest works immediately. A background GenServer continues to maintain partitions after boot.

### Upgrading after a library update

When you bump the `good_analytics` dependency and a new EctoEvolver version ships (v05, v06, etc.), generate a new host-app migration:

```bash
mix good_analytics.gen.migration
mix ecto.migrate
```

This creates an `*_update_good_analytics.exs` file that calls the same `up/0` and `down/0` functions. EctoEvolver compares the version comment on `ga_version` against its version list and applies only what is missing — existing databases skip already-applied versions.

You can also create the migration manually:

```elixir
defmodule MyApp.Repo.Migrations.UpdateGoodAnalytics do
  use Ecto.Migration

  def up, do: GoodAnalytics.Migration.up()
  def down, do: GoodAnalytics.Migration.down()
end
```

Run it with your normal Ecto workflow (`mix ecto.migrate`, release tasks, CI, etc.). GoodAnalytics schema changes ride alongside your own migrations in `schema_migrations`; only the SQL execution is library-owned.

### Fresh dev environments

A common host-app alias chains your own migrations with the library setup:

```elixir
# mix.exs
defp aliases do
  [
    "ecto.setup": [
      "ecto.create",
      "ecto.migrate",
      "good_analytics.setup",
      "ecto.migrate",
      "run priv/repo/seeds.exs"
    ]
  ]
end
```

Run your app's migrations first so shared prerequisites exist, then generate and apply the GoodAnalytics migration.

### Custom schema prefix

If you use a non-default schema name, set it before generating or running migrations:

```elixir
config :good_analytics, schema_prefix: "my_analytics"
```

EctoEvolver substitutes `$SCHEMA$` in the library SQL files with this value. Query with the matching prefix in application code:

```elixir
MyApp.Repo.all(Visitor, prefix: "my_analytics")
```

### Checking the applied version

To see which library schema version is on your database:

```sql
SELECT obj_description('good_analytics.ga_version'::regclass);
-- → 'GoodAnalytics version=12'
```

Replace `good_analytics` with your `:schema_prefix` if customized.

### Background flows (PgFlow)

GoodAnalytics depends on `{:pgflow, "~> 0.5.0"}` and defines four flows: `GoodAnalytics.Flows.CreatePartitions`, `GoodAnalytics.Flows.ConnectorPlanning`, `GoodAnalytics.Flows.ConnectorDelivery`, and `GoodAnalytics.Flows.ConnectorReconciliation`. They run only when your application supervises PgFlow and registers them:

```elixir
{PgFlow,
 repo: MyApp.Repo,
 flows: [
   GoodAnalytics.Flows.CreatePartitions,
   GoodAnalytics.Flows.ConnectorPlanning,
   GoodAnalytics.Flows.ConnectorDelivery,
   GoodAnalytics.Flows.ConnectorReconciliation
 ]}
```

Without a running `PgFlow.Supervisor`, partition creation falls back to direct SQL, and connector planning falls back to a supervised local task (it is skipped inside an open transaction).

If your application runs `PgFlow.Supervisor` but has not registered the GoodAnalytics flows, GoodAnalytics still routes partition creation and connector work through PgFlow. Partition creation falls back to direct SQL when `PgFlow.start_flow/2` returns an error. Connector planning falls back to a local task on an error only outside a database transaction; when the call is made inside an open transaction, planning is skipped. A host that runs PgFlow should therefore register all four `GoodAnalytics.Flows.*` modules.

PgFlow 0.5 workers require the PgFlow core schema at version 2 and helpers at version 6; verify with `mix pgflow.check_schema --repo MyApp.Repo`. If your database was set up for an earlier GoodAnalytics build on PgFlow 0.4, stop every PgFlow 0.4 worker first, then run `mix pgflow.setup --upgrade --repo MyApp.Repo` and `mix ecto.migrate` before starting 0.5 workers. There is no mixed-version rolling upgrade.

### What not to do

- Do not edit files under `deps/good_analytics/priv/good_analytics/sql/` — changes are lost on the next `mix deps.get`.
- Do not hand-roll DDL for `ga_*` tables in host-app migrations — add a version in the library instead.
- Do not generate multiple setup migrations; use `mix good_analytics.gen.migration` for subsequent upgrades.

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

### Server-Side Tracking In Phoenix Controllers

`GoodAnalytics.track/3` expects a resolved visitor. In Phoenix, resolve the
visitor from the tracking signals assigned by `GoodAnalytics.Core.Tracking.Plug`,
then pass that visitor to `track/3`, `track_lead/3`, or `track_sale/3`.

For browser `GET` requests that pass through the tracking plug:

```elixir
def show(conn, _params) do
  workspace_id = conn.assigns.workspace_id || GoodAnalytics.default_workspace_id()

  {:ok, visitor} =
    GoodAnalytics.resolve_visitor(conn.assigns.ga_signals,
      workspace_id: workspace_id
    )

  {:ok, _event} =
    GoodAnalytics.track(visitor, "custom", %{
      event_name: "Viewed Dashboard",
      url: Phoenix.Controller.current_url(conn)
    })

  render(conn, :show)
end
```

For `POST` requests or controller actions that may not run the tracking plug,
build signals from the GoodAnalytics cookies:

```elixir
def create(conn, params) do
  conn = Plug.Conn.fetch_cookies(conn)
  workspace_id = conn.assigns.workspace_id || GoodAnalytics.default_workspace_id()

  signals = %{
    ga_id: conn.cookies["_ga_good"],
    anonymous_id: conn.cookies["_ga_anon"],
    source: conn.assigns[:ga_source]
  }

  {:ok, visitor} =
    GoodAnalytics.resolve_visitor(signals, workspace_id: workspace_id)

  {:ok, _event} =
    GoodAnalytics.track(visitor, "custom", %{
      event_name: "Submitted Form",
      properties: params
    })

  redirect(conn, to: ~p"/thanks")
end
```

If the user is authenticated, identify the visitor before recording the event:

```elixir
{:ok, visitor} =
  GoodAnalytics.identify(visitor, %{
    person_external_id: to_string(conn.assigns.current_scope.user.id),
    person_email: conn.assigns.current_scope.user.email
  })

GoodAnalytics.track(visitor, "lead", %{url: Phoenix.Controller.current_url(conn)})
```

The server-side flow is:

```text
conn/cookies -> signals -> GoodAnalytics.resolve_visitor/2 -> visitor -> GoodAnalytics.track/3
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

### REST API

The REST API provides server-side access to events, links, and visitors. All requests require a `Bearer` token or `X-Api-Key` header. The workspace is derived from the auth callback response — it never appears in the URL.

#### Events

```bash
# Record a single event
curl -X POST /ga/api/events \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"visitor_id": "uuid", "event_type": "sale", "amount_cents": 4999, "currency": "USD"}'
# => 201 {"event_id": "uuid"}

# Idempotent submission (returns 200 if key already used)
curl -X POST /ga/api/events \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"visitor_id": "uuid", "event_type": "sale", "idempotency_key": "order-123"}'

# Batch events (up to 100, partial success returns 207)
curl -X POST /ga/api/events/batch \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"events": [
    {"visitor_id": "uuid-1", "event_type": "sale", "amount_cents": 100},
    {"person_external_id": "cust_123", "event_type": "lead"}
  ]}'
# => 201 {"results": [{"index": 0, "status": "ok", "event_id": "..."}, ...]}
```

Visitor resolution: pass `visitor_id` (UUID, direct lookup) or `person_external_id` (resolved via workspace). If both are provided, `visitor_id` takes precedence. Returns 404 if the visitor is not found — server-side events never create visitors implicitly.

#### Links

```bash
# Create a link
curl -X POST /ga/api/links \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"domain": "mybrand.link", "key": "promo", "url": "https://example.com/sale"}'
# => 201 {"id": "uuid", "domain": "mybrand.link", ...}

# List links (paginated)
curl /ga/api/links?limit=10&offset=0 -H "Authorization: Bearer $TOKEN"

# Get / Update / Archive a link
curl /ga/api/links/:id -H "Authorization: Bearer $TOKEN"
curl -X PATCH /ga/api/links/:id -d '{"url": "https://new.com"}' ...
curl -X DELETE /ga/api/links/:id ...   # => 204 (soft delete)

# Link analytics
curl /ga/api/links/:id/stats ...
# => {"total_clicks": 42, "unique_clicks": 38, "total_leads": 5, "total_sales": 2, "total_revenue_cents": 9800}

curl /ga/api/links/:id/clicks?limit=20 ...
```

#### Visitors

```bash
# List visitors (excludes merged, paginated)
curl /ga/api/visitors?limit=20&offset=0 -H "Authorization: Bearer $TOKEN"

# Get by ID or external ID
curl /ga/api/visitors/:id ...
curl /ga/api/visitors/by-external-id/cust_123 ...

# Timeline and attribution
curl /ga/api/visitors/:id/timeline ...
curl /ga/api/visitors/:id/attribution ...
# => {"attribution_path": [...], "first_source": {...}, "last_source": {...}, ...}
```

#### Authentication

| Header | Type | Example |
|--------|------|---------|
| `Authorization` | Bearer token | `Authorization: Bearer sk_live_abc123` |
| `X-Api-Key` | API key | `X-Api-Key: gak_abc123` |

If both headers are present, Bearer takes precedence. Error responses:

| Status | Condition |
|--------|-----------|
| 401 | Missing/invalid credentials, or `{:error, :unauthorized}` from callback |
| 403 | `{:error, :forbidden}` from callback |
| 503 | `:api_authenticate` config not set |

#### Configuration Reference

| Key | Required | Description |
|-----|----------|-------------|
| `:api_authenticate` | Yes | `{Module, :function}` tuple or `fn token, type -> result end` |

The callback receives `(token, type)` where `type` is `:bearer` or `:api_key`. Must return `{:ok, %{workspace_id: uuid, ...}}` or `{:error, reason}`.

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
| `mix good_analytics.setup` | Generate the initial `*_setup_good_analytics.exs` migration (first install only) |
| `mix good_analytics.gen.migration` | Generate an `*_update_good_analytics.exs` migration for pending library versions |
| `mix ua_inspector.download` | Download UA detection databases |
| `mix setup` | Run `deps.get` + `ua_inspector.download` |

See [Database Migrations](#database-migrations) for when to use each task and how they fit into `mix ecto.migrate`.

## Testing

### Running the Test Suite

```bash
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

## License

MIT
