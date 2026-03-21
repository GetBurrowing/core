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
    if vapid_configured?() do
      subscription = %{
        endpoint: sub.endpoint,
        keys: %{p256dh: sub.p256dh, auth: sub.auth}
      }

      # VAPID keys are read from application config by the library
      # (configured in runtime.exs via :web_push_encryption, :vapid_details)
      WebPushEncryption.send_web_push(json, subscription)
    else
      Logger.warning("[Push] VAPID keys not configured, skipping push")
      {:error, :vapid_keys_missing}
    end
  end

  defp vapid_configured? do
    case Application.get_env(:web_push_encryption, :vapid_details) do
      nil -> false
      details -> details[:public_key] != nil and details[:private_key] != nil
    end
  end
end
