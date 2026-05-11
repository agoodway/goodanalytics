defmodule GoodAnalytics.SchemaVerificationTest do
  @moduledoc """
  OpenSpec 2.10: Verify all tables, indexes, constraints, and partitions
  are created correctly in the good_analytics schema.
  """
  use GoodAnalytics.DataCase, async: false

  @schema "good_analytics"

  # -- SQL Helpers --

  defp table_exists?(table) do
    %{num_rows: n} =
      GoodAnalytics.TestRepo.query!(
        "SELECT 1 FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2",
        [@schema, table]
      )

    n > 0
  end

  defp column_info(table) do
    %{rows: rows} =
      GoodAnalytics.TestRepo.query!(
        """
        SELECT column_name, data_type, is_nullable
        FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2
        ORDER BY ordinal_position
        """,
        [@schema, table]
      )

    Enum.map(rows, fn [name, type, nullable] -> {name, type, nullable} end)
  end

  defp column_names(table) do
    column_info(table) |> Enum.map(fn {name, _, _} -> name end)
  end

  defp index_names(table) do
    %{rows: rows} =
      GoodAnalytics.TestRepo.query!(
        "SELECT indexname FROM pg_indexes WHERE schemaname = $1 AND tablename = $2",
        [@schema, table]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp check_constraints(table) do
    %{rows: rows} =
      GoodAnalytics.TestRepo.query!(
        """
        SELECT con.conname
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
        WHERE nsp.nspname = $1
          AND rel.relname = $2
          AND con.contype = 'c'
        """,
        [@schema, table]
      )

    Enum.map(rows, fn [name] -> name end)
  end

  defp has_partition?(parent, child) do
    %{num_rows: n} =
      GoodAnalytics.TestRepo.query!(
        """
        SELECT 1
        FROM pg_class c
        JOIN pg_inherits i ON c.oid = i.inhrelid
        WHERE i.inhparent = ($1 || '.' || $2)::regclass
          AND c.relname = $3
        """,
        [@schema, parent, child]
      )

    n > 0
  end

  # -- Tests --

  describe "ga_visitors" do
    test "table exists with all expected columns" do
      assert table_exists?("ga_visitors")

      cols = column_names("ga_visitors")

      expected = ~w(
        id workspace_id fingerprints anonymous_ids click_ids ga_id
        person_external_id person_email person_name person_metadata
        first_source first_click_id first_partner_id first_seen_at
        last_source last_click_id last_partner_id last_seen_at
        attribution_path click_id_params geo device
        total_sessions total_pageviews total_events total_time_seconds
        avg_scroll_depth top_pages lead_quality_score fraud_risk_score
        status merged_into_id identified_at converted_at ltv_cents
        inserted_at updated_at
      )

      for col <- expected do
        assert col in cols, "Missing column: #{col}"
      end
    end

    test "has all expected indexes" do
      indexes = index_names("ga_visitors")

      expected = ~w(
        ga_visitors_pkey
        idx_ga_visitors_fingerprints
        idx_ga_visitors_anonymous_ids
        idx_ga_visitors_click_ids
        idx_ga_visitors_ga_id
        idx_ga_visitors_person_external_id
        idx_ga_visitors_workspace
        idx_ga_visitors_status
        idx_ga_visitors_first_seen
        idx_ga_visitors_merged_into
        idx_ga_visitors_last_seen
        idx_ga_visitors_person_email
      )

      for idx <- expected do
        assert idx in indexes, "Missing index: #{idx}"
      end
    end

    test "has CHECK constraint on status" do
      constraints = check_constraints("ga_visitors")
      assert "chk_visitor_status" in constraints
    end
  end

  describe "ga_events" do
    test "table exists with all expected columns" do
      assert table_exists?("ga_events")

      cols = column_names("ga_events")

      expected = ~w(
        id workspace_id visitor_id event_type event_name
        link_id click_id url referrer referrer_url
        source_platform source_medium source_campaign source
        fingerprint ip_address user_agent
        amount_cents currency properties inserted_at
      )

      for col <- expected do
        assert col in cols, "Missing column: #{col}"
      end
    end

    test "has default partition" do
      assert has_partition?("ga_events", "ga_events_default")
    end

    test "has all expected indexes on parent" do
      indexes = index_names("ga_events")

      expected = ~w(
        ga_events_pkey
        idx_ga_events_visitor
        idx_ga_events_type
        idx_ga_events_link
        idx_ga_events_workspace
        idx_ga_events_click_id
        idx_ga_events_source
      )

      for idx <- expected do
        assert idx in indexes, "Missing index: #{idx}"
      end
    end

    test "has composite primary key (id, inserted_at)" do
      %{rows: rows} =
        GoodAnalytics.TestRepo.query!(
          """
          SELECT kcu.column_name
          FROM information_schema.table_constraints tc
          JOIN information_schema.key_column_usage kcu
            ON tc.constraint_name = kcu.constraint_name
            AND tc.table_schema = kcu.table_schema
          WHERE tc.table_schema = $1
            AND tc.table_name = $2
            AND tc.constraint_type = 'PRIMARY KEY'
          """,
          [@schema, "ga_events"]
        )

      pk_cols = Enum.map(rows, fn [col] -> col end) |> Enum.sort()
      assert pk_cols == ["id", "inserted_at"]
    end
  end

  describe "ga_links" do
    test "table exists with all expected columns" do
      assert table_exists?("ga_links")

      cols = column_names("ga_links")

      expected = ~w(
        id workspace_id domain key url link_type
        utm_source utm_medium utm_campaign utm_content utm_term
        password_hash expires_at ios_url android_url geo_targeting
        og_title og_description og_image
        total_clicks unique_clicks total_leads total_sales total_revenue_cents
        tags external_id metadata archived_at inserted_at updated_at
      )

      for col <- expected do
        assert col in cols, "Missing column: #{col}"
      end
    end

    test "has all expected indexes" do
      indexes = index_names("ga_links")

      expected = ~w(
        ga_links_pkey
        idx_ga_links_domain_key
        idx_ga_links_workspace
        idx_ga_links_type
        idx_ga_links_metadata
      )

      for idx <- expected do
        assert idx in indexes, "Missing index: #{idx}"
      end
    end

    test "has CHECK constraint on link_type" do
      constraints = check_constraints("ga_links")
      assert "chk_link_type" in constraints
    end
  end

  describe "ga_domains" do
    test "table exists with all expected columns" do
      assert table_exists?("ga_domains")

      cols = column_names("ga_domains")
      expected = ~w(id workspace_id domain verified verified_at default_url inserted_at)

      for col <- expected do
        assert col in cols, "Missing column: #{col}"
      end
    end

    test "has unique constraint on domain" do
      indexes = index_names("ga_domains")
      assert "ga_domains_domain_key" in indexes
    end
  end

  describe "ga_api_keys" do
    test "table exists with all expected columns" do
      assert table_exists?("ga_api_keys")

      cols = column_names("ga_api_keys")

      expected = ~w(
        id workspace_id key_type key_hash key_prefix
        allowed_hostnames name last_used_at expires_at
        inserted_at revoked_at
      )

      for col <- expected do
        assert col in cols, "Missing column: #{col}"
      end
    end

    test "has CHECK constraint on key_type" do
      constraints = check_constraints("ga_api_keys")
      assert "chk_key_type" in constraints
    end

    test "has unique partial index on key_hash" do
      indexes = index_names("ga_api_keys")
      assert "idx_ga_api_keys_hash" in indexes
    end
  end

  describe "ga_settings" do
    test "table exists with all expected columns" do
      assert table_exists?("ga_settings")

      cols = column_names("ga_settings")
      expected = ~w(id workspace_id key value inserted_at updated_at)

      for col <- expected do
        assert col in cols, "Missing column: #{col}"
      end
    end

    test "has unique constraint on (workspace_id, key)" do
      indexes = index_names("ga_settings")
      assert "ga_settings_workspace_id_key_key" in indexes
    end
  end
end
