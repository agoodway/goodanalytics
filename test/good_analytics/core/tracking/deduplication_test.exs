defmodule GoodAnalytics.Core.Tracking.DeduplicationTest do
  use ExUnit.Case, async: false

  alias GoodAnalytics.Core.Links.Link
  alias GoodAnalytics.Core.Tracking.Deduplication

  defp build_conn(ip) do
    %Plug.Conn{remote_ip: ip}
  end

  defp build_link(id \\ Uniq.UUID.uuid7()) do
    %Link{id: id}
  end

  describe "check/2" do
    test "returns {:ok, true} for first click from IP" do
      conn = build_conn({10, 0, System.unique_integer([:positive]) |> rem(256), 1})
      link = build_link()
      assert {:ok, true} = Deduplication.check(conn, link)
    end

    test "returns {:ok, false} for duplicate click from same IP" do
      ip = {10, 1, System.unique_integer([:positive]) |> rem(256), 1}
      conn = build_conn(ip)
      link = build_link()

      assert {:ok, true} = Deduplication.check(conn, link)
      assert {:ok, false} = Deduplication.check(conn, link)
    end

    test "different IPs are independent" do
      link = build_link()
      conn_a = build_conn({10, 2, System.unique_integer([:positive]) |> rem(256), 1})
      conn_b = build_conn({10, 3, System.unique_integer([:positive]) |> rem(256), 1})

      assert {:ok, true} = Deduplication.check(conn_a, link)
      assert {:ok, true} = Deduplication.check(conn_b, link)
    end

    test "different links from same IP are independent" do
      ip = {10, 4, System.unique_integer([:positive]) |> rem(256), 1}
      conn = build_conn(ip)

      assert {:ok, true} = Deduplication.check(conn, build_link())
      assert {:ok, true} = Deduplication.check(conn, build_link())
    end
  end
end
