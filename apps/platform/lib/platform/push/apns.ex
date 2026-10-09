defmodule Platform.Push.APNs do
  @moduledoc """
  Apple Push Notification service transport (task 01a10882 stage 2).

  Delivers a `%Platform.Push.Notification{}` to every `apns_devices` row of a
  user. It is reached only from `Platform.Push`, AFTER the archived-user check
  and the external redaction ran on the notification, so it never decides
  what a notification says, only where it goes.

  `deliver_voip_to_user/2` (task 01a10db7) is the second entry point: a
  PushKit `voip` push to every live `apns_voip_devices` row of a user, used to
  ring a meeting through CallKit. It shares this module's key, JWT cache,
  pool, retries and response handling; only the headers, body and device
  table differ.

  ## Configuration (all-or-nothing, mirroring `Platform.Push.vapid_details/0`)

  `apns_config/0` returns the four credentials or `nil`, never a part. Per
  key the order is: env var, then `Application.get_env(:platform, :apns)`,
  then Vault by slug, read with `accessor: {:system, nil}`:

  | key        | env              | app env      | Vault slug     |
  |------------|------------------|--------------|----------------|
  | `:key_id`  | `APNS_KEY_ID`    | `:key_id`    | `apns-key-id`  |
  | `:team_id` | `APNS_TEAM_ID`   | `:team_id`   | `apns-team-id` |
  | `:topic`   | `APNS_TOPIC`     | `:topic`     | `apns-topic`   |
  | `:auth_key`| `APNS_AUTH_KEY`  | `:auth_key`  | `apns-auth-key`|

  `:topic` is the iOS app's bundle id (Burrow), set per install.
  `:auth_key` is the `.p8` PEM. A partial configuration logs WHICH keys are
  missing and never a value.

  ## Secrets

  The device token, the `.p8` key, and the provider JWT are never logged,
  inspected, put in telemetry or returned. A log line names the
  `apns_devices.id` row and the APNs `reason` string only. The token appears
  in exactly one place: the request path Apple requires.

  ## Transport

  HTTP/2 through Req on the dedicated Finch pool `Platform.Push.APNsFinch`
  (started in `Platform.Application`). The host follows each device row's
  `environment`: `api.push.apple.com` for production,
  `api.sandbox.push.apple.com` for sandbox. `config :platform, :apns,
  base_url: ...` overrides both (a local stub), and
  `config :platform, :apns_req_options` is merged into every request (tests
  route it to `Req.Test`).

  A transport error (no HTTP status: `pool_not_available` on a cold or
  reconnecting pool, `closed`, `timeout`, ...) is retried after ~150, 500
  and 1500 ms (`config :platform, :apns_retry_backoff_ms`), then logged with
  its `reason` atom only. An HTTP status from APNs is never retried.

  ## Responses

    * 200 -> ok;
    * 410, or 400 with `BadDeviceToken` / `DeviceTokenNotForTopic` -> the
      device row is deleted;
    * 403 `ExpiredProviderToken` / `InvalidProviderToken` -> the cached JWT
      is dropped so the next send signs a fresh one;
    * anything else -> a warning with the row id and reason only.
  """

  import Ecto.Query

  require Logger

  alias Platform.Mobile.ApnsDevice
  alias Platform.Mobile.ApnsVoipDevice
  alias Platform.Mobile.AppSession
  alias Platform.Push.Notification
  alias Platform.Repo

  @finch Platform.Push.APNsFinch

  @production_url "https://api.push.apple.com"
  @sandbox_url "https://api.sandbox.push.apple.com"

  # Apple refuses a provider token older than 60 minutes and throttles one
  # refreshed more often than every 20. Reuse a token for 40 minutes, which
  # sits inside that window with room on both sides.
  @jwt_max_age_seconds 40 * 60
  @jwt_cache_key {__MODULE__, :provider_jwt}

  @keys [
    key_id: {"APNS_KEY_ID", "apns-key-id"},
    team_id: {"APNS_TEAM_ID", "apns-team-id"},
    topic: {"APNS_TOPIC", "apns-topic"},
    auth_key: {"APNS_AUTH_KEY", "apns-auth-key"}
  ]

  # Delays before each retry of a transport error. A cold or reconnecting
  # HTTP/2 pool answers `pool_not_available` at once while the connection to
  # APNs is still being set up, so an immediate retry fails the same way;
  # spacing the retries gives the handshake time. Overridable through
  # `config :platform, :apns_retry_backoff_ms` (tests use zeros).
  @default_retry_backoff_ms [150, 500, 1500]

  @prune_reasons ~w(BadDeviceToken DeviceTokenNotForTopic)
  @stale_jwt_reasons ~w(ExpiredProviderToken InvalidProviderToken)

  @doc "Name of the dedicated HTTP/2 Finch pool, started in `Platform.Application`."
  @spec finch_name() :: atom()
  def finch_name, do: @finch

  @doc "Default delays (ms) before each transport-error retry; the list length is the retry budget."
  @spec default_retry_backoff_ms() :: [non_neg_integer()]
  def default_retry_backoff_ms, do: @default_retry_backoff_ms

  @doc """
  Resolve the complete APNs credential set, or `nil` when ANY key is missing.
  """
  @spec apns_config() :: keyword() | nil
  def apns_config do
    resolved = resolve_all()

    if Enum.all?(resolved, fn {_k, v} -> v end), do: resolved
  end

  @doc "Whether APNs is usable for sending: exactly `apns_config() != nil`."
  @spec configured?() :: boolean()
  def configured?, do: apns_config() != nil

  @doc """
  Deliver `notification` to every APNs device of `user_id`.

  Returns `:ok`, or `{:error, :not_configured}` when the user has devices and
  the configuration is incomplete. A user with no devices costs one query and
  no configuration lookup.
  """
  @spec deliver_to_user(binary(), Notification.t()) :: :ok | {:error, :not_configured}
  def deliver_to_user(user_id, %Notification{} = notification) when is_binary(user_id) do
    case devices_for_user(user_id) do
      [] ->
        :ok

      devices ->
        case apns_config() do
          nil ->
            log_unconfigured()
            {:error, :not_configured}

          config ->
            body = Notification.to_apns_payload(notification)
            headers = alert_headers(config, notification)
            Enum.each(devices, &deliver(&1, headers, body, config))
            :ok
        end
    end
  end

  @doc """
  Ring every PushKit VoIP device of `user_id` (task 01a10db7): one `voip`
  push per `apns_voip_devices` row whose app session is not revoked.

  `payload` is the routing data the app's PushKit handler needs to report the
  CallKit call (atom or string keys; values must be JSON-encodable). The body
  sent is `{"aps": {}, ...payload, "install_host": ...}`; `install_host`
  defaults to this install's host exactly as `Platform.Push.Notification`
  does, and a value in `payload` wins. Its `ring_id`, when present, is the
  `apns-collapse-id`.

  Headers differ from an alert push in exactly the ways Apple requires of a
  VoIP push: topic `<configured topic>.voip`, push type `voip`, priority 10,
  and expiration 0 (a ring that cannot be delivered now is worthless later).
  Same provider key and cached JWT, same Finch pool, retry schedule and
  response handling as `deliver_to_user/2`; a 410 / `BadDeviceToken` /
  `DeviceTokenNotForTopic` deletes the VoIP row, never the install's alert
  row.

  Returns `:ok`, or `{:error, :not_configured}` when the user has devices and
  the configuration is incomplete.
  """
  @spec deliver_voip_to_user(binary(), map()) :: :ok | {:error, :not_configured}
  def deliver_voip_to_user(user_id, payload) when is_binary(user_id) and is_map(payload) do
    case voip_devices_for_user(user_id) do
      [] ->
        :ok

      devices ->
        case apns_config() do
          nil ->
            log_unconfigured()
            {:error, :not_configured}

          config ->
            body = voip_body(payload)
            headers = voip_headers(config, body["ring_id"])
            Enum.each(devices, &deliver(&1, headers, body, config))
            :ok
        end
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp devices_for_user(user_id) do
    if Platform.UUID.valid?(user_id) do
      Repo.all(from(d in ApnsDevice, where: d.user_id == ^user_id))
    else
      []
    end
  end

  # Only devices whose app session is live. Revoking a session deletes its
  # devices in the same transaction, so this is the belt to that pair of
  # braces: a ring must never reach a signed-out install.
  defp voip_devices_for_user(user_id) do
    if Platform.UUID.valid?(user_id) do
      Repo.all(
        from(d in ApnsVoipDevice,
          join: s in AppSession,
          on: s.id == d.app_session_id,
          where: d.user_id == ^user_id and is_nil(s.revoked_at)
        )
      )
    else
      []
    end
  end

  defp voip_body(payload) do
    routing = Map.new(payload, fn {k, v} -> {to_string(k), v} end)

    routing
    |> Map.put("aps", %{})
    |> Map.put_new_lazy("install_host", &Notification.install_host/0)
    |> then(fn
      %{"install_host" => nil} = body -> Map.delete(body, "install_host")
      body -> body
    end)
  end

  defp alert_headers(config, %Notification{} = n) do
    [
      {"apns-topic", config[:topic]},
      {"apns-push-type", "alert"},
      {"apns-priority", "10"}
    ] ++ collapse_header(n.collapse_id)
  end

  defp voip_headers(config, ring_id) do
    [
      {"apns-topic", config[:topic] <> ".voip"},
      {"apns-push-type", "voip"},
      {"apns-priority", "10"},
      {"apns-expiration", "0"}
    ] ++ collapse_header(ring_id)
  end

  defp deliver(device, headers, body, config) do
    case provider_jwt(config) do
      {:ok, jwt} ->
        attempt = fn -> request(device, headers, body, jwt) end

        attempt.()
        |> retry_transport_error(attempt, retry_backoff_ms())
        |> handle_response(device)

      :error ->
        Logger.error("[APNs] provider key could not be used to sign; device #{device.id} skipped")
    end
  end

  defp request(device, headers, body, jwt) do
    headers = [{"authorization", "bearer " <> jwt} | headers]

    options =
      [
        method: :post,
        base_url: base_url(device),
        url: "/3/device/" <> device.token,
        headers: headers,
        json: body,
        retry: false,
        finch: @finch
      ]
      |> Keyword.merge(Application.get_env(:platform, :apns_req_options, []))

    Req.request(options)
  rescue
    _ -> {:error, :request_failed}
  end

  # Bounded retries on a transport or connection error, never on an HTTP
  # status. Two cases reach here: the pool has no live connection yet (first
  # push after boot, or the HTTP/2 connection dropped while idle), which Req
  # reports as `pool_not_available` before APNs sees anything; and a stale
  # connection that fails mid-request. Finch (re)connects meanwhile, so each
  # retry waits the next delay of the backoff schedule first. Any answer from
  # APNs (a 4xx included) is final.
  defp retry_transport_error({:error, _}, again, [delay | rest]) do
    if delay > 0, do: Process.sleep(delay)
    retry_transport_error(again.(), again, rest)
  end

  defp retry_transport_error(response, _again, _schedule), do: response

  defp retry_backoff_ms do
    case Application.get_env(:platform, :apns_retry_backoff_ms) do
      list when is_list(list) -> Enum.filter(list, &(is_integer(&1) and &1 >= 0))
      _ -> @default_retry_backoff_ms
    end
  end

  defp collapse_header(id) when is_binary(id) and id != "",
    do: [{"apns-collapse-id", String.slice(id, 0, 64)}]

  defp collapse_header(_), do: []

  defp base_url(%{environment: env}) do
    case Application.get_env(:platform, :apns, [])[:base_url] do
      url when is_binary(url) and url != "" -> url
      _ -> if env == "sandbox", do: @sandbox_url, else: @production_url
    end
  end

  defp handle_response({:ok, %{status: 200}}, _device), do: :ok

  defp handle_response({:ok, %{status: 410} = resp}, device) do
    prune(device, reason(resp) || "Unregistered")
  end

  defp handle_response({:ok, %{status: 400} = resp}, device) do
    case reason(resp) do
      r when r in @prune_reasons -> prune(device, r)
      r -> warn(device, 400, r)
    end
  end

  defp handle_response({:ok, %{status: 403} = resp}, device) do
    r = reason(resp)
    if r in @stale_jwt_reasons, do: :persistent_term.erase(@jwt_cache_key)
    warn(device, 403, r)
  end

  defp handle_response({:ok, %{status: status} = resp}, device),
    do: warn(device, status, reason(resp))

  # Transport failures are reported by kind only: an exception struct or a
  # Mint error can carry the request it failed on, which holds the token, so
  # the struct is never inspected. Only the `reason` atom is printed.
  defp handle_response({:error, error}, device) do
    Logger.warning(
      "[APNs] request for device #{device.id} failed: transport_error (#{error_kind(error)})"
    )

    {:error, :transport_error}
  end

  defp error_kind(%Req.HTTPError{reason: r}) when is_atom(r), do: Atom.to_string(r)
  defp error_kind(%Req.TransportError{reason: r}) when is_atom(r), do: Atom.to_string(r)
  defp error_kind(%Req.HTTPError{}), do: "http_error"
  defp error_kind(%Req.TransportError{}), do: "transport_error"
  defp error_kind(:request_failed), do: "request_failed"
  defp error_kind(_), do: "unknown"

  # Deletes from the table the failing row came from: a dead VoIP token says
  # nothing about the install's alert token, and vice versa.
  defp prune(%schema{} = device, reason) when schema in [ApnsDevice, ApnsVoipDevice] do
    from(d in schema, where: d.id == ^device.id) |> Repo.delete_all()
    Logger.info("[APNs] device #{device.id} removed: #{reason}")
    {:error, :device_removed}
  end

  defp warn(device, status, reason) do
    Logger.warning("[APNs] device #{device.id} push returned #{status}: #{reason || "unknown"}")
    {:error, {:http_error, status}}
  end

  # APNs answers errors as `{"reason": "..."}`. Only a short identifier-shaped
  # string is ever echoed into a log.
  defp reason(%{body: %{"reason" => r}}), do: safe_reason(r)

  defp reason(%{body: body}) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, %{"reason" => r}} -> safe_reason(r)
      _ -> nil
    end
  end

  defp reason(_), do: nil

  defp safe_reason(r) when is_binary(r) do
    if Regex.match?(~r/\A[A-Za-z]{1,64}\z/, r), do: r
  end

  defp safe_reason(_), do: nil

  # ── Provider token ─────────────────────────────────────────────────────────

  # Cached per credential set: the fingerprint is a hash of the key id, team
  # id and key, so rotating any of them signs a new token at once.
  defp provider_jwt(config) do
    fingerprint = :crypto.hash(:sha256, [config[:key_id], config[:team_id], config[:auth_key]])
    now = System.system_time(:second)

    case :persistent_term.get(@jwt_cache_key, nil) do
      {^fingerprint, jwt, issued_at} when now - issued_at < @jwt_max_age_seconds ->
        {:ok, jwt}

      _ ->
        case sign(config, now) do
          {:ok, jwt} ->
            :persistent_term.put(@jwt_cache_key, {fingerprint, jwt, now})
            {:ok, jwt}

          :error ->
            :error
        end
    end
  end

  defp sign(config, now) do
    jwk = JOSE.JWK.from_pem(config[:auth_key])

    {_meta, jwt} =
      JOSE.JWT.sign(
        jwk,
        %{"alg" => "ES256", "kid" => config[:key_id]},
        %{"iss" => config[:team_id], "iat" => now}
      )
      |> JOSE.JWS.compact()

    {:ok, jwt}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  # ── Configuration ──────────────────────────────────────────────────────────

  defp resolve_all do
    app_env = Application.get_env(:platform, :apns, [])

    Enum.map(@keys, fn {key, {env_var, slug}} ->
      {key, presence(System.get_env(env_var)) || presence(app_env[key]) || vault_get(slug)}
    end)
  end

  # Neither key present is an unconfigured install: one quiet line. Some but
  # not all present is a misconfiguration: an error naming the missing keys.
  defp log_unconfigured do
    resolved = resolve_all()
    missing = for {k, nil} <- resolved, do: k

    if length(missing) == length(resolved) do
      Logger.info("[APNs] not configured, skipping native push")
    else
      Logger.error(
        "[APNs] half-configured: missing #{Enum.map_join(missing, ", ", &Atom.to_string/1)}; " <>
          "refusing to send"
      )
    end
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
