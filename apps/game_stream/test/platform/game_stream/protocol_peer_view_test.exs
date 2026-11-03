defmodule Platform.GameStream.ProtocolPeerViewTest do
  use ExUnit.Case, async: true

  alias Platform.GameStream.Protocol

  @base %{"session_id" => "s1", "peer_id" => "p1"}

  test "a slot frame parses" do
    assert {:ok, %{session_id: "s1", peer_id: "p1", view: "slot", slot: 3}} =
             Protocol.parse_peer_view(Map.merge(@base, %{"view" => "slot", "slot" => 3}))
  end

  test "slot bounds 0 and 31 are accepted" do
    for slot <- [0, 31],
        do:
          assert(
            {:ok, %{slot: ^slot}} =
              Protocol.parse_peer_view(Map.merge(@base, %{"view" => "slot", "slot" => slot}))
          )
  end

  test "a shared frame parses with a nil slot, absent or nil, extra keys ignored" do
    expected = {:ok, %{session_id: "s1", peer_id: "p1", view: "shared", slot: nil}}
    assert expected == Protocol.parse_peer_view(Map.put(@base, "view", "shared"))

    assert expected ==
             Protocol.parse_peer_view(
               Map.merge(@base, %{"view" => "shared", "slot" => nil, "extra" => 1})
             )
  end

  test "a 64-byte peer_id is fine, 65 bytes and empty are :bad_peer_id" do
    ok = Map.merge(@base, %{"view" => "shared", "peer_id" => String.duplicate("a", 64)})
    assert {:ok, _} = Protocol.parse_peer_view(ok)

    for bad <- [String.duplicate("a", 65), ""],
        do: assert({:error, :bad_peer_id} = Protocol.parse_peer_view(%{ok | "peer_id" => bad}))
  end

  test "slot 32, -1 and \"0\" are :bad_slot; a slot view with no slot too" do
    for slot <- [32, -1, "0", 1.0] do
      assert {:error, :bad_slot} =
               Protocol.parse_peer_view(Map.merge(@base, %{"view" => "slot", "slot" => slot}))
    end

    assert {:error, :bad_slot} = Protocol.parse_peer_view(Map.put(@base, "view", "slot"))
  end

  test "an unknown view is :bad_view" do
    assert {:error, :bad_view} = Protocol.parse_peer_view(Map.put(@base, "view", "camera"))
  end

  test "missing session_id, peer_id or view is :malformed" do
    assert {:error, :malformed} =
             Protocol.parse_peer_view(%{"peer_id" => "p1", "view" => "shared"})

    assert {:error, :malformed} =
             Protocol.parse_peer_view(%{"session_id" => "s1", "view" => "shared"})

    assert {:error, :malformed} = Protocol.parse_peer_view(@base)
    assert {:error, :malformed} = Protocol.parse_peer_view(nil)
  end
end
