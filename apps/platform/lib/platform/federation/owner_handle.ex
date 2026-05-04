defmodule Platform.Federation.OwnerHandle do
  @moduledoc """
  Stable pseudonymous identifier for an invoking user, scoped to a peer org.

  Per ADR 0040 §D4. Used (Stage 3) to refer to an invoking user inside a
  federation peer's data without disclosing the user's real identifier.

  ## Threats addressed

    * Cross-org information leakage of real user_ids — handles are derived
      via HMAC, not reversible without the server key.
    * Enumeration if `server_key` is compromised — closed by per-user salt.
    * Bulk handle revocation across all peers — closed by versioned key
      registry; rotate the global key, re-issue handles under a new version.
    * Per-user right-to-be-forgotten (GDPR Art. 17) — closed by per-user salt.
      Rotate a user's salt; existing handles in peer data become unverifiable.
    * Component boundary swap attacks — closed by length-prefixed encoding.

  ## Threats NOT addressed (documented limitations)

    * Active collusion between peers correlating via timing, content, IP
      fingerprint, request size patterns. Pseudonymization protects against
      passive peers; active anti-correlation requires batching, traffic
      shaping, or contractual non-collusion. Out of scope for this module;
      tracked as a separate concern in ADR 0040.

  ## Configuration

  Configure a versioned key registry in `config/runtime.exs`:

      config :platform, :federation_owner_handle_keys, %{
        1 => System.fetch_env!("FEDERATION_OWNER_HANDLE_KEY_V1") |> Base.decode64!()
      }

  Each key must be at least 32 bytes of cryptographic randomness. Generate
  with `:crypto.strong_rand_bytes(32) |> Base.encode64()`.

  ## Usage

      iex> alias Platform.Federation.OwnerHandle
      iex> handle = OwnerHandle.for(user_id, user_salt, peer_org_id, 1)
      "uXMfM3K6w7zN..."

      iex> OwnerHandle.verify(handle, user_id, user_salt, peer_org_id, [1, 2])
      {:ok, 1}

  Per-user salt is stored alongside the user record. To revoke all handles
  for a user (account compromise, RTBF), rotate the salt — existing peer
  copies become unverifiable.

  This module is shipped in Stage 1 of ADR 0040 with no callers; it
  establishes the cryptographic contract that Stage 3 (federation handshake
  pseudonymization) will rely on. Getting the contract right at Stage 1 is
  cheaper than retrofitting at Stage 3.
  """

  @hash_alg :sha256
  @encoding_version "ohv1"
  @min_key_bytes 32

  @typedoc "User identifier. UUID string (v7) or any non-empty binary."
  @type user_id :: binary()

  @typedoc """
  Per-user salt. Generated via `generate_salt/0` and stored alongside the
  user record. May be empty for users created before salt issuance shipped;
  empty salt is a valid input that produces a deterministic handle.
  """
  @type user_salt :: binary()

  @typedoc "Peer organization identifier."
  @type peer_org_id :: binary()

  @typedoc "Versioned key registry index. Positive integer."
  @type key_version :: pos_integer()

  @typedoc "Pseudonymous handle. URL-safe base64, 43 characters for SHA-256."
  @type handle :: binary()

  @doc """
  Compute a stable pseudonymous handle for a (user, peer_org) pair under
  the given key version.

  Returns a base64url-encoded string of fixed length (43 chars for SHA-256).

  Raises `ArgumentError` if `user_id` or `peer_org_id` is empty.
  Raises `RuntimeError` with actionable detail if `key_version` is not
  configured or the configured key is too short.
  """
  @spec for(user_id(), user_salt(), peer_org_id(), key_version()) :: handle()
  def for(user_id, user_salt, peer_org_id, key_version)
      when is_binary(user_id) and is_binary(user_salt) and
             is_binary(peer_org_id) and is_integer(key_version) and key_version > 0 do
    user_id != "" || raise ArgumentError, "user_id must be non-empty"
    peer_org_id != "" || raise ArgumentError, "peer_org_id must be non-empty"

    key = key_for_version!(key_version)
    message = encode_message(user_id, user_salt, peer_org_id)

    :crypto.mac(:hmac, @hash_alg, key, message)
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Verify a handle against a candidate (user, peer_org) tuple by trying each
  of the listed key versions in order.

  Returns `{:ok, version}` on the first match, or `:error` if none match.

  Use during key rotation to accept both old and new versions during a
  soak window: pass `[old_version, new_version]`. After deprecation, pass
  only `[new_version]` and old handles fail verification.

  Comparison uses `Plug.Crypto.secure_compare/2` for constant-time semantics.
  """
  @spec verify(handle(), user_id(), user_salt(), peer_org_id(), [key_version()]) ::
          {:ok, key_version()} | :error
  def verify(handle, user_id, user_salt, peer_org_id, key_versions)
      when is_binary(handle) and is_binary(user_id) and is_binary(user_salt) and
             is_binary(peer_org_id) and is_list(key_versions) do
    Enum.find_value(key_versions, :error, fn version ->
      try do
        expected = __MODULE__.for(user_id, user_salt, peer_org_id, version)
        if Plug.Crypto.secure_compare(handle, expected), do: {:ok, version}
      rescue
        # If a listed version isn't configured, treat it as "no match for this
        # version" rather than crashing the entire verify call. Mis-configured
        # key registry should still allow other versions in the list to match.
        RuntimeError -> nil
        ArgumentError -> nil
      end
    end)
  end

  @doc """
  Generate a fresh per-user salt. Returns 32 bytes of base64url-encoded
  cryptographic randomness (43 characters).

  Store alongside the user record at user creation. To revoke all handles
  for a user (account compromise, RTBF request), rotate by generating a
  fresh salt and persisting it; existing handles in peer data become
  unverifiable.
  """
  @spec generate_salt() :: user_salt()
  def generate_salt do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  # ---------------------------------------------------------------------------
  # private
  # ---------------------------------------------------------------------------

  # Length-prefixed encoding prevents component-boundary-swap attacks where
  # ("AB", "", "CD") would otherwise hash the same as ("A", "BCD").
  # Each component carries its byte size as a 32-bit big-endian prefix.
  # The protocol prefix `ohv1` makes the encoding versionable for future
  # schema changes; bumping it would invalidate all existing handles.
  defp encode_message(user_id, user_salt, peer_org_id) do
    IO.iodata_to_binary([
      @encoding_version,
      <<byte_size(user_id)::32-big>>,
      user_id,
      <<byte_size(user_salt)::32-big>>,
      user_salt,
      <<byte_size(peer_org_id)::32-big>>,
      peer_org_id
    ])
  end

  defp key_for_version!(version) do
    keys = Application.get_env(:platform, :federation_owner_handle_keys, %{})

    case Map.fetch(keys, version) do
      {:ok, key} when is_binary(key) and byte_size(key) >= @min_key_bytes ->
        key

      {:ok, _short_key} ->
        raise """
        Owner handle key v#{version} is shorter than #{@min_key_bytes} bytes.

        Each key in :federation_owner_handle_keys must be at least #{@min_key_bytes}
        bytes of cryptographic randomness. Generate with:

            :crypto.strong_rand_bytes(#{@min_key_bytes}) |> Base.encode64()
        """

      :error ->
        raise """
        Owner handle key v#{version} not configured.

        Add to config/runtime.exs:

            config :platform, :federation_owner_handle_keys, %{
              #{version} => System.fetch_env!("FEDERATION_OWNER_HANDLE_KEY_V#{version}") |> Base.decode64!()
            }

        Configured versions: #{inspect(Map.keys(keys))}
        """
    end
  end
end
