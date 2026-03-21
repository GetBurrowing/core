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
    test "returns a 32-char hex string" do
      identity = NodeIdentity.load_or_create()
      id = NodeIdentity.device_id(identity)

      assert is_binary(id)
      assert byte_size(id) == 32
      assert Regex.match?(~r/^[0-9a-f]{32}$/, id)
    end

    test "is deterministic for the same identity" do
      identity = NodeIdentity.load_or_create()
      assert NodeIdentity.device_id(identity) == NodeIdentity.device_id(identity)
    end
  end

  describe "sign_challenge/2" do
    test "produces a valid Ed25519 signature" do
      identity = NodeIdentity.load_or_create()
      nonce = :crypto.strong_rand_bytes(32)
      signature = NodeIdentity.sign_challenge(nonce, identity)

      assert is_binary(signature)
      assert byte_size(signature) == 64

      # Verify signature
      assert :crypto.verify(:eddsa, :none, nonce, signature, [identity.public_key, :ed25519])
    end
  end
end
