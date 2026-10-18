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

  The signature is Ed25519 over `<signing prefix> <> raw_body` and travels,
  unpadded base64url, in that protocol's signature header. The verifier works
  on the RAW bytes it received and never re-encodes JSON, so key order and
  whitespace cannot change a verdict.

  ## Protocol ids (task 01a14ba9 stage 1)

  The protocol id names the SIGNATURE DOMAIN only. The body schema is the
  same under both, so the body's `"v"` stays `1` under either id.

  | protocol id | signing prefix | signature header | sent by this install |
  |---|---|---|---|
  | `suite-federation/1` | `"suite-federation/1\\n"` | `suite-federation-signature` | yes (default) |
  | `burrow-federation/2` | `"burrow-federation/2\\n"` | `burrow-federation-signature` | only when switched on AND the peer advertises it |

  The id is inside the signed bytes, so a renamed id is a new protocol, not
  an alias: a v1-only peer refuses a v2 signature. This install ACCEPTS both.
  What it SIGNS is chosen per recipient by `build/4` (see "Choosing the
  signing protocol" below). The verifier picks the arm by HEADER: when
  `burrow-federation-signature` is present only it is checked, over the v2
  prefix, with no fallback to a v1 header on the same request (so a bad v2
  header beside a good v1 header is `:bad_signature`); otherwise
  `suite-federation-signature` is checked over the v1 prefix; with neither,
  `:missing_signature`. The verified map's `:protocol` names the arm that
  verified.

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

  ## Choosing the signing protocol (task 01a14ba9 stage 2)

  `build/4` signs under exactly one protocol and sends exactly one signature
  header, never both. It picks v2 only when BOTH hold:

    1. `Platform.Federation.Peers.Config.signing_protocol/0` is
       `"burrow-federation/2"` (env `PEER_FEDERATION_SIGNING_PROTOCOL`, off by
       default), and
    2. the recipient is a `%Peer{}` whose `metadata["protocols"]` (stored
       from its descriptor at every fetch, see `Platform.Federation.Peers`)
       includes `"burrow-federation/2"`.

  Otherwise it signs v1. A peer with no stored list is v1-only. A bare
  install_id recipient always signs v1: the builder has no descriptor for it,
  so it cannot know the peer's version. In production every send passes a
  `%Peer{}`, including `relationship.propose`, whose pending_outbound row
  already carries the protocols of the descriptor fetched a moment before;
  the bare-id form is used by test fixtures.

  A `Platform.Federation.Peers.PeerConnection` holds the `%Peer{}` it was
  started with, so a protocols refresh reaches a running connection's sends
  only after the connection restarts (an install restart does that).

  The caller (the plug) returns only the reason atom to the peer and never
  echoes input.
  """

  alias Platform.Federation.Ed25519
  alias Platform.Federation.Peers
  alias Platform.Federation.Peers.Config
  alias Platform.Federation.Peers.InstallIdentity
  alias Platform.Federation.Peers.NonceCache
  alias Platform.Federation.Peers.Peer
  alias Platform.Federation.Peers.PeerKey

  @version 1
  # v1 is the wire id every install running core before task 01a14ba9 speaks;
  # these literals ARE that id and are not renamed. v2 is sent only per
  # `signing_version/1`.
  @prefix "suite-federation/1\n"
  @signature_header "suite-federation-signature"
  @protocol_v1 "suite-federation/1"
  @prefix_v2 "burrow-federation/2\n"
  @signature_header_v2 "burrow-federation-signature"
  @protocol_v2 "burrow-federation/2"
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
          key_status: String.t() | :payload,
          protocol: String.t()
        }

  @type protocol_version :: :v1 | :v2

  @doc "Maximum accepted body size in bytes (256 KB)."
  def max_bytes, do: @max_bytes

  @doc "Timestamp window in milliseconds (300 s either side)."
  def window_ms, do: @window_ms

  @doc "The v1 signature header (the default `build/4` sends; see `signing_version/1`)."
  def signature_header, do: signature_header(:v1)

  @doc "The header carrying the signature for protocol `:v1` or `:v2`."
  @spec signature_header(protocol_version()) :: String.t()
  def signature_header(:v1), do: @signature_header
  def signature_header(:v2), do: @signature_header_v2

  @doc "The v1 domain-separation prefix (the default; see `signing_version/1`)."
  def signing_prefix, do: signing_prefix(:v1)

  @doc "The domain-separation prefix the signature covers for `:v1` or `:v2`."
  @spec signing_prefix(protocol_version()) :: String.t()
  def signing_prefix(:v1), do: @prefix
  def signing_prefix(:v2), do: @prefix_v2

  @doc "The protocol id string for `:v1` or `:v2`."
  @spec protocol_id(protocol_version()) :: String.t()
  def protocol_id(:v1), do: @protocol_v1
  def protocol_id(:v2), do: @protocol_v2

  @doc "Every protocol id this install accepts, oldest first."
  @spec accepted_protocols() :: [String.t()]
  def accepted_protocols, do: [@protocol_v1, @protocol_v2]

  @doc "Envelope types a pending (not yet active) peer may send."
  def handshake_types, do: @handshake_types

  @doc """
  Builds a signed envelope of `type` carrying `payload` for `recipient` (a
  `%Peer{}` or a recipient install_id). Returns `{:ok, {raw_body, headers}}`.

  The signature covers the prefix of `signing_version(recipient)` and travels
  in that protocol's header alone. A bare install_id recipient always gets v1.

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
      version = signing_version(recipient)

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

      sign(fields, Keyword.get(opts, :signer), version)
    end
  end

  @doc """
  The protocol (`:v1` or `:v2`) `build/4` signs with for `recipient`. See
  "Choosing the signing protocol" in the moduledoc.
  """
  @spec signing_version(Peer.t() | String.t()) :: protocol_version()
  def signing_version(recipient) do
    if Config.signing_protocol() == @protocol_v2 and peer_speaks_v2?(recipient),
      do: :v2,
      else: :v1
  end

  defp peer_speaks_v2?(%Peer{metadata: %{"protocols" => protocols}}) when is_list(protocols),
    do: @protocol_v2 in protocols

  defp peer_speaks_v2?(_recipient), do: false

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
         {:ok, protocol} <- check_signature(raw_body, headers, public_key),
         :ok <- check_timestamp(env, now_ms),
         :ok <- NonceCache.check_and_record(env["from"], env["nonce"], env["ts"], now_ms) do
      {:ok, %{envelope: env, peer: peer, key_status: key_status, protocol: protocol}}
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

  defp sign(fields, {kid, private_key}, version)
       when is_binary(kid) and is_binary(private_key) do
    raw = Jason.encode!(fields.(kid))
    {:ok, {raw, headers(Ed25519.sign(signing_prefix(version) <> raw, private_key), version)}}
  end

  defp sign(fields, signer, version) do
    kid_opt =
      case signer do
        {:install, kid} -> kid
        _ -> nil
      end

    with {:ok, kid} <- install_kid(kid_opt) do
      raw = Jason.encode!(fields.(kid))

      with {:ok, %{signature: signature}} <-
             InstallIdentity.sign(signing_prefix(version) <> raw, kid) do
        {:ok, {raw, headers(signature, version)}}
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

  defp headers(signature, version) do
    [
      {"content-type", "application/json"},
      {signature_header(version), Base.url_encode64(signature, padding: false)}
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

  # The arm is chosen by HEADER, deterministically: a present v2 header is the
  # only one checked, so a bad v2 signature never falls back to a v1 header
  # carried on the same request.
  defp check_signature(raw, headers, public_key) do
    case {header(headers, @signature_header_v2), header(headers, @signature_header)} do
      {nil, nil} -> {:error, :missing_signature}
      {nil, v1} -> verify_signature(@prefix, raw, v1, public_key, @protocol_v1)
      {v2, _} -> verify_signature(@prefix_v2, raw, v2, public_key, @protocol_v2)
    end
  end

  defp verify_signature(prefix, raw, value, public_key, protocol) do
    with {:ok, signature} <- Base.url_decode64(value, padding: false),
         true <- Ed25519.verify(prefix <> raw, signature, public_key) do
      {:ok, protocol}
    else
      _ -> {:error, :bad_signature}
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
