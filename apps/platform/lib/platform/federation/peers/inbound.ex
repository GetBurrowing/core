defmodule Platform.Federation.Peers.Inbound do
  @moduledoc """
  Handlers for VERIFIED peer envelopes (task 01a0d90f stage 3, ADR 0054
  section 1). Input is the `Envelope.verify/3` result, so every envelope
  here is well-formed, addressed to this install, signed, fresh and unseen.

  Handled types:

    * `relationship.propose` — the ONLY type an unknown install may send.
      `Envelope.verify/3` checked it against the key in its own payload,
      which proves only possession of that key. This handler then re-fetches
      the proposer's `.well-known` from the payload's `base_url` (through the
      SSRF-guarded `Client`) and requires the same `install_id` and the same
      `kid` with the same public key. That binds the key to a domain the
      proposer controls. It then records a `pending_inbound` row for a local
      admin to accept after comparing fingerprints out of band. At most
      `proposal_cap/0` proposals are recorded per hour and at most
      `fetch_cap/0` fetches are made per hour (per node); both are checked
      BEFORE the fetch.
    * `relationship.accept` — moves our `pending_outbound` row to `active`.
    * `relationship.revoke` — marks the row `revoked`, `revoked_by: peer`.
    * `key.rotate` — must be signed by a kid that is `current` for the peer
      (not a `previous` one inside its overlap); adds the new kid as current
      and demotes the old one for the 7-day overlap.
    * `space.share` (stage 5) — the peer shares one of its spaces with us:
      `Platform.Federation.Peers.SharedSpaces.accept_share/2` creates the
      local replica channel. The answer carries our space id in `data`.
    * `message.replicate` / `message.submit` (stage 5) — a shared-space
      message from the owner / from the replica, posted by
      `Platform.Federation.Peers.Ingest`. The answer carries our message id
      in `data`.

  `Envelope.verify/3` already refuses the stage 5 types from a pending peer
  (they are not handshake types), and each handler checks `active` again.

  ## Idempotency

  Each handler checks state before acting, so a re-delivered envelope (for
  example one replayed after a `NonceCache` wipe, inside the timestamp
  window) is `{:ok, :already_applied}` and changes nothing: a second propose
  with the same key, an accept for an already-active peer, a rotate to a kid
  already held with the same key. A revoke cannot be re-delivered at all:
  `Envelope.verify/3` refuses every envelope from a revoked peer.
  """

  require Logger

  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Client
  alias Platform.Federation.Peers.Ingest
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.NonceCache
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.SharedSpaces

  @proposal_cap 10
  @fetch_cap 30
  @proposal_window_seconds 3600
  @display_name_max 120

  @doc "Maximum `pending_inbound` proposals recorded per hour."
  def proposal_cap, do: @proposal_cap

  @doc "Maximum unknown-proposer `.well-known` fetches per hour, per node."
  def fetch_cap, do: @fetch_cap

  @doc """
  Handles one verified envelope. `{:ok, result}` or, for types whose answer
  names a local id, `{:ok, result, data}`; `{:error, reason}` otherwise.
  """
  @spec handle(Platform.Federation.Peers.Envelope.verified()) ::
          {:ok, atom()} | {:ok, atom(), map()} | {:error, atom()}
  def handle(%{envelope: %{"type" => type} = env} = verified) do
    result = dispatch(type, env, verified)

    if elem(result, 0) == :ok do
      case verified.peer do
        %Peer{status: status} = peer when status != "revoked" -> _ = Peers.touch_last_seen(peer)
        _ -> :ok
      end
    end

    result
  end

  defp dispatch("relationship.propose", env, %{peer: peer}), do: propose(env, peer)
  defp dispatch("relationship.accept", _env, %{peer: peer}), do: accept(peer)
  defp dispatch("relationship.revoke", _env, %{peer: peer}), do: revoke(peer)
  defp dispatch("key.rotate", env, verified), do: rotate(env, verified)

  defp dispatch("space.share", %{"payload" => payload}, %{peer: %Peer{} = peer}),
    do: SharedSpaces.accept_share(peer, payload)

  defp dispatch(type, %{"payload" => payload}, %{peer: %Peer{} = peer})
       when type in ["message.replicate", "message.submit"],
       do: Ingest.ingest(peer, type, payload)

  defp dispatch(_type, _env, _verified), do: {:error, :unsupported_type}

  # ── relationship.propose ───────────────────────────────────────────────

  # A known install re-proposing with the key we already hold is a
  # re-delivery; anything else from a known install is refused.
  defp propose(%{"kid" => kid, "payload" => payload}, %Peer{} = peer) do
    same_key? =
      Enum.any?(peer.public_keys, &(&1.kid == kid and &1.public_key == payload["public_key"]))

    if peer.status == "pending_inbound" and same_key?,
      do: {:ok, :already_applied},
      else: {:error, :already_known}
  end

  # An install cannot propose to itself (`to` is already verified as self).
  defp propose(%{"from" => same, "to" => same}, nil), do: {:error, :invalid_proposal}

  defp propose(%{"from" => from, "kid" => kid, "payload" => payload}, nil) do
    with {:ok, base_url} <- payload_base_url(payload),
         :ok <- check_proposal_cap(),
         {:ok, descriptor} <- fetch_descriptor(base_url),
         :ok <- check_binding(descriptor, from, kid, payload["public_key"]) do
      attrs = %{
        peer_install_id: from,
        base_url: base_url,
        display_name: display_name(payload["display_name"], descriptor),
        status: "pending_inbound",
        public_keys: [%{kid: kid, public_key: payload["public_key"]}]
      }

      case Peers.create_peer(attrs) do
        {:ok, _peer} ->
          Logger.info(
            "[federation] proposal recorded peer_install_id=#{from} kid=#{kid} " <>
              "fingerprint=#{fingerprint(payload["public_key"])}"
          )

          {:ok, :proposal_recorded}

        {:error, %Ecto.Changeset{errors: errors}} ->
          if Keyword.has_key?(errors, :peer_install_id),
            do: {:error, :already_known},
            else: {:error, :invalid_proposal}
      end
    end
  end

  defp payload_base_url(%{"base_url" => url}) when is_binary(url) and byte_size(url) <= 2048 do
    {:ok, String.trim_trailing(url, "/")}
  end

  defp payload_base_url(_), do: {:error, :invalid_proposal}

  # Two caps, both checked BEFORE the fetch: recorded proposals per hour
  # (the spec's cap), and fetch attempts per hour, because a proposal whose
  # fetch or binding fails records nothing and would otherwise make this
  # install issue unlimited GETs.
  defp check_proposal_cap do
    since = DateTime.add(DateTime.utc_now(), -@proposal_window_seconds, :second)

    cond do
      Peers.count_inbound_proposals_since(since) >= @proposal_cap ->
        {:error, :proposal_rate_limited}

      NonceCache.count_propose_fetch(System.system_time(:millisecond)) > @fetch_cap ->
        {:error, :proposal_rate_limited}

      true ->
        :ok
    end
  end

  defp fetch_descriptor(base_url) do
    case Client.fetch_descriptor(base_url) do
      {:ok, descriptor} ->
        {:ok, descriptor}

      {:error, reason} ->
        Logger.info("[federation] proposal descriptor fetch refused reason=#{inspect(reason)}")
        {:error, :descriptor_unavailable}
    end
  end

  defp check_binding(%{"install_id" => id, "keys" => keys}, from, kid, public_key) do
    key_matches? =
      Enum.any?(keys, fn
        %{"kid" => ^kid, "public_key" => ^public_key} -> true
        _ -> false
      end)

    if id == from and key_matches?, do: :ok, else: {:error, :descriptor_mismatch}
  end

  defp display_name(name, descriptor) do
    (if(is_binary(name) and name != "", do: name, else: descriptor["display_name"]) || "")
    |> to_string()
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
    |> String.slice(0, @display_name_max)
  end

  defp fingerprint(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, raw} -> Platform.Federation.Ed25519.fingerprint(raw)
      _ -> "invalid"
    end
  end

  # ── relationship.accept / revoke ───────────────────────────────────────

  defp accept(%Peer{status: "pending_outbound"} = peer) do
    case Peers.activate(peer, nil) do
      {:ok, _} -> {:ok, :accepted}
      {:error, _} -> {:error, :invalid_transition}
    end
  end

  defp accept(%Peer{status: "active"}), do: {:ok, :already_applied}
  defp accept(_), do: {:error, :invalid_transition}

  defp revoke(%Peer{} = peer) do
    case Peers.mark_revoked(peer, :peer) do
      {:ok, _} ->
        Logger.info("[federation] peer revoked us peer_install_id=#{peer.peer_install_id}")
        {:ok, :revoked}

      {:error, _} ->
        {:error, :invalid_transition}
    end
  end

  defp revoke(nil), do: {:error, :unknown_peer}

  # ── key.rotate ─────────────────────────────────────────────────────────

  defp rotate(_env, %{peer: %Peer{status: status}}) when status != "active",
    do: {:error, :peer_not_active}

  defp rotate(_env, %{key_status: key_status}) when key_status != "current",
    do: {:error, :rotation_needs_current_kid}

  defp rotate(%{"payload" => %{"kid" => new_kid, "public_key" => new_pub}}, %{peer: peer})
       when is_binary(new_kid) and is_binary(new_pub) do
    case Enum.find(peer.public_keys, &(&1.kid == new_kid)) do
      %{public_key: ^new_pub} ->
        {:ok, :already_applied}

      %{} ->
        {:error, :kid_conflict}

      nil ->
        case Peers.add_peer_key(peer, new_kid, new_pub, InstallIdentity.overlap_seconds()) do
          {:ok, _} ->
            Logger.info(
              "[federation] peer key rotated peer_install_id=#{peer.peer_install_id} " <>
                "new_kid=#{new_kid} fingerprint=#{fingerprint(new_pub)}"
            )

            {:ok, :key_rotated}

          {:error, _} ->
            {:error, :invalid_key}
        end
    end
  end

  defp rotate(_env, _verified), do: {:error, :invalid_key}
end
