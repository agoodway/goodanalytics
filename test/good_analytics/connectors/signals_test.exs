defmodule GoodAnalytics.Connectors.SignalsTest do
  use ExUnit.Case, async: true

  alias GoodAnalytics.Connectors.Signals

  describe "all_signal_keys/0" do
    test "includes all recognized signals" do
      keys = Signals.all_signal_keys()
      assert "fbclid" in keys
      assert "gclid" in keys
      assert "gbraid" in keys
      assert "wbraid" in keys
      assert "li_fat_id" in keys
      assert "ttclid" in keys
      assert "_fbp" in keys
      assert "_fbc" in keys
    end
  end

  describe "extract_from_payload/1" do
    test "extracts recognized signals from payload" do
      payload = %{
        "_fbp" => "fb.1.1234567890.1234567890",
        "_fbc" => "fb.1.1234567890.abc123",
        "fbclid" => "click_abc",
        "event_type" => "pageview",
        "url" => "https://example.com"
      }

      signals = Signals.extract_from_payload(payload)
      assert signals["_fbp"] == "fb.1.1234567890.1234567890"
      assert signals["_fbc"] == "fb.1.1234567890.abc123"
      assert signals["fbclid"] == "click_abc"
      refute Map.has_key?(signals, "event_type")
      refute Map.has_key?(signals, "url")
    end

    test "skips nil and empty values" do
      payload = %{"_fbp" => nil, "_fbc" => "", "gclid" => "abc"}
      signals = Signals.extract_from_payload(payload)
      assert signals == %{"gclid" => "abc"}
    end

    test "returns empty map for payload with no signals" do
      assert Signals.extract_from_payload(%{"url" => "https://example.com"}) == %{}
    end
  end

  describe "merge/1" do
    test "merges multiple signal maps" do
      server = %{"fbclid" => "click1", "_fbp" => "fb.1.old"}
      js = %{"_fbp" => "fb.1.new", "_fbc" => "fb.1.abc"}

      merged = Signals.merge([server, js])
      assert merged["fbclid"] == "click1"
      # JS-supplied values take precedence (later source)
      assert merged["_fbp"] == "fb.1.new"
      assert merged["_fbc"] == "fb.1.abc"
    end

    test "filters out nil and empty values" do
      signals = Signals.merge([%{"_fbp" => "fb.1.123", "gclid" => nil}])
      assert signals == %{"_fbp" => "fb.1.123"}
    end
  end

  describe "build_source_context/2" do
    test "builds context with signals and metadata" do
      signals = %{"_fbp" => "fb.1.123", "fbclid" => "abc"}

      ctx =
        Signals.build_source_context(signals,
          visitor_id: "visitor-123",
          event_type: "lead",
          source: %{"platform" => "meta"}
        )

      assert ctx["signals"] == signals
      assert ctx["visitor_id"] == "visitor-123"
      assert ctx["event_type"] == "lead"
      assert ctx["source"] == %{"platform" => "meta"}
      assert is_binary(ctx["captured_at"])
    end

    test "omits nil values" do
      ctx = Signals.build_source_context(%{"gclid" => "abc"})
      refute Map.has_key?(ctx, "visitor_id")
      refute Map.has_key?(ctx, "amount_cents")
    end
  end

  describe "has_required_signals?/2" do
    test "returns true when required signals are present" do
      signals = %{"_fbp" => "fb.1.123"}
      assert Signals.has_required_signals?(signals, [["_fbp", "_fbc", "fbclid"]])
    end

    test "returns true with any signal from group" do
      signals = %{"fbclid" => "abc"}
      assert Signals.has_required_signals?(signals, [["_fbp", "_fbc", "fbclid"]])
    end

    test "returns false when no signals from a group are present" do
      signals = %{"gclid" => "abc"}
      refute Signals.has_required_signals?(signals, [["_fbp", "_fbc", "fbclid"]])
    end

    test "returns true with empty required groups" do
      assert Signals.has_required_signals?(%{}, [])
    end

    test "handles multiple groups (AND of ORs)" do
      signals = %{"_fbp" => "fb.1.123", "gclid" => "abc"}
      # Both groups satisfied
      assert Signals.has_required_signals?(signals, [
               ["_fbp", "fbclid"],
               ["gclid", "gbraid"]
             ])

      # Second group not satisfied
      refute Signals.has_required_signals?(%{"_fbp" => "fb.1.123"}, [
               ["_fbp", "fbclid"],
               ["gclid", "gbraid"]
             ])
    end

    test "empty string values don't count as present" do
      signals = %{"_fbp" => ""}
      refute Signals.has_required_signals?(signals, [["_fbp"]])
    end
  end
end
