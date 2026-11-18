# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project will adhere to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches `1.0.0`. Until then, breaking changes may land in any release.

## [0.3.1] - 2026-11-18

### Changed

- Drops the unused `livefilter` dependency. It was declared as a required
  dependency (`~> 0.2.0`) but nothing in GoodAnalytics references it, and the
  pin blocked hosts from using LiveFilter 0.3. Hosts that mount the PgFlow
  dashboard should add `livefilter` to their own dependencies.

## [0.3.0] - 2026-11-11

Database schema version 15. Hosts need a new migration wrapper calling
`GoodAnalytics.Migration.up(version: 15)` (`down(version: 14)`); on very large
tables schedule it for a quiet period.

### Changed (review before upgrading)

Stored historical rows are not rewritten (except the `'nil'` repair below);
`Referers.canonical_platform/1` maps old platform spellings to the new ones.

- **Platform atoms renamed:** `fbclid` click id `:meta` -> `:facebook`;
  `:duckai` -> `:duck_ai`; `mail.zoho.com` `:zoho_mail` -> `:zoho`; `e.mail.ru`
  `:mailru` -> `:mail_ru`; `mail.yandex.ru`/`.com` `:yandex_mail` -> `:yandex`.
  A `utm_source` of a known platform is now its canonical atom instead of the
  raw string (`"twitter"` -> `:twitter`, `"linkedin"` -> `:linkedin`). Unknown
  sources stay raw strings.
- **Messaging is social:** `web.whatsapp.com`, `web.telegram.org`, `slack.com`,
  `app.slack.com`, `discord.com` and Microsoft Teams hosts moved from medium
  `:messaging` to `:social` (GA4 has no messaging channel).
- **`you.com` is a chatbot** (medium `:ai`), pinned in the supplement.
- **Free-text referers are direct:** a referer that is not a URL or hostname
  classifies as direct instead of a referral with a junk `referer_domain`.
  Protocol-relative referers (`//host/x`) now resolve. IDN and IPv6-literal
  referers also classify as direct.
- **`link_click` fingerprint backfill is narrower:** for a returning visitor on
  an owned destination the redirect hands off the visitor's persistent `ga_id`
  instead of the per-click id, so the beacon `ga_id` no longer equals the
  `link_click` `click_id` and the fingerprint backfill does not match. New
  visitors still match. Returning visitors are already identified by cookie.
- `utm_campaign` alone no longer yields `"unknown"` (see Source
  classification).
- **The `:referer_map` override now extends** the vendored referrer data (exact
  domains first) instead of replacing it.
- **Internal navigation moves from Referral to Direct** in event-level
  breakdowns: a visit whose referer is the site's own host now records no source
  (NULL `source_platform`/`source_medium`). Session-level breakdowns are
  unchanged.
- **`neq`/`not_in` filters on `source_medium` now include events with no
  medium**, because a missing medium counts as `direct` for the equality and
  membership operators (`eq`, `neq`, `in`, `not_in`) at both event and session
  grain; `ilike` still compares the raw column.
- **The `:link_click` hook's `source` can be `nil`** (internal navigation or an
  ignored hand-off host). Hooks must handle a missing source.
- **`BeaconController` honours an upstream-assigned `nil` source** (a host plug
  that assigns `:ga_source` as `nil` means "no source"); it only classifies
  itself when nothing was assigned.
- **`attribution_path` can hold consecutive duplicate email touchpoints:** the
  newsletter link click and the landing pageview that carries the same UTMs
  each add an email touchpoint.
- **A campaign-only UTM on internal navigation returns `nil`**, so that
  campaign is not kept.

### Added

- **Source classification from a vendored referrer database.**
  `SourceClassifier` classifies referers, `utm_source` names and display names
  from `priv/referers/referers.yml` instead of hand-coded host maps. It merges
  the hand-kept supplement (`good_analytics_referers.yml`), the Snowplow
  referer-parser database and the Matomo searchengine-and-social-list, in that
  precedence order. Search engines, Google country domains, webmail, ISP
  webmail, Android app packages and AI assistants resolve; unlisted hosts stay
  `:referral` with `referer_domain` kept.
- `mix good_analytics.referers.update [--snowplow-ref SHA] [--matomo-ref SHA] [--dry-run]`
  refreshes the vendored data. Added `{:yamerl, "~> 0.10"}` as an explicit
  dependency (already pulled in by `ua_inspector`).
- `GoodAnalytics.Core.Tracking.Referers`: `lookup/1` (exact host, then parent
  domains, never a bare TLD), `resolve/1`, `canonical_platform/1` and `name/1`.
- **Internal navigation is not a source.** `SourceClassifier.classify/2`
  returns `nil` when the referer is on the page's own host (`www.` and port
  ignored) or a host in `config :good_analytics, internal_hosts: [...]`, unless
  a click id, `via`/`ref` param or UTM is present. List ALL of a site's own
  domains in `internal_hosts`, short-link domains included. Payment and sign-in
  hand-off hosts (such as `checkout.stripe.com`) also classify to `nil`.
  New `SourceClassifier.internal_referer?/2` and `classify_beacon/2` (classify
  a tracker payload's `url` + `referrer`).
- **`last_source` keeps the last non-direct source:** a direct visit no longer
  overwrites a real `last_source`, a new real source replaces it, and direct is
  stored when there is no prior source.
- **UTM medium inference:** a `utm_source` with no `utm_medium` gets the medium
  of the known source (`linkedin` -> `:social`, `perplexity` -> `:ai`,
  `newsletter` -> `:email`), else `:referral`. The medium is never `"unknown"`.
- **Campaign-only UTMs** (`utm_campaign`/`content`/`term` with no source or
  medium) keep the campaign while the referer, or direct, supplies platform and
  medium.
- **A link's own UTM tags classify `link_click` events** and the visitor's
  `last_source` when the request has no referer or UTM params (request UTMs
  override link UTMs). The redirect passes `page_host` so same-site referers
  are internal.
- **`GoodAnalytics.Sources`**, the shared source and channel vocabulary:
  `channels/0`, `channel/1` (source map or medium), `channel/2`,
  `channel_name/1` (GA4 names: Organic Search, Organic Social, Paid Search, Paid
  Social, Email, Referral, Direct, AI Assistant, Affiliates, SMS, Organic
  Video, Display, Other), `label/1`, `platform_name/1`, `parse_channel/1`
  (never creates atoms), `mediums/1` (the stored mediums for a channel),
  `channel_sql/1` (a CASE over a table alias), the `channel_fragment/2` macro
  for Ecto queries and `medium_filter/2` (an Ecto condition for filtering
  events by `source_medium`, where a blank medium counts as `direct`). Paid
  mediums split by platform into paid search or paid social. `channel/1` on a
  source map infers a missing or `"unknown"` medium from the platform, and the
  historical medium `"unknown"` maps to a channel by the platform's primary
  medium, otherwise Referral. Generic `utm_source` words (`mail`, `search`,
  `you`, `pi`, `web`, `app`) no longer resolve through the alias table, and
  alias keys shorter than three characters resolve only when the supplement
  lists them (`fb`, `ig`, `li`, `x`); `utm_medium` is trimmed and lowercased.
- **Bot detection in `Devices`.** The generic automation denylist (curl,
  HeadlessChrome, ...) is part of core (`Devices.automation_ua?/1`); a matched
  UA parses to `type "bot"`, the tool name and `bot_category "Automation"`.
  `Devices.parse/1` adds `"bot_category"` (the raw ua_inspector category) and
  `Devices.bot_kind/1` classifies a device as `:ai_crawler`, `:ai_assistant`,
  `:search_crawler`, `:crawler`, `:social_preview`, `:seo_tool`, `:monitoring`
  or `:other`.
- `Link.valid_http_url?/1` and the link changeset reject destination URLs with
  a backslash or userinfo (`user@host`), which parse to one host but navigate
  to another.
- `config :good_analytics, internal_hosts: [...]` (see the README).

### Fixed

- Engagement events (`Recorder`) now store `user_agent` and the device
  attributes, so bots no longer slip through with NULL `bot_name`/`device_type`.
- The browser tracker counts SPA pageviews only when the URL changes:
  `replaceState` or `pushState` to the current URL no longer records a
  pageview, and the initial pageview seeds the last-seen URL.
- The redirect hands a returning visitor's `ga_id` to the destination only when
  the destination is an owned host (the link domain, the request host, or a host
  in `:internal_hosts`). Off-site destinations keep the per-click id.
- The string `'nil'` was stored in `source_platform`/`source_medium`/
  `source_campaign` when there was no source. Schema version 15 repairs
  existing `ga_events` and `ga_sessions` rows (`'nil'` becomes NULL; down is a
  no-op) and touches only rows with the bad value. Session acquisition and
  backfill also treat a stored `"nil"` as no value.
- Drill filters now compare mediums case-insensitively, matching the channel CASE.
