defmodule Platform.Push do
  @moduledoc """
  Web Push notification context.

  Manages push subscriptions and sends notifications via the Web Push protocol.
  VAPID keys are read from `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` env vars,
  falling back to Vault lookup by slugs `"vapid-public-key"` / `"vapid-private-key"`.
  """

  import Ecto.Query

  require Logger

  alias Platform.Push.Subscription
  alias Platform.Repo

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Upsert a push subscription for a participant."
  @spec subscribe(binary(), map()) :: {:ok, Subscription.t()} | {:error, Ecto.Changeset.t()}
  def subscribe(participant_id, %{endpoint: endpoint, keys: %{p256dh: p256dh, auth: auth}}) do
    attrs = %{
      participant_id: participant_id,
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth
    }

    %Subscription{}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth]},
      conflict_target: [:participant_id, :endpoint]
    )
  end

  @doc "Remove a push subscription by participant and endpoint."
  @spec unsubscribe(binary(), String.t()) :: {non_neg_integer(), nil}
  def unsubscribe(participant_id, endpoint) do
    from(s in Subscription,
      where: s.participant_id == ^participant_id and s.endpoint == ^endpoint
    )
    |> Repo.delete_all()
  end

  @doc "Send a web push notification to all subscriptions for a participant."
  @spec send_notification(binary(), map()) :: :ok
  def send_notification(participant_id, %{title: _, body: _} = payload) do
    subscriptions =
      from(s in Subscription, where: s.participant_id == ^participant_id)
      |> Repo.all()

    json = Jason.encode!(payload)

    Enum.each(subscriptions, fn sub ->
      case do_send_push(sub, json) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("[Push] failed to send to #{sub.endpoint}: #{inspect(reason)}")
      end
    end)
  end

  @doc "List all push subscriptions for a participant."
  @spec list_subscriptions(binary()) :: [Subscription.t()]
  def list_subscriptions(participant_id) do
    from(s in Subscription, where: s.participant_id == ^participant_id)
    |> Repo.all()
  end

  @doc "Return the VAPID public key for use in client-side subscription."
  @spec vapid_public_key() :: String.t() | nil
  def vapid_public_key do
    case System.get_env("VAPID_PUBLIC_KEY") do
      nil -> vault_get("vapid-public-key")
      key -> key
    end
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  defp vapid_private_key do
    case System.get_env("VAPID_PRIVATE_KEY") do
      nil -> vault_get("vapid-private-key")
      key -> key
    end
  end

  defp vault_get(slug) do
    case Platform.Vault.get(slug) do
      {:ok, value} -> value
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp do_send_push(sub, json) do
    vapid = Application.get_env(:web_push_encryption, :vapid_details)

    unless vapid do
      Logger.warning("[Push] VAPID keys not configured, skipping push")
      {:error, :vapid_keys_missing}
    else
      try do
        encrypted =
          WebPushEncryption.Encrypt.encrypt(json, %{
            keys: %{p256dh: sub.p256dh, auth: sub.auth}
          })

        audience = URI.parse(sub.endpoint) |> then(&"#{&1.scheme}://#{&1.host}")
        jwt = build_vapid_jwt(audience, vapid)
        public_key_b64 = Keyword.get(vapid, :public_key)

        salt_b64 = Base.url_encode64(encrypted.salt, padding: false)
        server_key_b64 = Base.url_encode64(encrypted.server_public_key, padding: false)

        headers = [
          {"Content-Encoding", "aesgcm"},
          {"Encryption", "salt=#{salt_b64}"},
          {"Crypto-Key", "dh=#{server_key_b64};p256ecdsa=#{public_key_b64}"},
          {"Authorization", "vapid t=#{jwt}, k=#{public_key_b64}"},
          {"TTL", "86400"}
        ]

        case Req.post(sub.endpoint, body: encrypted.ciphertext, headers: headers) do
          {:ok, %{status: status}} when status in [200, 201, 202] ->
            {:ok, %{status: status}}

          {:ok, %{status: 410}} ->
            Logger.info("[Push] subscription gone (410): #{sub.endpoint}")
            unsubscribe(sub.participant_id, sub.endpoint)
            {:error, :subscription_expired}

          {:ok, %{status: status, body: body}} ->
            Logger.warning("[Push] push returned #{status}: #{inspect(body)}")
            {:error, {:http_error, status}}

          {:error, reason} ->
            Logger.warning("[Push] request failed: #{inspect(reason)}")
            {:error, reason}
        end
      rescue
        e ->
          Logger.warning("[Push] send failed: #{Exception.message(e)}")
          {:error, :send_failed}
      end
    end
  end

  defp build_vapid_jwt(audience, vapid) do
    private_key_raw =
      Base.url_decode64!(Keyword.get(vapid, :private_key), padding: false)

    header =
      Base.url_encode64(Jason.encode!(%{typ: "JWT", alg: "ES256"}), padding: false)

    claims =
      Base.url_encode64(
        Jason.encode!(%{
          aud: audience,
          exp: System.system_time(:second) + 86_400,
          sub: Keyword.get(vapid, :subject)
        }),
        padding: false
      )

    signing_input = "#{header}.#{claims}"

    der_sig =
      :crypto.sign(:ecdsa, :sha256, signing_input, [private_key_raw, :secp256r1])

    raw_sig = der_to_raw_ecdsa(der_sig)
    "#{signing_input}.#{Base.url_encode64(raw_sig, padding: false)}"
  end

  # Convert DER-encoded ECDSA signature to raw r||s (64 bytes)
  defp der_to_raw_ecdsa(<<48, _, 2, r_len, rest::binary>>) do
    <<r_bytes::binary-size(r_len), 2, s_len, s_bytes::binary-size(s_len), _::binary>> = rest
    pad_to_32(r_bytes) <> pad_to_32(s_bytes)
  end

  defp pad_to_32(bytes) when byte_size(bytes) >= 32,
    do: binary_part(bytes, byte_size(bytes) - 32, 32)

  defp pad_to_32(bytes),
    do: :binary.copy(<<0>>, 32 - byte_size(bytes)) <> bytes

  defp vapid_configured? do
    case Application.get_env(:web_push_encryption, :vapid_details) do
      nil -> false
      details -> details[:public_key] != nil and details[:private_key] != nil
    end
  end
end
