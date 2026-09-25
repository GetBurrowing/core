defmodule Platform.Federation.Ed25519 do
  @moduledoc """
  The one Ed25519 implementation in core (task 01a0d90f stage 2, ADR 0054).

  Hoisted out of `Platform.Federation.NodeIdentity`, which used these exact
  `:crypto` calls inline for its OpenClaw device key. NodeIdentity now
  delegates here, and install-to-install federation
  (`Platform.Federation.Peers.InstallIdentity`) signs with the same functions.
  There is no second keypair implementation.

  Ed25519 is deterministic: the same private key and payload always give the
  same signature. `test/platform/federation/ed25519_test.exs` pins the RFC 8032
  test vector 1 and the NodeIdentity values computed before the hoist, so a
  change here that altered NodeIdentity's output would fail there.

  Keys are raw bytes: a 32-byte public key and the 32-byte private seed that
  `:crypto` uses for `:eddsa`. Nothing in this module logs, persists or
  encodes a private key.
  """

  @type public_key :: <<_::256>>
  @type private_key :: <<_::256>>

  @doc "Generates a fresh keypair. Returns `{public_key, private_key}`."
  @spec generate() :: {public_key(), private_key()}
  def generate, do: :crypto.generate_key(:eddsa, :ed25519)

  @doc "Signs `payload` with `private_key`. Returns the 64-byte signature."
  @spec sign(binary(), private_key()) :: binary()
  def sign(payload, private_key) when is_binary(payload) and is_binary(private_key) do
    :crypto.sign(:eddsa, :none, payload, [private_key, :ed25519])
  end

  @doc """
  Verifies `signature` over `payload` against `public_key`.

  Returns a boolean and never raises: a malformed key or signature (wrong
  size, not a binary) is a failed verification, not a crash, because the
  inputs come from remote peers.
  """
  @spec verify(binary(), binary(), binary()) :: boolean()
  def verify(payload, signature, public_key)
      when is_binary(payload) and is_binary(signature) and byte_size(public_key) == 32 do
    :crypto.verify(:eddsa, :none, payload, signature, [public_key, :ed25519])
  rescue
    _ -> false
  end

  def verify(_payload, _signature, _public_key), do: false

  @doc """
  The fingerprint of a public key: sha256 of the raw key bytes, lowercase hex
  (64 characters). This is NodeIdentity's `device_id` and the value admins
  compare out of band when accepting a peer.
  """
  @spec fingerprint(public_key()) :: String.t()
  def fingerprint(public_key) when is_binary(public_key) do
    :crypto.hash(:sha256, public_key)
    |> Base.encode16(case: :lower)
  end
end
