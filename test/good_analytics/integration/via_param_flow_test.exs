defmodule GoodAnalytics.Integration.ViaParamFlowTest do
  @moduledoc """
  OpenSpec 12.4: Via param flow integration test.

  Tests: visit with ?via=john -> source classification -> client click
  endpoint -> verify visitor + event created.
  """
  use GoodAnalytics.DataCase, async: false

  alias GoodAnalytics.Core.Links
  alias GoodAnalytics.Core.Tracking.BeaconController
  alias GoodAnalytics.Core.Tracking.SourceClassifier

  import Plug.Test

  defp build_beacon_conn(params) do
    conn(:post, "/ga/t/click", params)
    |> Map.put(:host, "test.link")
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("user-agent", "ViaTest/1.0")
    |> Plug.Conn.assign(:ga_source, nil)
    |> Plug.Conn.put_private(:phoenix_format, "json")
  end

  describe "via param source classification" do
    test "via param classifies source with partner_code" do
      conn =
        conn(:get, "/page?via=john")
        |> Plug.Conn.fetch_query_params()
        |> Plug.Conn.put_req_header("user-agent", "ViaTest/1.0")

      source = SourceClassifier.classify(conn)
      assert source[:partner_code] == "john"
    end

    test "ref param classifies source with partner_code" do
      conn =
        conn(:get, "/page?ref=partner123")
        |> Plug.Conn.fetch_query_params()
        |> Plug.Conn.put_req_header("user-agent", "ViaTest/1.0")

      source = SourceClassifier.classify(conn)
      assert source[:partner_code] == "partner123"
    end
  end

  describe "client click endpoint" do
    test "click creates visitor and returns ga_id" do
      _link = create_link!(%{domain: "test.link", key: "john"})

      conn = build_beacon_conn(%{"key" => "john", "fingerprint" => "fp_via_test"})
      result = BeaconController.click(conn, %{"key" => "john", "fingerprint" => "fp_via_test"})

      body = Jason.decode!(result.resp_body)
      assert body["status"] == "ok"
      assert {:ok, _} = Ecto.UUID.cast(body["ga_id"])
      assert body["visitor_id"]
    end

    test "click records link_click event" do
      link =
        create_link!(%{
          domain: "test.link",
          key: "click_rec_#{System.unique_integer([:positive])}"
        })

      conn = build_beacon_conn(%{"key" => link.key, "fingerprint" => "fp_click_rec"})
      BeaconController.click(conn, %{"key" => link.key, "fingerprint" => "fp_click_rec"})

      clicks = Links.link_clicks(link.id)
      assert [_ | _] = clicks
      assert hd(clicks).event_type == "link_click"
    end

    test "click increments link rollups and broadcasts live click message" do
      link =
        create_link!(%{
          domain: "test.link",
          key: "click_rollup_#{System.unique_integer([:positive])}"
        })

      Phoenix.PubSub.subscribe(
        GoodAnalytics.PubSub,
        "good_analytics:link_clicks:#{link.workspace_id}"
      )

      conn = build_beacon_conn(%{"key" => link.key, "fingerprint" => "fp_click_rollup"})
      BeaconController.click(conn, %{"key" => link.key, "fingerprint" => "fp_click_rollup"})

      link_id = link.id
      updated = Links.get_link(link.id)
      assert updated.total_clicks == 1
      assert updated.unique_clicks == 1
      assert_receive {:link_click, ^link_id, true}
    end

    test "click returns 404 for nonexistent link key" do
      conn = build_beacon_conn(%{"key" => "nonexistent_via"})
      result = BeaconController.click(conn, %{"key" => "nonexistent_via"})
      assert result.status == 404
    end
  end
end
