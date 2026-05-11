defmodule GoodAnalytics.TestHelpers do
  @moduledoc """
  Shared factory and helper functions for GoodAnalytics tests.
  """

  alias GoodAnalytics.Core.Events.Recorder
  alias GoodAnalytics.Core.IdentityResolver
  alias GoodAnalytics.Core.Visitors.Visitor

  @workspace_id GoodAnalytics.default_workspace_id()

  def default_workspace_id, do: @workspace_id

  @doc """
  Creates a link via `GoodAnalytics.create_link/1`. Raises on failure.
  Generates a unique key by default.
  """
  def create_link!(attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          domain: "test.link",
          key: "k#{System.unique_integer([:positive])}",
          url: "https://example.com"
        },
        attrs
      )

    {:ok, link} = GoodAnalytics.create_link(attrs)
    link
  end

  @doc """
  Creates a visitor directly via Repo.insert!.
  Sets workspace_id and timestamps by default.
  """
  def create_visitor!(attrs \\ %{}) do
    now = DateTime.utc_now()

    attrs =
      Map.merge(
        %{
          workspace_id: @workspace_id,
          first_seen_at: now,
          last_seen_at: now
        },
        attrs
      )

    %Visitor{id: Uniq.UUID.uuid7()}
    |> Visitor.changeset(attrs)
    |> GoodAnalytics.Repo.repo().insert!(prefix: "good_analytics")
  end

  @doc """
  Resolves a visitor via IdentityResolver. Raises on error.
  """
  def resolve_visitor!(signals, opts \\ []) do
    opts = Keyword.put_new(opts, :workspace_id, @workspace_id)

    case IdentityResolver.resolve(signals, opts) do
      {:ok, visitor} -> visitor
      {:error, reason} -> raise "resolve_visitor! failed: #{inspect(reason)}"
    end
  end

  @doc """
  Records an event via Recorder. Raises on error.
  """
  def record_event!(visitor, event_type, attrs \\ %{}) do
    case Recorder.record(visitor, event_type, attrs) do
      {:ok, event} -> event
      {:error, reason} -> raise "record_event! failed: #{inspect(reason)}"
    end
  end
end
