defmodule GoodAnalytics do
  @moduledoc """
  Visitor intelligence, link tracking, source attribution, and behavioral analytics for Phoenix.

  GoodAnalytics is a pluggable Elixir/Phoenix library that adds visitor intelligence,
  link tracking, source attribution, and behavioral analytics to any existing Phoenix
  application.

  ## Configuration

      config :good_analytics,
        repo: MyApp.Repo,
        links: [domains: ["mybrand.link"]]

  """

  alias GoodAnalytics.Core.Events
  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Tracking.ShareLinks
  alias GoodAnalytics.Core.Visitors
  alias GoodAnalytics.Hooks

  @default_workspace_id "00000000-0000-0000-0000-000000000000"
  @schema_name Application.compile_env(:good_analytics, :schema_prefix, "good_analytics")

  @doc """
  Returns the sentinel workspace UUID for single-tenant library mode.
  """
  @spec default_workspace_id() :: String.t()
  def default_workspace_id, do: @default_workspace_id

  @doc """
  Returns the PostgreSQL schema name used by GoodAnalytics tables.
  """
  def schema_name, do: @schema_name

  # ── Identity ──

  @doc "Resolve tracking signals to a single visitor record."
  def resolve_visitor(signals, opts \\ []) do
    IdentityResolver.resolve(signals, opts)
  end

  @doc "Associate a visitor with the host app's known person attributes."
  def identify(visitor, person_attrs) do
    IdentityResolver.identify(visitor, person_attrs)
  end

  @doc "Update visitor attribution (extension point for GoodPartners)."
  def update_visitor_attribution(visitor_id, attrs) do
    Visitors.update_attribution(visitor_id, attrs)
  end

  @doc "List recent visitors for a workspace."
  def list_visitors(workspace_id, opts \\ []) do
    Visitors.list_visitors(workspace_id, opts)
  end

  # ── Events ──

  @doc "List recent events for a workspace."
  def list_events(workspace_id, opts \\ []) do
    Events.list_events(workspace_id, opts)
  end

  @doc "Get source platform/medium breakdown for a workspace."
  def source_breakdown(workspace_id, opts \\ []) do
    Events.source_breakdown(workspace_id, opts)
  end

  @doc "Record a tracking event."
  def track(visitor, event_type, properties \\ %{}) do
    Recorder.record(visitor, event_type, properties)
  end

  @doc """
  Track a lead (signup).

  Accepts an optional keyword list as the third argument:
    - `:connector_signals` — explicit connector signal overrides
  """
  def track_lead(visitor, person_attrs, opts \\ []) do
    attrs = maybe_add_connector_signals(person_attrs, opts)
    Recorder.record_lead(visitor, attrs)
  end

  @doc """
  Track a sale.

  Accepts an optional keyword list as the third argument:
    - `:connector_signals` — explicit connector signal overrides
  """
  def track_sale(visitor, sale_attrs, opts \\ []) do
    attrs = maybe_add_connector_signals(sale_attrs, opts)
    Recorder.record_sale(visitor, attrs)
  end

  @doc "Get the most recent event of a given type for a visitor."
  def last_event(visitor_id, event_type) do
    Events.last_event(visitor_id, event_type)
  end

  # ── Links ──

  @doc "Create a tracked short link."
  def create_link(attrs), do: Links.create_link(attrs)

  @doc "Get a link by ID."
  def get_link(id), do: Links.get_link(id)

  @doc "Get a link by domain and key."
  def get_link_by_key(domain, key), do: Links.get_link_by_key(domain, key)

  @doc "List links for a workspace."
  def list_links(workspace_id, opts \\ []),
    do: Links.list_links(workspace_id, opts)

  @doc "Update a link."
  def update_link(id, attrs), do: Links.update_link(id, attrs)

  @doc "Archive a link."
  def archive_link(id), do: Links.archive_link(id)

  # ── Link Analytics ──

  @doc "Get aggregated stats for a link."
  def link_stats(link_id, opts \\ []), do: Links.link_stats(link_id, opts)

  @doc "Get click events for a link."
  def link_clicks(link_id, opts \\ []), do: Links.link_clicks(link_id, opts)

  # ── Visitors ──

  @doc "Get a visitor by ID."
  def get_visitor(id), do: Visitors.get_visitor(id)

  @doc "Get a visitor by host-app external ID."
  def get_visitor_by_external_id(workspace_id, person_external_id) do
    Visitors.get_by_external_id(workspace_id, person_external_id)
  end

  @doc "Get the full event timeline for a visitor."
  def visitor_timeline(visitor_id), do: Visitors.timeline(visitor_id)

  @doc "Get the attribution path for a visitor."
  def visitor_attribution(visitor_id), do: Visitors.attribution(visitor_id)

  @doc "Update visitor lifecycle status."
  def update_visitor_status(visitor_id, status) do
    Visitors.update_status(visitor_id, status)
  end

  # ── Shares ──

  @doc "Generate social share URLs for a short link."
  def share_urls(short_link, opts \\ []) do
    ShareLinks.all_share_urls(short_link, opts)
  end

  # ── Data Deletion ──

  @doc "Remove all PII, events, and identity signals for a visitor (GDPR)."
  def forget_visitor(visitor_id), do: Visitors.forget(visitor_id)

  # ── Conversions (deprecated — use track_lead/track_sale with opts) ──

  @doc false
  @deprecated "Use track_lead/3 with connector_signals opt instead"
  def submit_lead(visitor, attrs \\ %{}, opts \\ []) do
    track_lead(visitor, attrs, opts)
  end

  @doc false
  @deprecated "Use track_sale/3 with connector_signals opt instead"
  def submit_sale(visitor, attrs \\ %{}, opts \\ []) do
    track_sale(visitor, attrs, opts)
  end

  # ── Hooks ──

  @doc "Register a callback for an event type."
  def register_hook(event_type, callback), do: Hooks.register(event_type, callback)

  # ── Private ──

  defp maybe_add_connector_signals(attrs, opts) do
    case Keyword.get(opts, :connector_signals) do
      nil -> attrs
      signals -> Map.put(attrs, :connector_signals, signals)
    end
  end
end
