defmodule Platform.Federation.Ed25519Test do
  @moduledoc """
  Task 01a0d90f stage 2: the Ed25519 primitives hoisted out of NodeIdentity.

  The fixed-key values below were computed BEFORE the hoist, with the exact
  `:crypto` calls NodeIdentity then made inline, and cross-checked against
  two independent implementations (Python `cryptography` and `sha256sum`).
  The key is RFC 8032 section 7.1 TEST 1, whose empty-message signature is
  published in the RFC, so that value is an external anchor rather than
  something this code produced.
  """

  # async: false — the NodeIdentity describe sets the GLOBAL
  # :node_identity_path app env, which node_identity_test.exs (async) also
  # sets. Running after the async pool keeps the two from racing.
  use ExUnit.Case, async: false

  alias Platform.Federation.Ed25519
  alias Platform.Federation.NodeIdentity

  @moduletag :tmp_dir

  # RFC 8032 7.1 TEST 1.
  @rfc_secret Base.decode16!("9D61B19DEFFD5A60BA844AF492EC2CC44449C5697B326919703BAC031CAE7F60")
  @rfc_public Base.decode16!("D75A980182B10AB7D54BFED3C964073A0EE172F3DAA62325AF021A68F707511A")
  @rfc_empty_signature Base.decode16!(
                         "E5564300C360AC729086E2CC806E828A84877F1EB8E5D974D873E065224901555FB8821590A33BACC61E39701CF9B46BD25BF5F0595BBE24655141438E7A100B"
                       )

  # Pre-hoist NodeIdentity values for the RFC key.
  @pinned_device_id "21fe31dfa154a261626bf854046fd2271b7bed4b6abe45aa58877ef47f9721b9"
  @pinned_auth_payload "v3|dev|cli|backend|operator||1700000000000|tok|nonce|linux|"
  @pinned_auth_signature Base.decode16!(
                           "DD88BB5EDA34F2004D7D136DA7DE0CEF8830CA8C82C4B2F5004CDB42FC6E4043E3C856FC40D53DCA792E705C4EFA62C4E4688C264A10683F306AB47C79E0330C"
                         )

  describe "generate/0, sign/2, verify/3" do
    test "a generated keypair signs and verifies a roundtrip" do
      {pub, priv} = Ed25519.generate()
      assert byte_size(pub) == 32
      assert byte_size(priv) == 32

      signature = Ed25519.sign("hello federation", priv)
      assert byte_size(signature) == 64
      assert Ed25519.verify("hello federation", signature, pub)
    end

    test "a payload tampered by one byte fails verification" do
      {pub, priv} = Ed25519.generate()
      payload = "hello federation"
      signature = Ed25519.sign(payload, priv)

      # Positive control: the untampered payload verifies under this key.
      assert Ed25519.verify(payload, signature, pub)

      <<first, rest::binary>> = payload
      tampered = <<Bitwise.bxor(first, 1), rest::binary>>
      refute Ed25519.verify(tampered, signature, pub)
    end

    test "a signature from a different key fails verification" do
      {pub, _priv} = Ed25519.generate()
      {_other_pub, other_priv} = Ed25519.generate()

      refute Ed25519.verify("payload", Ed25519.sign("payload", other_priv), pub)
    end

    test "malformed keys and signatures are a false, not a crash" do
      {pub, _priv} = Ed25519.generate()

      refute Ed25519.verify("payload", "short", pub)
      refute Ed25519.verify("payload", :binary.copy(<<0>>, 64), <<1, 2, 3>>)
      refute Ed25519.verify("payload", nil, pub)
    end

    test "the RFC 8032 test 1 vector reproduces exactly" do
      assert {@rfc_public, @rfc_secret} == :crypto.generate_key(:eddsa, :ed25519, @rfc_secret)
      assert Ed25519.sign("", @rfc_secret) == @rfc_empty_signature
      assert Ed25519.verify("", @rfc_empty_signature, @rfc_public)
    end

    test "fingerprint/1 is the lowercase sha256 hex of the public key" do
      assert Ed25519.fingerprint(@rfc_public) == @pinned_device_id
    end
  end

  describe "NodeIdentity after the hoist" do
    setup %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "node_identity.json")

      File.write!(
        path,
        Jason.encode!(%{
          public_key: Base.encode64(@rfc_public),
          private_key: Base.encode64(@rfc_secret)
        })
      )

      Application.put_env(:platform, :node_identity_path, path)
      on_exit(fn -> Application.delete_env(:platform, :node_identity_path) end)
      %{path: path}
    end

    test "output is byte-identical to the pre-hoist values for a fixed key" do
      identity = NodeIdentity.load_or_create()

      assert identity == %{public_key: @rfc_public, private_key: @rfc_secret}
      assert NodeIdentity.device_id(identity) == @pinned_device_id
      assert NodeIdentity.sign("", identity) == @rfc_empty_signature
      assert NodeIdentity.sign(@pinned_auth_payload, identity) == @pinned_auth_signature

      payload =
        NodeIdentity.build_auth_payload(%{
          device_id: "dev",
          client_id: "cli",
          client_mode: "backend",
          role: "operator",
          signed_at_ms: 1_700_000_000_000,
          token: "tok",
          nonce: "nonce"
        })

      assert payload == @pinned_auth_payload
    end

    test "a freshly generated identity keeps the on-disk format", %{path: path} do
      File.rm!(path)
      identity = NodeIdentity.load_or_create()

      assert {:ok, %{"public_key" => pub_b64, "private_key" => priv_b64} = on_disk} =
               path |> File.read!() |> Jason.decode()

      assert map_size(on_disk) == 2
      assert Base.decode64!(pub_b64) == identity.public_key
      assert Base.decode64!(priv_b64) == identity.private_key
    end
  end
end
