defmodule Platform.Federation.NodeIdentityTest do
  use ExUnit.Case, async: true

  alias Platform.Federation.NodeIdentity

  @moduletag :tmp_dir
  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "node_identity.json")
    Application.put_env(:platform, :node_identity_path, path)

    on_exit(fn ->
      Application.delete_env(:platform, :node_identity_path)
    end)

    %{path: path}
  end

  describe "load_or_create/0" do
    test "generates a new identity when no file exists", %{path: path} do
      identity = NodeIdentity.load_or_create()

      assert is_binary(identity.public_key)
      assert is_binary(identity.private_key)
      assert byte_size(identity.public_key) == 32
      assert byte_size(identity.private_key) == 32
      assert File.exists?(path)
    end

    test "loads an existing identity from disk", %{path: _path} do
      first = NodeIdentity.load_or_create()
      second = NodeIdentity.load_or_create()

      assert first.public_key == second.public_key
      assert first.private_key == second.private_key
    end

    test "regenerates if file contains invalid JSON", %{path: path} do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "not json")

      identity = NodeIdentity.load_or_create()
      assert is_binary(identity.public_key)
      assert byte_size(identity.public_key) == 32
    end
  end

  describe "device_id/1" do
    test "returns a 64-char hex string (full SHA256)" do
      identity = NodeIdentity.load_or_create()
      id = NodeIdentity.device_id(identity)

      assert is_binary(id)
      assert byte_size(id) == 64
      assert Regex.match?(~r/^[0-9a-f]{64}$/, id)
    end

    test "is deterministic for the same identity" do
      identity = NodeIdentity.load_or_create()
      assert NodeIdentity.device_id(identity) == NodeIdentity.device_id(identity)
    end
  end

  describe "sign/2" do
    test "produces a valid Ed25519 signature" do
      identity = NodeIdentity.load_or_create()
      payload = "v3|test-device|cli|node|node||12345||some-nonce|linux|"
      signature = NodeIdentity.sign(payload, identity)

      assert is_binary(signature)
      assert byte_size(signature) == 64

      # Verify signature
      assert :crypto.verify(:eddsa, :none, payload, signature, [identity.public_key, :ed25519])
    end
  end

  describe "build_auth_payload/1" do
    test "builds a pipe-delimited v3 payload" do
      payload =
        NodeIdentity.build_auth_payload(%{
          device_id: "abc123",
          client_id: "cli",
          client_mode: "node",
          role: "node",
          signed_at_ms: 1_234_567_890,
          token: "mytoken",
          nonce: "test-nonce"
        })

      assert payload == "v3|abc123|cli|node|node||1234567890|mytoken|test-nonce|linux|"
    end
  end

  describe "base64url/1" do
    test "encodes without padding" do
      encoded = NodeIdentity.base64url(<<1, 2, 3>>)
      assert is_binary(encoded)
      refute String.contains?(encoded, "=")
      refute String.contains?(encoded, "+")
      refute String.contains?(encoded, "/")
    end
  end
end
