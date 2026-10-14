defmodule Platform.Push.Relay do
  @moduledoc """
  The push relay, install side (task 01a1261e stage 2): an install with no
  APNs/FCM credentials of its own reaches the Burrow app through a relay
  install (`Platform.Push.RelayServer`) instead.

  `Platform.Push` picks the transport per platform: direct credentials
  configured -> direct, exactly as before; else this relay if configured;
  else the not-configured log.

  ## Configuration (all-or-nothing, mirroring `Platform.Push.APNs.apns_config/0`)

  | key           | env                     | app env (`:push_relay`) | Vault slug              |
  |---------------|-------------------------|-------------------------|-------------------------|
  | `:url`        | `PUSH_RELAY_URL`        | `:url`                  | `push-relay-url`        |
  | `:credential` | `PUSH_RELAY_CREDENTIAL` | `:credential`           | `push-relay-credential` |

  A half configuration logs WHICH key is missing, never a value.

  ## What leaves the install

  Per device, one item: `platform`, `token`, `environment` (iOS),
  `install_host`, `unread_count`, `unread_as_of`, `sealed`, `collapse_id`.
  `sealed` is `Notification.to_fcm_payload/1`'s `"data"` map sealed to that
  device row's `push_public_key` (`Platform.Push.Seal`, aad = install_host).
  A device with no key, or a map too large to seal, gets `sealed: null`:
  NEVER plaintext. `collapse_id` is `sha256(install_host <> "|" <> id)` in
  hex, so the relay cannot read an inbox or ring id out of it either.

  Batches of at most 100 go to `<url>/api/push-relay/v1/notifications`
  through Req (`config :platform, :push_relay_req_options` is merged in;
  tests route it to `Req.Test`), retrying a transport error on the APNs
  schedule (`config :platform, :push_relay_retry_backoff_ms`). Device rows
  the relay reports `unregistered` are deleted here. Nothing logs a token,
  a blob, the credential or the url.
  """

  import Ecto.Query

  require Logger

  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.FcmDevice
  alias Platform.Push.APNs
  alias Platform.Push.FCM
  alias Platform.Push.Notification
  alias Platform.Push.Seal
  alias Platform.Repo

  @path "/api/push-relay/v1/notifications"
  @batch 100

  @keys [
    url: {"PUSH_RELAY_URL", "push-relay-url"},
    credential: {"PUSH_RELAY_CREDENTIAL", "push-relay-credential"}
  ]

  @doc "The relay url and credential, or nil when either is missing."
  @spec relay_config() :: keyword() | nil
  def relay_config do
    resolved = resolve_all()

    case for {k, nil} <- resolved, do: k do
      [] ->
        resolved

      missing when length(missing) < length(resolved) ->
        Logger.error(
          "[PushRelay] half-configured: missing #{Enum.map_join(missing, ", ", &Atom.to_string/1)}; " <>
            "relay transport off"
        )

        nil

      _ ->
        nil
    end
  end

  @doc "Whether the relay transport is usable: exactly `relay_config() != nil`."
  @spec configured?() :: boolean()
  def configured?, do: relay_config() != nil

  @doc """
  Deliver `notification` to every `platform` (`:ios` | `:android`) device of
  `user_id` through the relay. Returns `:ok` or `{:error, :not_configured}`.
  """
  @spec deliver_to_user(binary(), Notification.t(), :ios | :android) ::
          :ok | {:error, :not_configured}
  def deliver_to_user(user_id, %Notification{} = notification, platform)
      when platform in [:ios, :android] do
    case devices(user_id, platform) do
      [] ->
        :ok

      devices ->
        case relay_config() do
          nil ->
            {:error, :not_configured}

          config ->
            data = Notification.to_fcm_payload(notification)["data"]

            devices
            |> Enum.map(&{&1, item(&1, notification, data)})
            |> Enum.chunk_every(@batch)
            |> Enum.each(&post_batch(&1, config))

            :ok
        end
    end
  end

  @doc """
  The relay's collapse id for a notification collapse id: hex SHA-256 of
  `install_host <> "|" <> id` (64 characters), or nil.
  """
  @spec collapse_id(String.t() | nil, String.t() | nil) :: String.t() | nil
  def collapse_id(_host, id) when id in [nil, ""], do: nil

  def collapse_id(host, id),
    do: :crypto.hash(:sha256, "#{host}|#{id}") |> Base.encode16(case: :lower)

  # ── internals ──────────────────────────────────────────────────────────

  defp devices(user_id, :ios), do: APNs.devices_for_user(user_id)
  defp devices(user_id, :android), do: FCM.devices_for_user(user_id)

  defp item(device, %Notification{} = n, data) do
    base = %{
      "token" => device.token,
      "install_host" => n.install_host,
      "unread_count" => n.unread_count,
      "unread_as_of" => n.unread_as_of && DateTime.to_iso8601(n.unread_as_of),
      "sealed" => sealed(device.push_public_key, data, n.install_host),
      "collapse_id" => collapse_id(n.install_host, n.collapse_id)
    }

    case device do
      %ApnsDevice{environment: env} ->
        Map.merge(base, %{"platform" => "ios", "environment" => env})

      %FcmDevice{} ->
        Map.put(base, "platform", "android")
    end
  end

  # No key, no host to bind to, or too large: no preview. Never plaintext.
  defp sealed(key, data, host) when is_binary(key) and is_binary(host) and host != "" do
    case Seal.seal(key, data, host) do
      {:ok, blob} -> blob
      {:error, _} -> nil
    end
  end

  defp sealed(_key, _data, _host), do: nil

  defp post_batch(pairs, config) do
    {devices, items} = Enum.unzip(pairs)

    case request(%{"notifications" => items}, config) do
      {:ok, %{status: 200, body: %{"results" => results}}}
      when length(results) == length(devices) ->
        devices
        |> Enum.zip(results)
        |> Enum.each(fn
          {device, %{"status" => "unregistered"}} -> prune(device)
          _ -> :ok
        end)

      {:ok, %{status: status}} ->
        Logger.warning("[PushRelay] relay answered #{status} for a batch of #{length(items)}")

      {:error, error} ->
        Logger.warning(
          "[PushRelay] relay request failed: transport_error (#{error_kind(error)}) " <>
            "for a batch of #{length(items)}"
        )
    end
  end

  defp request(body, config) do
    attempt = fn -> do_request(body, config) end
    retry(attempt.(), attempt, retry_backoff_ms())
  end

  defp do_request(body, config) do
    [
      method: :post,
      url: String.trim_trailing(config[:url], "/") <> @path,
      headers: [{"authorization", "Bearer " <> config[:credential]}],
      json: body,
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:platform, :push_relay_req_options, []))
    |> Req.request()
  rescue
    _ -> {:error, :request_failed}
  end

  defp retry({:error, _}, again, [delay | rest]) do
    if delay > 0, do: Process.sleep(delay)
    retry(again.(), again, rest)
  end

  defp retry(response, _again, _schedule), do: response

  defp retry_backoff_ms do
    case Application.get_env(:platform, :push_relay_retry_backoff_ms) do
      list when is_list(list) -> Enum.filter(list, &(is_integer(&1) and &1 >= 0))
      _ -> APNs.default_retry_backoff_ms()
    end
  end

  defp error_kind(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Req.HTTPError] and is_atom(reason),
       do: Atom.to_string(reason)

  defp error_kind(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "unknown"

  defp prune(%schema{id: id}) when schema in [ApnsDevice, FcmDevice] do
    from(d in schema, where: d.id == ^id) |> Repo.delete_all()
    Logger.info("[PushRelay] device #{id} removed: unregistered")
  end

  defp resolve_all do
    app_env = Application.get_env(:platform, :push_relay, [])

    Enum.map(@keys, fn {key, {env_var, slug}} ->
      {key, presence(System.get_env(env_var)) || presence(app_env[key]) || vault_get(slug)}
    end)
  end

  defp vault_get(slug) do
    case Platform.Vault.get(slug, accessor: {:system, nil}) do
      {:ok, value} -> presence(value)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value) when is_binary(value), do: value
  defp presence(_), do: nil
end
