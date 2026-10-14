defmodule Platform.Push.Seal do
  @moduledoc """
  Sealed notification previews (task 01a1261e stage 1).

  A push that travels through the Burrow push relay must carry no plaintext
  the relay could read, log or store. The install seals the notification's
  inner data map to the receiving device's own X25519 public key
  (`apns_devices.push_public_key` / `fcm_devices.push_public_key`); only the
  app on that device can open it.

  ## Construction

  HPKE, RFC 9180, base mode (no PSK, no sender authentication), ciphersuite

    * KEM  `DHKEM(X25519, HKDF-SHA256)` (`kem_id` 0x0020),
    * KDF  `HKDF-SHA256` (`kdf_id` 0x0001),
    * AEAD `AES-128-GCM` (`aead_id` 0x0001),

  one single-shot message (sequence number 0), built on `:crypto` alone.

    * `info` is the constant `"burrow push v1"`;
    * `aad` is the `install_host` bytes. The ciphertext is bound to the
      install it came from: a relay that rewrites a payload's
      `install_host` produces a blob the device cannot open, so a push can
      never be shown under another install's name.

  The blob is `enc (32 bytes) || ciphertext || tag (16 bytes)`,
  base64url-encoded without padding. CryptoKit ships the same suite as
  `HPKE.Ciphersuite.Curve25519_SHA256_AES_GCM_128` (iOS 17+); Tink and
  BouncyCastle ship it on Android. RFC 9180 Appendix A.1.1 publishes test
  vectors for exactly this suite, and `test/platform/push/seal_test.exs`
  reproduces them.

  ## Plaintext and size

  The plaintext is the JSON of the map `Platform.Push.Notification.to_fcm_payload/1`
  puts under `"data"`, for BOTH platforms: one inner shape. A sealed blob is
  at most 3,072 base64url bytes (`max_blob_bytes/0`); when a map would
  exceed it, `seal/3` drops `"author_avatar_url"` first (the app falls back
  to the sender's letter disc; task 01a12773), then `"body"`, trying again
  after each, and then returns `{:error, :too_large}` and the caller sends
  no preview at all, never a truncated or plaintext one.

  ## Secrets

  Nothing here logs. A failure is an atom, never the input.
  """

  @kem_id 0x0020
  @kdf_id 0x0001
  @aead_id 0x0001

  @nk 16
  @nn 12
  @nh 32
  @n_secret 32
  @n_pk 32
  @tag_bytes 16

  @mode_base 0x00

  @info "burrow push v1"
  @max_blob_bytes 3072

  @type key :: <<_::256>>

  @doc "The HPKE `info` string every Burrow push blob is sealed with."
  @spec info() :: String.t()
  def info, do: @info

  @doc "The largest sealed blob, in base64url bytes."
  @spec max_blob_bytes() :: pos_integer()
  def max_blob_bytes, do: @max_blob_bytes

  @doc """
  Seal `plaintext` to `recipient_pub`, bound to `install_host`.

  `recipient_pub` is the device's X25519 public key, raw (32 bytes) or
  base64url without padding (the stored column form). `plaintext` is the
  inner data map (JSON-encoded here) or an already-encoded binary.

  Returns `{:ok, blob}` (base64url, no padding), `{:error, :too_large}` when
  even the map without `author_avatar_url` and `body` exceeds
  `max_blob_bytes/0`, or
  `{:error, :invalid_key}`.
  """
  @spec seal(binary(), map() | binary(), String.t()) ::
          {:ok, String.t()} | {:error, :too_large | :invalid_key}
  def seal(recipient_pub, plaintext, install_host) do
    seal(recipient_pub, plaintext, install_host, [])
  end

  # Test seam: `ephemeral: {pub, priv}` fixes the sender's ephemeral key so
  # a test (and the cross-language fixture) can pin the exact blob. Never
  # pass it in production: a reused ephemeral key reuses the AEAD key and
  # nonce across messages.
  @doc false
  @spec seal(binary(), map() | binary(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :too_large | :invalid_key}
  def seal(recipient_pub, plaintext, install_host, opts) when is_binary(install_host) do
    with {:ok, pk_r} <- decode_key(recipient_pub) do
      seal_fitting(pk_r, plaintext, install_host, opts)
    end
  end

  @doc """
  Open a blob produced by `seal/3` with the device's private key. The
  server never needs this; it exists for tests and positive controls.

  Returns `{:ok, plaintext_binary}` or `{:error, :open_failed}` (wrong key,
  wrong `install_host`, tampered or malformed blob alike).
  """
  @spec open(binary(), String.t(), String.t()) :: {:ok, binary()} | {:error, :open_failed}
  def open(recipient_priv, blob, install_host)
      when is_binary(recipient_priv) and is_binary(blob) and is_binary(install_host) do
    with {:ok, sk_r} <- decode_key(recipient_priv),
         {:ok, raw} <- Base.url_decode64(blob, padding: false),
         <<enc::binary-size(@n_pk), ct::binary>> when byte_size(ct) >= @tag_bytes <- raw do
      pk_r = public_key(sk_r)
      dh = :crypto.compute_key(:ecdh, enc, sk_r, :x25519)
      shared_secret = extract_and_expand(dh, enc <> pk_r)
      %{key: key, base_nonce: nonce} = key_schedule(shared_secret, @info)

      ct_len = byte_size(ct) - @tag_bytes
      ciphertext = binary_part(ct, 0, ct_len)
      tag = binary_part(ct, ct_len, @tag_bytes)

      case :crypto.crypto_one_time_aead(
             :aes_128_gcm,
             key,
             nonce,
             ciphertext,
             install_host,
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) -> {:ok, plaintext}
        :error -> {:error, :open_failed}
      end
    else
      _ -> {:error, :open_failed}
    end
  rescue
    _ -> {:error, :open_failed}
  end

  @doc """
  Whether `value` is a stored-form device public key: base64url WITHOUT
  padding that decodes to exactly 32 bytes (an X25519 public key), in its
  canonical encoding (43 characters, re-encodes to itself).
  """
  @spec valid_public_key?(term()) :: boolean()
  def valid_public_key?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<_::binary-size(32)>> = raw} -> Base.url_encode64(raw, padding: false) == value
      _ -> false
    end
  end

  def valid_public_key?(_value), do: false

  @doc "The stored form of a raw public key: base64url, no padding."
  @spec encode_key(key()) :: String.t()
  def encode_key(<<_::binary-size(32)>> = raw), do: Base.url_encode64(raw, padding: false)

  @doc "A fresh X25519 keypair `{public, private}`, raw 32-byte binaries."
  @spec generate_keypair() :: {key(), key()}
  def generate_keypair, do: :crypto.generate_key(:ecdh, :x25519)

  @doc "The X25519 public key of a raw private key."
  @spec public_key(key()) :: key()
  def public_key(<<_::binary-size(32)>> = sk) do
    {pk, _sk} = :crypto.generate_key(:ecdh, :x25519, sk)
    pk
  end

  # ── RFC 9180 primitives, exposed for the Appendix A vector test ─────────

  @doc false
  # RFC 9180 §7.1.3 DeriveKeyPair for X25519.
  def derive_key_pair(ikm) do
    dkp_prk = labeled_extract(kem_suite_id(), "", "dkp_prk", ikm)
    sk = labeled_expand(kem_suite_id(), dkp_prk, "sk", "", 32)
    {public_key(sk), sk}
  end

  @doc false
  # RFC 9180 §4.1 Encap with a given ephemeral keypair.
  def encap(pk_r, {pk_e, sk_e}) do
    dh = :crypto.compute_key(:ecdh, pk_r, sk_e, :x25519)
    {extract_and_expand(dh, pk_e <> pk_r), pk_e}
  end

  @doc false
  # RFC 9180 §5.1 KeySchedule, base mode (empty psk and psk_id).
  def key_schedule(shared_secret, info) do
    suite = hpke_suite_id()
    psk_id_hash = labeled_extract(suite, "", "psk_id_hash", "")
    info_hash = labeled_extract(suite, "", "info_hash", info)
    context = <<@mode_base>> <> psk_id_hash <> info_hash
    secret = labeled_extract(suite, shared_secret, "secret", "")

    %{
      key_schedule_context: context,
      secret: secret,
      key: labeled_expand(suite, secret, "key", context, @nk),
      base_nonce: labeled_expand(suite, secret, "base_nonce", context, @nn),
      exporter_secret: labeled_expand(suite, secret, "exp", context, @nh)
    }
  end

  @doc false
  # AEAD Seal at sequence number `seq`: nonce = base_nonce XOR I2OSP(seq, Nn).
  def aead_seal(key, base_nonce, seq, aad, pt) do
    nonce = :crypto.exor(base_nonce, <<seq::size(@nn * 8)>>)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, pt, aad, true)
    ct <> tag
  end

  # ── internals ────────────────────────────────────────────────────────────

  # Keys dropped, in order, from a map that does not fit (task 01a12773
  # stage 2). `author_avatar_url` goes first: the app draws the sender's
  # letter disc without it, so losing it costs a picture, not the preview.
  @droppable_when_too_large ~w(author_avatar_url body)

  defp seal_fitting(pk_r, %{} = data, install_host, opts),
    do:
      seal_dropping(
        pk_r,
        data,
        install_host,
        opts,
        Enum.filter(@droppable_when_too_large, &is_map_key(data, &1))
      )

  defp seal_fitting(pk_r, plaintext, install_host, opts) when is_binary(plaintext),
    do: seal_binary(pk_r, plaintext, install_host, opts)

  defp seal_dropping(pk_r, data, install_host, opts, droppable) do
    case {seal_binary(pk_r, Jason.encode!(data), install_host, opts), droppable} do
      {{:error, :too_large}, [key | rest]} ->
        seal_dropping(pk_r, Map.delete(data, key), install_host, opts, rest)

      {result, _} ->
        result
    end
  end

  defp seal_binary(pk_r, plaintext, install_host, opts) do
    ephemeral = Keyword.get_lazy(opts, :ephemeral, &generate_keypair/0)
    {shared_secret, enc} = encap(pk_r, ephemeral)
    %{key: key, base_nonce: base_nonce} = key_schedule(shared_secret, @info)

    blob =
      Base.url_encode64(enc <> aead_seal(key, base_nonce, 0, install_host, plaintext),
        padding: false
      )

    if byte_size(blob) > @max_blob_bytes, do: {:error, :too_large}, else: {:ok, blob}
  end

  defp decode_key(<<_::binary-size(32)>> = raw), do: {:ok, raw}

  defp decode_key(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, <<_::binary-size(32)>> = raw} -> {:ok, raw}
      _ -> {:error, :invalid_key}
    end
  end

  defp decode_key(_), do: {:error, :invalid_key}

  # RFC 9180 §4.1 ExtractAndExpand.
  defp extract_and_expand(dh, kem_context) do
    eae_prk = labeled_extract(kem_suite_id(), "", "eae_prk", dh)
    labeled_expand(kem_suite_id(), eae_prk, "shared_secret", kem_context, @n_secret)
  end

  defp kem_suite_id, do: "KEM" <> <<@kem_id::16>>
  defp hpke_suite_id, do: "HPKE" <> <<@kem_id::16, @kdf_id::16, @aead_id::16>>

  defp labeled_extract(suite_id, salt, label, ikm),
    do: hkdf_extract(salt, "HPKE-v1" <> suite_id <> label <> ikm)

  defp labeled_expand(suite_id, prk, label, info, len),
    do: hkdf_expand(prk, <<len::16>> <> "HPKE-v1" <> suite_id <> label <> info, len)

  # RFC 5869. An empty salt is HashLen zero bytes; HMAC pads a short key with
  # zeros, so "" and <<0::256>> are the same key.
  defp hkdf_extract(salt, ikm), do: :crypto.mac(:hmac, :sha256, salt, ikm)

  defp hkdf_expand(prk, info, len) do
    {okm, _} =
      Enum.reduce_while(1..255, {<<>>, <<>>}, fn i, {acc, prev} ->
        if byte_size(acc) >= len do
          {:halt, {acc, prev}}
        else
          t = :crypto.mac(:hmac, :sha256, prk, prev <> info <> <<i>>)
          {:cont, {acc <> t, t}}
        end
      end)

    binary_part(okm, 0, len)
  end
end
