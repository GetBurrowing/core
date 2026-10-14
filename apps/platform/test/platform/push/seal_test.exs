defmodule Platform.Push.SealTest do
  @moduledoc """
  Task 01a1261e stage 1: `Platform.Push.Seal`, HPKE RFC 9180 base mode with
  DHKEM(X25519, HKDF-SHA256) / HKDF-SHA256 / AES-128-GCM.

  The Appendix A.1.1 vector is the correctness anchor: every intermediate the
  RFC publishes (derived keypairs, shared secret, key schedule, the first
  sequence's ciphertext) is reproduced exactly. The rest pins the Burrow
  envelope: `info`, the install_host as aad, the 3,072-byte cap and the
  key format the device tables store.
  """
  use ExUnit.Case, async: true

  alias Platform.Push.Seal

  defp h(hex), do: Base.decode16!(hex, case: :lower)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # RFC 9180 Appendix A.1.1, copied from https://www.rfc-editor.org/rfc/rfc9180.txt
  @info "4f6465206f6e2061204772656369616e2055726e"
  @ikm_e "7268600d403fce431561aef583ee1613527cff655c1343f29812e66706df3234"
  @pk_em "37fda3567bdbd628e88668c3c8d7e97d1d1253b6d4ea6d44c150f741f1bf4431"
  @sk_em "52c4a758a802cd8b936eceea314432798d5baf2d7e9235dc084ab1b9cfa2f736"
  @ikm_r "6db9df30aa07dd42ee5e8181afdb977e538f5e1fec8a06223f33f7013e525037"
  @pk_rm "3948cfe0ad1ddb695d780e59077195da6c56506b027329794ab02bca80815c4d"
  @sk_rm "4612c550263fc8ad58375df3f557aac531d26850903e55a9f23f21d8534e8ac8"
  @shared_secret "fe0e18c9f024ce43799ae393c7e8fe8fce9d218875e8227b0187c04e7d2ea1fc"
  @key_schedule_context "00725611c9d98c07c03f60095cd32d400d8347d45ed67097bbad50fc56da742d07cb6cffde367bb0565ba28bb02c90744a20f5ef37f30523526106f637abb05449"
  @secret "12fff91991e93b48de37e7daddb52981084bd8aa64289c3788471d9a9712f397"
  @key "4531685d41d65f03dc48f6b8302c05b0"
  @base_nonce "56d890e5accaaf011cff4b7d"
  @exporter_secret "45ff1c2e220db587171952c0592d5f5ebe103f1561a2614e38f2ffd47e99e3f8"
  @pt "4265617574792069732074727574682c20747275746820626561757479"
  @aad0 "436f756e742d30"
  @ct0 "f938558b5d72f1a23810b4be2ab4f84331acc02fc97babc53a52ae8218a355a96d8770ac83d07bea87e13c512a"
  @aad1 "436f756e742d31"
  @ct1 "af2d7e9ac9ae7e270f46ba1f975be53c09f8d875bdc8535458c2494e8a6eab251c03d0c22a56b8ca42c2063b84"

  describe "RFC 9180 A.1.1 (base mode, X25519 / HKDF-SHA256 / AES-128-GCM)" do
    test "DeriveKeyPair reproduces both published keypairs" do
      assert {pk_e, sk_e} = Seal.derive_key_pair(h(@ikm_e))
      assert hex(pk_e) == @pk_em
      assert hex(sk_e) == @sk_em

      assert {pk_r, sk_r} = Seal.derive_key_pair(h(@ikm_r))
      assert hex(pk_r) == @pk_rm
      assert hex(sk_r) == @sk_rm
    end

    test "Encap, the key schedule and the first-sequence ciphertext match exactly" do
      {shared_secret, enc} = Seal.encap(h(@pk_rm), {h(@pk_em), h(@sk_em)})

      assert hex(enc) == @pk_em
      assert hex(shared_secret) == @shared_secret

      ks = Seal.key_schedule(shared_secret, h(@info))
      assert hex(ks.key_schedule_context) == @key_schedule_context
      assert hex(ks.secret) == @secret
      assert hex(ks.key) == @key
      assert hex(ks.base_nonce) == @base_nonce
      assert hex(ks.exporter_secret) == @exporter_secret

      assert hex(Seal.aead_seal(ks.key, ks.base_nonce, 0, h(@aad0), h(@pt))) == @ct0
      # Sequence 1 proves the nonce XOR is applied, not just the base nonce.
      assert hex(Seal.aead_seal(ks.key, ks.base_nonce, 1, h(@aad1), h(@pt))) == @ct1
    end
  end

  describe "seal/3 and open/3" do
    setup do
      {pk, sk} = Seal.generate_keypair()
      %{pk: pk, sk: sk, host: "suite-b.localhost"}
    end

    test "round trip: a sealed map opens to its JSON", %{pk: pk, sk: sk, host: host} do
      data = %{"title" => "Dana in launch", "body" => "ZEBRA-7731", "install_host" => host}

      assert {:ok, blob} = Seal.seal(pk, data, host)
      assert blob =~ ~r/\A[A-Za-z0-9_-]+\z/, "blob must be base64url without padding"
      refute blob =~ "ZEBRA"

      assert {:ok, json} = Seal.open(sk, blob, host)
      assert Jason.decode!(json) == data
    end

    test "the blob is enc || ciphertext || tag: 32 + plaintext + 16 bytes", ctx do
      {:ok, blob} = Seal.seal(ctx.pk, "hello", ctx.host)
      assert byte_size(Base.url_decode64!(blob, padding: false)) == 32 + 5 + 16
    end

    test "accepts the stored base64url form of the public key", ctx do
      assert {:ok, blob} = Seal.seal(Seal.encode_key(ctx.pk), "hello", ctx.host)
      assert {:ok, "hello"} = Seal.open(ctx.sk, blob, ctx.host)
    end

    test "opening with a different install_host as aad fails", ctx do
      {:ok, blob} = Seal.seal(ctx.pk, "hello", ctx.host)

      # Positive control in the same body: the right host opens it.
      assert {:ok, "hello"} = Seal.open(ctx.sk, blob, ctx.host)
      assert {:error, :open_failed} = Seal.open(ctx.sk, blob, "suite-a.localhost")
      assert {:error, :open_failed} = Seal.open(ctx.sk, blob, "")
    end

    test "another device's key cannot open it, and a tampered blob fails", ctx do
      {:ok, blob} = Seal.seal(ctx.pk, "hello", ctx.host)
      {_pk2, sk2} = Seal.generate_keypair()
      assert {:error, :open_failed} = Seal.open(sk2, blob, ctx.host)

      raw = Base.url_decode64!(blob, padding: false)
      last = :binary.last(raw)
      tampered = binary_part(raw, 0, byte_size(raw) - 1) <> <<Bitwise.bxor(last, 1)>>

      assert {:error, :open_failed} =
               Seal.open(ctx.sk, Base.url_encode64(tampered, padding: false), ctx.host)

      assert {:error, :open_failed} = Seal.open(ctx.sk, "not base64!", ctx.host)
      assert {:error, :open_failed} = Seal.open(ctx.sk, "AAAA", ctx.host)
    end

    test "uses a fresh ephemeral key per seal", ctx do
      {:ok, a} = Seal.seal(ctx.pk, "hello", ctx.host)
      {:ok, b} = Seal.seal(ctx.pk, "hello", ctx.host)
      refute a == b
    end

    test "a malformed recipient key is refused", ctx do
      assert {:error, :invalid_key} = Seal.seal(<<1, 2, 3>>, "hello", ctx.host)
      assert {:error, :invalid_key} = Seal.seal(String.duplicate("A", 42), "hello", ctx.host)
    end
  end

  describe "the 3,072-byte cap" do
    setup do
      {pk, sk} = Seal.generate_keypair()
      %{pk: pk, sk: sk, host: "suite-b.localhost"}
    end

    test "an oversized body is dropped and the rest still seals", ctx do
      data = %{"title" => "Dana in launch", "body" => String.duplicate("x", 4_000)}

      assert {:ok, blob} = Seal.seal(ctx.pk, data, ctx.host)
      assert byte_size(blob) <= Seal.max_blob_bytes()
      assert {:ok, json} = Seal.open(ctx.sk, blob, ctx.host)
      assert Jason.decode!(json) == %{"title" => "Dana in launch"}
    end

    test "a map too large even without its body is {:error, :too_large}", ctx do
      data = %{"title" => String.duplicate("t", 4_000), "body" => "short"}
      assert {:error, :too_large} = Seal.seal(ctx.pk, data, ctx.host)
    end

    test "a map that fits keeps its body", ctx do
      data = %{"title" => "T", "body" => String.duplicate("b", 200)}
      {:ok, blob} = Seal.seal(ctx.pk, data, ctx.host)
      {:ok, json} = Seal.open(ctx.sk, blob, ctx.host)
      assert Jason.decode!(json)["body"] == String.duplicate("b", 200)
    end

    # Task 01a12773 stage 2: the avatar url has a letter fallback on the
    # device, so it is the first thing a too-large map gives up.
    test "an oversized map loses author_avatar_url before body", ctx do
      url = "https://idp.example/" <> String.duplicate("a", 1_400)
      body = String.duplicate("b", 1_400)
      data = %{"title" => "Dana in launch", "body" => body, "author_avatar_url" => url}

      # Precondition: the whole map does not fit, without the url it does.
      assert byte_size(Jason.encode!(data)) > 2_256
      assert byte_size(Jason.encode!(Map.delete(data, "author_avatar_url"))) <= 2_256

      assert {:ok, blob} = Seal.seal(ctx.pk, data, ctx.host)
      assert {:ok, json} = Seal.open(ctx.sk, blob, ctx.host)
      assert Jason.decode!(json) == %{"title" => "Dana in launch", "body" => body}
    end

    test "when dropping the url is not enough, the body goes too", ctx do
      data = %{
        "title" => "Dana in launch",
        "body" => String.duplicate("b", 4_000),
        "author_avatar_url" => "https://idp.example/" <> String.duplicate("a", 1_400)
      }

      assert {:ok, blob} = Seal.seal(ctx.pk, data, ctx.host)
      assert {:ok, json} = Seal.open(ctx.sk, blob, ctx.host)
      assert Jason.decode!(json) == %{"title" => "Dana in launch"}
    end

    test "a map that fits keeps its avatar url", ctx do
      data = %{"title" => "T", "author_avatar_url" => "https://h.example/a.png?v=1"}
      {:ok, blob} = Seal.seal(ctx.pk, data, ctx.host)
      {:ok, json} = Seal.open(ctx.sk, blob, ctx.host)
      assert Jason.decode!(json) == data
    end

    test "the boundary: the largest plaintext that fits, and one byte more", ctx do
      # 3,072 base64url chars encode 2,304 bytes = 32 enc + 16 tag + 2,256.
      assert {:ok, blob} = Seal.seal(ctx.pk, String.duplicate("p", 2_256), ctx.host)
      assert byte_size(blob) == 3_072
      assert {:error, :too_large} = Seal.seal(ctx.pk, String.duplicate("p", 2_257), ctx.host)
    end
  end

  describe "valid_public_key?/1 (the stored device-key format)" do
    test "accepts unpadded base64url of exactly 32 bytes" do
      {pk, _} = Seal.generate_keypair()
      assert Seal.valid_public_key?(Seal.encode_key(pk))
    end

    test "rejects 31 and 33 bytes, padding, standard base64 and non-strings" do
      refute Seal.valid_public_key?(Base.url_encode64(:binary.copy(<<7>>, 31), padding: false))
      refute Seal.valid_public_key?(Base.url_encode64(:binary.copy(<<7>>, 33), padding: false))
      refute Seal.valid_public_key?(Base.url_encode64(:binary.copy(<<7>>, 32)))
      # `+`/`/` are standard base64, not base64url.
      refute Seal.valid_public_key?(Base.encode64(:binary.copy(<<0xFB>>, 32), padding: false))
      refute Seal.valid_public_key?(nil)
      refute Seal.valid_public_key?(:binary.copy(<<7>>, 32))
    end
  end
end
