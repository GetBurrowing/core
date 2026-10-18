defmodule Platform.Federation.Peers.InstallIdentity do
  @moduledoc """
  This install's federation identity: its `install_id` and Ed25519 signing
  keys (task 01a0d90f stage 2, ADR 0054 section 1).

  ## Private-key custody

  The private key is generated in memory by `Platform.Federation.Ed25519`
  and stored ONLY in `Platform.Vault`, under slug `peer-federation-key-<kid>`
  at platform scope. It is read back at call time with an explicit
  `{:system, nil}` accessor, the same Vault-at-call-time pattern as
  `Platform.Push.vapid_details/0`, and used only inside `sign/1`. It is:

    * never written to a file (unlike `NodeIdentity`'s device key, which is a
      client-side key with a different threat model);
    * never logged — log lines here carry the install_id, kid and
      fingerprint, nothing else;
    * never returned from this module's public functions. `current/0`,
      `descriptor/0` and `rotate!/0` return public material only.

  `federation_install_keys` holds the public half and the Vault slug.

  ## Rotation

  `rotate!/0` generates a new key and makes it `current`. The old key becomes
  `previous` with `valid_until` = now + 7 days, the overlap during which
  peers still accept signatures under the old kid. `previous` keys past
  `valid_until` are retired (and their Vault entry deleted) by the next
  `rotate!/0` or `descriptor/0`. The descriptor lists `current` plus every
  unexpired `previous`.

  ## Concurrency

  `ensure!/0` and `rotate!/0` run in one transaction holding a
  transaction-scoped advisory lock, so two callers cannot both create an
  identity or both rotate. The schema backs this up: the identity table is a
  singleton and at most one key is `current`.
  """

  import Ecto.Query

  require Logger

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.IdentityRecord
  alias Platform.Federation.Peers.InstallKey
  alias Platform.Repo
  alias Platform.Vault

  @protocol "suite-federation/1"
  @alg "ed25519"
  @overlap_seconds 7 * 24 * 60 * 60
  @vault_slug_prefix "peer-federation-key-"
  @vault_accessor {:system, nil}
  @vault_scope {:platform, nil}

  # Arbitrary constant naming this module's advisory lock.
  @lock_key 5_401_090_001

  @type current :: %{
          install_id: String.t(),
          display_name: String.t(),
          kid: String.t(),
          public_key: binary(),
          fingerprint: String.t()
        }

  @doc "The rotation overlap in seconds (7 days)."
  def overlap_seconds, do: @overlap_seconds

  @doc "The Vault slug holding the private key for `kid`."
  @spec vault_slug(String.t()) :: String.t()
  def vault_slug(kid), do: @vault_slug_prefix <> kid

  @doc """
  Returns this install's identity, creating it (and its first key) on first
  call. Idempotent: later calls return the same install_id and kid.
  """
  @spec ensure!() :: current()
  def ensure! do
    locked!(fn ->
      record = get_record() || create_record!()
      key = current_key() || create_key!()
      to_current(record, key)
    end)
  end

  @doc "This install's identity and current key, or nil if none exists yet."
  @spec current() :: current() | nil
  def current do
    with %IdentityRecord{} = record <- get_record(),
         %InstallKey{} = key <- current_key() do
      to_current(record, key)
    end
  end

  @doc """
  Signs `payload` with the current private key.

  Returns `{:ok, %{kid: kid, signature: signature}}`, or an error when no
  identity exists or the Vault refuses the read. The private key is read from
  the Vault for this call and not retained.
  """
  @spec sign(binary()) :: {:ok, %{kid: String.t(), signature: binary()}} | {:error, term()}
  def sign(payload) when is_binary(payload) do
    case current_key() do
      nil ->
        {:error, :no_install_identity}

      %InstallKey{} = key ->
        with {:ok, private_key} <- fetch_private_key(key) do
          {:ok, %{kid: key.kid, signature: Ed25519.sign(payload, private_key)}}
        end
    end
  end

  @doc """
  Signs `payload` with the private key of `kid`, which must be one of
  `verifying_keys/0` (the current key, or a `previous` key inside its
  overlap). Key rotation uses it: a `key.rotate` notice is signed by the OLD
  key, because that is the key the peer currently trusts (ADR 0054 section 1).
  """
  @spec sign(binary(), String.t()) ::
          {:ok, %{kid: String.t(), signature: binary()}} | {:error, term()}
  def sign(payload, kid) when is_binary(payload) and is_binary(kid) do
    case Enum.find(verifying_keys(), &(&1.kid == kid)) do
      nil ->
        {:error, :unknown_install_kid}

      %InstallKey{} = key ->
        with {:ok, private_key} <- fetch_private_key(key) do
          {:ok, %{kid: key.kid, signature: Ed25519.sign(payload, private_key)}}
        end
    end
  end

  @doc """
  Rotates the signing key. The new kid becomes `current`; the old one
  becomes `previous` for the 7-day overlap. Returns the new current identity.
  Creates the identity first if none exists.
  """
  @spec rotate!() :: current()
  def rotate! do
    locked!(fn ->
      record = get_record() || create_record!()
      retire_expired!()

      old = current_key()

      if old do
        valid_until = DateTime.add(now(), @overlap_seconds, :second)

        old
        |> InstallKey.changeset(%{status: "previous", valid_until: valid_until})
        |> Repo.update!()
      end

      new = create_key!()

      Logger.info(
        "[federation] install key rotated install_id=#{record.install_id} " <>
          "old_kid=#{old && old.kid} new_kid=#{new.kid} " <>
          "fingerprint=#{Ed25519.fingerprint(new.public_key)}"
      )

      to_current(record, new)
    end)
  end

  @doc """
  The public `/.well-known/suite-federation` document. Creates the identity
  on first call. Contains public keys only.
  """
  @spec descriptor() :: map()
  def descriptor do
    %{install_id: install_id, display_name: display_name} = ensure!()
    retire_expired_unlocked()
    base_url = Config.base_url()

    %{
      protocol: @protocol,
      install_id: install_id,
      display_name: display_name,
      base_url: base_url,
      inbox: base_url <> "/federation/v1/inbox",
      keys: Enum.map(verifying_keys(), &key_descriptor/1)
    }
  end

  @doc "Keys that currently verify: `current` plus unexpired `previous`."
  @spec verifying_keys() :: [InstallKey.t()]
  def verifying_keys do
    now = now()

    from(k in InstallKey,
      where:
        k.status == "current" or
          (k.status == "previous" and k.valid_until > ^now),
      order_by: [asc: k.status, desc: k.inserted_at]
    )
    |> Repo.all()
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp key_descriptor(%InstallKey{} = key) do
    %{
      kid: key.kid,
      alg: @alg,
      public_key: Base.url_encode64(key.public_key, padding: false),
      status: key.status,
      valid_until: key.valid_until
    }
  end

  defp to_current(%IdentityRecord{} = record, %InstallKey{} = key) do
    %{
      install_id: record.install_id,
      display_name: record.display_name,
      kid: key.kid,
      public_key: key.public_key,
      fingerprint: Ed25519.fingerprint(key.public_key)
    }
  end

  defp get_record, do: Repo.one(from(r in IdentityRecord, limit: 1))

  defp current_key, do: Repo.one(from(k in InstallKey, where: k.status == "current"))

  defp create_record! do
    record =
      %IdentityRecord{}
      |> IdentityRecord.changeset(%{
        install_id: Platform.Types.UUIDv7.generate(),
        display_name: default_display_name()
      })
      |> Repo.insert!()

    Logger.info("[federation] install identity created install_id=#{record.install_id}")
    record
  end

  defp create_key! do
    {public_key, private_key} = Ed25519.generate()
    fingerprint = Ed25519.fingerprint(public_key)
    kid = kid_for(fingerprint)
    slug = vault_slug(kid)

    case Vault.put(slug, :keypair, private_key,
           scope: @vault_scope,
           provider: "suite-federation",
           name: "Burrow federation signing key #{kid}",
           metadata: %{"kid" => kid, "fingerprint" => fingerprint, "alg" => @alg}
         ) do
      {:ok, _credential} ->
        :ok

      # Raise with the changeset's ERRORS only. The changeset itself carries
      # the private key in its changes; `encrypted_data` is `redact: true`,
      # but a crash report is not the place to rely on that.
      {:error, %Ecto.Changeset{errors: errors}} ->
        raise "could not store install key #{kid} in the Vault: #{inspect(errors)}"
    end

    key =
      %InstallKey{}
      |> InstallKey.changeset(%{
        kid: kid,
        public_key: public_key,
        status: "current",
        vault_slug: slug
      })
      |> Repo.insert!()

    Logger.info("[federation] install key created kid=#{kid} fingerprint=#{fingerprint}")
    key
  end

  # A kid is the first 16 hex characters of the key's fingerprint plus a
  # millisecond timestamp, so it is readable, sortable and never reused even
  # if a key were somehow regenerated.
  defp kid_for(fingerprint) do
    "#{String.slice(fingerprint, 0, 16)}-#{System.system_time(:millisecond)}"
  end

  defp fetch_private_key(%InstallKey{vault_slug: slug}) do
    case Vault.get_unique(slug, accessor: @vault_accessor, scope: @vault_scope) do
      {:ok, <<_::256>> = private_key} -> {:ok, private_key}
      {:ok, _other} -> {:error, :malformed_private_key}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retire_expired_unlocked do
    if Enum.any?(expired_previous()) do
      locked!(fn -> retire_expired!() end)
    end

    :ok
  end

  defp expired_previous do
    now = now()

    from(k in InstallKey, where: k.status == "previous" and k.valid_until <= ^now)
    |> Repo.all()
  end

  defp retire_expired! do
    Enum.each(expired_previous(), fn key ->
      key |> InstallKey.changeset(%{status: "retired"}) |> Repo.update!()

      # The private half of a retired key can sign nothing anyone accepts, so
      # it is deleted rather than left as material to leak.
      _ = Vault.delete(key.vault_slug, accessor: @vault_accessor, scope: @vault_scope)

      Logger.info("[federation] install key retired kid=#{key.kid}")
    end)
  end

  defp locked!(fun) do
    case Repo.transaction(fn ->
           Repo.query!("SELECT pg_advisory_xact_lock($1)", [@lock_key])
           fun.()
         end) do
      {:ok, result} -> result
      {:error, reason} -> raise "install identity transaction failed: #{inspect(reason)}"
    end
  end

  defp default_display_name do
    case URI.parse(Config.base_url()) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> "Burrow install"
    end
  end

  defp now, do: DateTime.utc_now()
end
