defmodule Platform.Federation.Peers.Envelope do
  @moduledoc """
  The signed peer envelope: build and verify (task 01a0d90f stage 3, ADR 0054
  section 2).

  This is the VERDICT half of the inbox, in the same split as
  `Platform.Webhooks.GithubSignature` (verdict) and
  `PlatformWeb.Plugs.VerifyGithubSignature` (transport):
  `PlatformWeb.Plugs.VerifyPeerEnvelope` reads the raw bytes and asks this
  module for a verdict. Nothing here touches a conn.

  ## Wire format

  The body is one JSON object:

      {"v": 1, "id": <uuidv7>, "from": <install_id>, "to": <install_id>,
       "kid": <signing kid>, "ts": <unix ms>, "nonce": <16 bytes, b64url>,
       "type": <string>, "payload": {...}}

  The signature is Ed25519 over `"suite-federation/1\\n" <> raw_body` and
  travels, unpadded base64url, in the `suite-federation-signature` header.
  The verifier works on the RAW bytes it received and never re-encodes JSON,
  so key order and whitespace cannot change a verdict.

  ## Verification order

  `verify/3` runs these checks in this order and stops at the first failure.
  Each has its own reason atom:

  | # | check | reason |
  |---|---|---|
  | 1 | body at most 256 KB | `:too_large` |
  | 2 | JSON object | `:invalid_json` |
  | 3 | `v == 1` | `:unsupported_version` |
  | - | every field present and well-typed | `:malformed_envelope` |
  | 4 | `to` is this install | `:wrong_recipient` |
  | 5 | `from` is a known peer, or the type is `relationship.propose` | `:unknown_peer` |
  | 5a | that peer is not revoked | `:peer_revoked` |
  | 5b | a pending peer sends only handshake types | `:peer_not_active` |
  | 6 | `kid` verifies for that peer now | `:unknown_kid`, `:retired_kid`, `:expired_kid`, `:malformed_key` |
  | 7 | signature header present and valid | `:missing_signature`, `:bad_signature` |
  | 8 | `abs(now - ts) <= 300_000` | `:stale_timestamp` (past), `:future_timestamp` |
  | 9 | nonce unseen | `:replayed_nonce` |

  The nonce is recorded only after checks 1-8 pass, so an unsigned or stale
  request cannot burn a nonce a real envelope will later carry.

  A `relationship.propose` from an unknown install (step 5) verifies against
  the key IN ITS PAYLOAD, whose `install_id` and `kid` must equal the
  envelope's `from` and `kid`. That proves only possession of the key. The
  binding of the key to a domain happens after verification, in
  `Platform.Federation.Peers.Inbound`, which re-fetches the proposer's
  `.well-known`.

  The caller (the plug) returns only the reason atom to the peer and never
  echoes input.
  """

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.NonceCache
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PeerKey

  @version 1
  @prefix "suite-federation/1\n"
  @signature_header "suite-federation-signature"
  @max_bytes 256 * 1024
  @window_ms 300_000

  @propose "relationship.propose"
  @handshake_types ~w(relationship.propose relationship.accept relationship.revoke)

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @type reason ::
          :too_large
          | :invalid_json
          | :unsupported_version
          | :malformed_envelope
          | :wrong_recipient
          | :unknown_peer
          | :peer_revoked
          | :peer_not_active
          | :unknown_kid
          | :retired_kid
          | :expired_kid
          | :malformed_key
          | :missing_signature
          | :bad_signature
          | :stale_timestamp
          | :future_timestamp
          | :replayed_nonce

  @type verified :: %{
          envelope: map(),
          peer: Peer.t() | nil,
          key_status: String.t() | :payload
        }

  @doc "Maximum accepted body size in bytes (256 KB)."
  def max_bytes, do: @max_bytes

  @doc "Timestamp window in milliseconds (300 s either side)."
  def window_ms, do: @window_ms

  @doc "The header carrying the signature."
  def signature_header, do: @signature_header

  @doc "The domain-separation prefix the signature covers."
  def signing_prefix, do: @prefix

  @doc "Envelope types a pending (not yet active) peer may send."
  def handshake_types, do: @handshake_types

  @doc """
  Builds a signed envelope of `type` carrying `payload` for `recipient` (a
  `%Peer{}` or a recipient install_id). Returns `{:ok, {raw_body, headers}}`.

  Options (tests and key rotation use them; production callers normally pass
  none):

    * `:signer` — `{kid, private_key}`, or `{:install, kid}` to sign with one
      of this install's verifying keys. Default: this install's current key.
    * `:from` — sender install_id. Default: this install's.
    * `:to`, `:ts`, `:nonce`, `:id` — override the generated field.
  """
  @spec build(String.t(), map(), Peer.t() | String.t(), keyword()) ::
          {:ok, {binary(), [{String.t(), String.t()}]}} | {:error, term()}
  def build(type, payload, recipient, opts \\ [])
      when is_binary(type) and is_map(payload) do
    with {:ok, from} <- sender_id(opts) do
      to = Keyword.get_lazy(opts, :to, fn -> recipient_id(recipient) end)

      fields = fn kid ->
        %{
          "v" => @version,
          "id" => Keyword.get_lazy(opts, :id, &Platform.Types.UUIDv7.generate/0),
          "from" => from,
          "to" => to,
          "kid" => kid,
          "ts" => Keyword.get_lazy(opts, :ts, fn -> System.system_time(:millisecond) end),
          "nonce" => Keyword.get_lazy(opts, :nonce, &new_nonce/0),
          "type" => type,
          "payload" => payload
        }
      end

      sign(fields, Keyword.get(opts, :signer))
    end
  end

  @doc """
  Verifies a received envelope. `headers` is a list of `{name, value}` (any
  case) or a map; `now_ms` is the receiver's clock in unix milliseconds.
  """
  @spec verify(binary(), [{String.t(), String.t()}] | map(), integer()) ::
          {:ok, verified()} | {:error, reason()}
  def verify(raw_body, headers, now_ms) when is_binary(raw_body) and is_integer(now_ms) do
    with :ok <- check_size(raw_body),
         {:ok, map} <- decode(raw_body),
         :ok <- check_version(map),
         {:ok, env} <- check_shape(map),
         :ok <- check_recipient(env),
         {:ok, peer} <- resolve_sender(env),
         {:ok, public_key, key_status} <- resolve_key(env, peer, now_ms),
         :ok <- check_signature(raw_body, headers, public_key),
         :ok <- check_timestamp(env, now_ms),
         :ok <- NonceCache.check_and_record(env["from"], env["nonce"], env["ts"], now_ms) do
      {:ok, %{envelope: env, peer: peer, key_status: key_status}}
    end
  end

  def verify(_raw_body, _headers, _now_ms), do: {:error, :invalid_json}

  # ── build helpers ──────────────────────────────────────────────────────

  defp sender_id(opts) do
    case Keyword.fetch(opts, :from) do
      {:ok, from} ->
        {:ok, from}

      :error ->
        case InstallIdentity.current() do
          %{install_id: id} -> {:ok, id}
          nil -> {:error, :no_install_identity}
        end
    end
  end

  defp recipient_id(%Peer{peer_install_id: id}), do: id
  defp recipient_id(id) when is_binary(id), do: id

  defp sign(fields, {kid, private_key}) when is_binary(kid) and is_binary(private_key) do
    raw = Jason.encode!(fields.(kid))
    {:ok, {raw, headers(Ed25519.sign(@prefix <> raw, private_key))}}
  end

  defp sign(fields, signer) do
    kid_opt =
      case signer do
        {:install, kid} -> kid
        _ -> nil
      end

    with {:ok, kid} <- install_kid(kid_opt) do
      raw = Jason.encode!(fields.(kid))

      with {:ok, %{signature: signature}} <- InstallIdentity.sign(@prefix <> raw, kid) do
        {:ok, {raw, headers(signature)}}
      end
    end
  end

  defp install_kid(nil) do
    case InstallIdentity.current() do
      %{kid: kid} -> {:ok, kid}
      nil -> {:error, :no_install_identity}
    end
  end

  defp install_kid(kid), do: {:ok, kid}

  defp headers(signature) do
    [
      {"content-type", "application/json"},
      {@signature_header, Base.url_encode64(signature, padding: false)}
    ]
  end

  defp new_nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  # ── verify steps ───────────────────────────────────────────────────────

  defp check_size(raw) when byte_size(raw) > @max_bytes, do: {:error, :too_large}
  defp check_size(_raw), do: :ok

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :invalid_json}
    end
  end

  defp check_version(%{"v" => @version}), do: :ok
  defp check_version(_), do: {:error, :unsupported_version}

  defp check_shape(
         %{
           "id" => id,
           "from" => from,
           "to" => to,
           "kid" => kid,
           "ts" => ts,
           "nonce" => nonce,
           "type" => type,
           "payload" => payload
         } = env
       )
       when is_binary(id) and is_binary(from) and is_binary(to) and is_binary(kid) and
              is_integer(ts) and is_binary(nonce) and is_binary(type) and is_map(payload) do
    if uuid?(id) and uuid?(from) and uuid?(to) and byte_size(kid) in 1..128 and
         byte_size(type) in 1..64 and nonce?(nonce) do
      {:ok, env}
    else
      {:error, :malformed_envelope}
    end
  end

  defp check_shape(_), do: {:error, :malformed_envelope}

  defp uuid?(value), do: Regex.match?(@uuid, value)

  defp nonce?(nonce) do
    match?({:ok, <<_::128>>}, Base.url_decode64(nonce, padding: false))
  end

  defp check_recipient(%{"to" => to}) do
    case InstallIdentity.current() do
      %{install_id: ^to} -> :ok
      _ -> {:error, :wrong_recipient}
    end
  end

  defp resolve_sender(%{"from" => from, "type" => type}) do
    case Peers.get_peer_by_install_id(from) do
      nil when type == @propose -> {:ok, nil}
      nil -> {:error, :unknown_peer}
      %Peer{status: "revoked"} -> {:error, :peer_revoked}
      %Peer{status: "active"} = peer -> {:ok, peer}
      %Peer{} = peer when type in @handshake_types -> {:ok, peer}
      %Peer{} -> {:error, :peer_not_active}
    end
  end

  # An unknown proposer: the key comes from the payload and must name the
  # same install and kid as the envelope.
  defp resolve_key(%{"from" => from, "kid" => kid, "payload" => payload}, nil, _now_ms) do
    with %{"install_id" => ^from, "kid" => ^kid, "public_key" => b64} when is_binary(b64) <-
           payload,
         {:ok, <<_::256>> = key} <- Base.url_decode64(b64, padding: false) do
      {:ok, key, :payload}
    else
      _ -> {:error, :malformed_key}
    end
  end

  defp resolve_key(%{"kid" => kid}, %Peer{} = peer, now_ms) do
    now = DateTime.from_unix!(now_ms, :millisecond)

    with {:ok, key} <- Peers.verification_key(peer, kid, now) do
      %PeerKey{status: status} = Enum.find(peer.public_keys, &(&1.kid == kid))
      {:ok, key, status}
    end
  end

  defp check_signature(raw, headers, public_key) do
    case header(headers, @signature_header) do
      nil ->
        {:error, :missing_signature}

      value ->
        with {:ok, signature} <- Base.url_decode64(value, padding: false),
             true <- Ed25519.verify(@prefix <> raw, signature, public_key) do
          :ok
        else
          _ -> {:error, :bad_signature}
        end
    end
  end

  defp check_timestamp(%{"ts" => ts}, now_ms) do
    cond do
      now_ms - ts > @window_ms -> {:error, :stale_timestamp}
      ts - now_ms > @window_ms -> {:error, :future_timestamp}
      true -> :ok
    end
  end

  defp header(headers, name) when is_map(headers) do
    headers |> Enum.to_list() |> header(name)
  end

  defp header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name and is_binary(v) and v != "", do: v
    end)
  end
end
