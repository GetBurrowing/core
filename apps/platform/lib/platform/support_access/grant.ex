defmodule Platform.SupportAccess.Grant do
  @moduledoc """
  Verifies a vendor support grant request (task 01a1b362 stage 1, ADR 0059).
  The shape follows `Platform.Federation.Peers.Envelope.verify/3`: a raw JSON
  body, an Ed25519 signature in a header over a fixed prefix plus the raw
  bytes, and a persisted replay check.

  ## Wire format

  Body, canonical JSON (the bytes are what is signed, so the receiver never
  re-encodes):

      {"install_id": "...", "kind": "admin" | "repair",
       "operator": {"name": "...", "email": "..."},
       "duration_s": 3600, "nonce": "...",
       "issued_at": 1794000000, "expires_at": 1794000120, "kid": "..."}

  `issued_at` and `expires_at` are unix seconds. Header
  `x-burrow-support-signature`: base64url (no padding) of the Ed25519
  signature over `"burrow-support-grant/1\\n" <> raw_body`, checked against
  the public key `kid` names in `SUPPORT_VENDOR_KEYS`.

  ## Refusal order

  Each refusal has its own reason atom and HTTP status (`status_for/1`):

    1. no keys configured          -> `:not_found` 404 (the route is absent)
    2. bad signature / unknown kid -> `:bad_signature` 401
       (a signed body that is not a grant -> `:malformed_grant` 400)
    3. another install's id        -> `:wrong_install` 421
    4. expired, or valid > 300 s   -> `:grant_expired` 410
    5. nonce already used          -> `:replayed_nonce` 409
    6. `duration_s` over the cap   -> `:duration_too_long` 422
    7. the owner's switch is off   -> `:support_access_off` 403

  Steps 3 onward run only for a validly signed request; `signed?/1` tells the
  caller which side of that line a refusal is on, because only signed
  requests are audited.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Federation.Ed25519
  alias Platform.Repo
  alias Platform.SupportAccess.Config
  alias Platform.SupportAccess.GrantNonce
  alias Platform.SupportAccess.Settings

  @prefix "burrow-support-grant/1\n"
  @signature_header "x-burrow-support-signature"
  @max_bytes 16 * 1024

  @type grant :: %{
          install_id: String.t(),
          kind: String.t(),
          operator_name: String.t(),
          operator_email: String.t(),
          duration_s: pos_integer(),
          nonce: String.t(),
          issued_at: integer(),
          expires_at: integer(),
          kid: String.t()
        }

  def prefix, do: @prefix
  def signature_header, do: @signature_header
  def max_bytes, do: @max_bytes

  @doc "HTTP status for a refusal reason."
  @spec status_for(atom()) :: pos_integer()
  def status_for(:not_found), do: 404
  def status_for(:bad_signature), do: 401
  def status_for(:malformed_grant), do: 400
  def status_for(:wrong_install), do: 421
  def status_for(:grant_expired), do: 410
  def status_for(:replayed_nonce), do: 409
  def status_for(:duration_too_long), do: 422
  def status_for(:support_access_off), do: 403
  def status_for(:operator_email_taken), do: 400
  def status_for(:too_large), do: 413
  def status_for(:rate_limited), do: 429
  def status_for(_), do: 400

  @doc "Whether a refusal happened after the signature verified."
  @spec signed?(atom()) :: boolean()
  def signed?(reason), do: reason not in [:not_found, :bad_signature, :too_large, :rate_limited]

  @doc """
  Verifies `raw` against `headers` at `now` (a `DateTime`). Returns
  `{:ok, grant}` or `{:error, reason}`; on `{:error, reason}` with
  `signed?(reason)`, the second element of `{:error, reason, grant}` carries
  what was verified so the refusal can be audited.
  """
  @spec verify(binary(), [{String.t(), String.t()}], DateTime.t()) ::
          {:ok, grant()} | {:error, atom()} | {:error, atom(), map()}
  def verify(raw, headers, %DateTime{} = now) when is_binary(raw) do
    with :ok <- check_configured(),
         {:ok, map} <- check_signature(raw, headers),
         {:ok, grant} <- check_shape(map) do
      case check_signed(grant, now) do
        :ok -> {:ok, grant}
        {:error, reason} -> {:error, reason, grant}
      end
    else
      {:error, :malformed_grant} -> {:error, :malformed_grant, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_signed(grant, now) do
    with :ok <- check_install(grant),
         :ok <- check_window(grant, now),
         :ok <- check_nonce(grant),
         :ok <- check_duration(grant) do
      check_enabled()
    end
  end

  defp check_configured do
    if Config.configured?(), do: :ok, else: {:error, :not_found}
  end

  defp check_signature(raw, headers) do
    with {:ok, %{"kid" => kid} = map} when is_binary(kid) <- decode(raw),
         {:ok, public_key} <- Map.fetch(Config.vendor_keys(), kid),
         value when is_binary(value) <- header(headers, @signature_header),
         {:ok, signature} <- Base.url_decode64(String.trim_trailing(value, "="), padding: false),
         true <- Ed25519.verify(@prefix <> raw, signature, public_key) do
      {:ok, map}
    else
      _ -> {:error, :bad_signature}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp check_shape(%{
         "install_id" => install_id,
         "kind" => kind,
         "operator" => %{"name" => name, "email" => email},
         "duration_s" => duration_s,
         "nonce" => nonce,
         "issued_at" => issued_at,
         "expires_at" => expires_at,
         "kid" => kid
       })
       when is_binary(install_id) and kind in ["admin", "repair"] and is_binary(name) and
              is_binary(email) and is_integer(duration_s) and duration_s > 0 and
              is_binary(nonce) and is_integer(issued_at) and is_integer(expires_at) do
    name = String.trim(name)
    email = email |> String.trim() |> String.downcase()

    if name != "" and String.length(name) <= 200 and Regex.match?(~r/^[^\s@]+@[^\s@]+$/, email) and
         byte_size(email) <= 254 and byte_size(nonce) in 16..128 do
      {:ok,
       %{
         install_id: install_id,
         kind: kind,
         operator_name: name,
         operator_email: email,
         duration_s: duration_s,
         nonce: nonce,
         issued_at: issued_at,
         expires_at: expires_at,
         kid: kid
       }}
    else
      {:error, :malformed_grant}
    end
  end

  defp check_shape(_), do: {:error, :malformed_grant}

  defp check_install(%{install_id: install_id}) do
    case Config.install_id() do
      ^install_id -> :ok
      _ -> {:error, :wrong_install}
    end
  end

  defp check_window(%{issued_at: issued_at, expires_at: expires_at}, now) do
    now_s = DateTime.to_unix(now)

    cond do
      expires_at <= now_s -> {:error, :grant_expired}
      expires_at - issued_at > Config.max_validity_s() -> {:error, :grant_expired}
      expires_at < issued_at -> {:error, :grant_expired}
      true -> :ok
    end
  end

  # Persisted, so a replay is refused across restarts. The insert is the
  # check: of two concurrent requests with one nonce, one insert wins.
  defp check_nonce(%{nonce: nonce, expires_at: expires_at}) do
    {count, _} =
      Repo.insert_all(
        GrantNonce,
        [%{nonce: nonce, expires_at: DateTime.from_unix!(expires_at * 1_000_000, :microsecond)}],
        on_conflict: :nothing,
        conflict_target: :nonce
      )

    if count == 1, do: :ok, else: {:error, :replayed_nonce}
  end

  defp check_duration(%{duration_s: duration_s}) do
    if duration_s <= Config.max_duration_s(), do: :ok, else: {:error, :duration_too_long}
  end

  defp check_enabled do
    if Settings.enabled?(), do: :ok, else: {:error, :support_access_off}
  end

  @doc "Deletes nonces whose grant has expired. Returns the count."
  @spec prune_nonces(DateTime.t()) :: non_neg_integer()
  def prune_nonces(now) do
    {count, _} = Repo.delete_all(from(n in GrantNonce, where: n.expires_at <= ^now))
    count
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == name and is_binary(v) and v != "", do: v
    end)
  end
end
