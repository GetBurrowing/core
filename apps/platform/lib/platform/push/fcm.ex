defmodule Platform.Push.FCM do
  @moduledoc """
  Firebase Cloud Messaging HTTP v1 transport (task 01a10d8e stage 1).

  Delivers a `%Platform.Push.Notification{}` to every `fcm_devices` row of a
  user (the Android app; its package id lives in `Platform.Mobile.FcmDevice`). Like
  `Platform.Push.APNs`, it is reached only from `Platform.Push`, AFTER the
  archived-user check and the external redaction ran on the notification, so
  it never decides what a notification says, only where it goes. The message
  is `Notification.to_fcm_payload/1`: data-only, so the app builds every
  notification itself.

  ## Configuration (all-or-nothing, mirroring `Platform.Push.APNs`)

  `fcm_config/0` returns the complete credential set or `nil`, never a part.
  Per key the order is: env var, then `Application.get_env(:platform, :fcm)`,
  then Vault by slug, read with `accessor: {:system, nil}`:

  | key                | env                        | app env            | Vault slug            |
  |--------------------|----------------------------|--------------------|-----------------------|
  | `:service_account` | `FCM_SERVICE_ACCOUNT_JSON` | `:service_account` | `fcm-service-account` |
  | `:project_id`      | `FCM_PROJECT_ID`           | `:project_id`      | `fcm-project-id`      |

  `:service_account` is the whole Google service-account JSON, stored per
  install exactly like the `apns-*` slugs. It must carry `client_email`,
  `private_key` and `token_uri`. `:project_id` falls back to the JSON's own
  `project_id`. A partial configuration logs WHICH key is missing (for a
  service account, which field of it) and never a value.

  `config :platform, :fcm` also takes `base_url:` and `token_url:` (a local
  recording stub: `clients/android/scripts/e2e/fcm_stub.py`) and
  `allowed_packages:` (read by `Platform.Mobile.FcmDevice`).

  ## Auth

  An RS256 JWT signed with the service account's key (`iss` = client_email,
  `scope` = firebase.messaging, `aud` = token_uri, one hour) is exchanged at
  the `token_uri` with grant `urn:ietf:params:oauth:grant-type:jwt-bearer`
  for an OAuth access token. The access token is cached in
  `:persistent_term` until five minutes before it expires, keyed by a hash of
  the credential set, and erased when FCM answers 401.

  ## Secrets

  Registration tokens, the service-account JSON and its private key, the
  signed JWT and the access token are never logged, inspected, put in
  telemetry or returned. A log line names the `fcm_devices.id` row and an FCM
  error status string only.

  ## Transport and responses

  `POST {base_url}/v1/projects/{project_id}/messages:send` through Req with
  `retry: false`; `config :platform, :fcm_req_options` is merged into every
  request (tests route it to `Req.Test`).

    * 200 -> ok;
    * 404 `UNREGISTERED`, or 400 `INVALID_ARGUMENT` whose details name
      `message.token` -> the device row is deleted;
    * 401 -> the cached access token is erased;
    * anything else (429, 5xx, ...) -> a warning with row id and status only.

  A transport error (no HTTP status at all: a cold or reset connection) is
  retried per `config :platform, :fcm_retry_backoff_ms` (default
  `[150, 500, 1500]`, so at most four attempts), then logged as
  `transport_error (<reason atom>)`. An HTTP status is never retried. Same
  lesson as core PR #1192 (APNs cold pool).
  """

  import Ecto.Query

  require Logger

  alias Platform.Mobile.FcmDevice
  alias Platform.Push.Notification
  alias Platform.Repo

  @default_base_url "https://fcm.googleapis.com"
  @scope "https://www.googleapis.com/auth/firebase.messaging"
  @jwt_bearer_grant "urn:ietf:params:oauth:grant-type:jwt-bearer"
  @jwt_lifetime_seconds 3600
  # Refresh an access token this long before Google says it expires.
  @token_refresh_margin_seconds 5 * 60
  @default_backoff_ms [150, 500, 1500]

  @access_token_key {__MODULE__, :access_token}

  @service_account_fields ~w(client_email private_key token_uri)

  @doc """
  Resolve the complete FCM credential set, or `nil` when ANY part is missing.

  Returns `[project_id:, client_email:, private_key:, token_uri:]`. Never log
  or inspect the result: it holds the private key.
  """
  @spec fcm_config() :: keyword() | nil
  def fcm_config do
    case resolve() do
      {:ok, config} -> config
      {:missing, _missing} -> nil
    end
  end

  @doc "Whether FCM is usable for sending: exactly `fcm_config() != nil`."
  @spec configured?() :: boolean()
  def configured?, do: fcm_config() != nil

  @doc """
  Deliver `notification` to every FCM device of `user_id`.

  Returns `:ok`, or `{:error, :not_configured}` when the user has devices and
  the configuration is incomplete. A user with no devices costs one query and
  no configuration lookup.

  `opts`: `quiet_unconfigured: true` skips the not-configured log line.
  """
  @spec deliver_to_user(binary(), Notification.t(), keyword()) :: :ok | {:error, :not_configured}
  def deliver_to_user(user_id, %Notification{} = notification, opts \\ [])
      when is_binary(user_id) do
    case devices_for_user(user_id) do
      [] ->
        :ok

      devices ->
        case resolve() do
          {:missing, missing} ->
            # `quiet_unconfigured: true` (task 01a1261e): the caller tries
            # the push relay next and logs only if that is absent too.
            unless opts[:quiet_unconfigured], do: log_unconfigured(missing)
            {:error, :not_configured}

          {:ok, config} ->
            message = Notification.to_fcm_payload(notification)
            Enum.each(devices, &deliver(&1, message, config))
            :ok
        end
    end
  end

  @doc """
  Send one v1 `message` (without `token`) to one registration token (task
  01a1261e stage 2): the per-token core of `deliver_to_user/2`, shared with
  the push relay, which holds no device rows.

  `target` carries `:token`. Same OAuth access-token cache, transport retry
  schedule and response classification as `deliver_to_user/2`; `label`
  names the target in log lines (never the token).

  Returns `:ok`, `{:error, :unregistered}` (404 `UNREGISTERED`, or 400
  `INVALID_ARGUMENT` naming `message.token`), or `{:error, reason}`. It
  deletes nothing.
  """
  @spec send_to_token(map(), map(), keyword(), String.t()) ::
          :ok | {:error, :unregistered | term()}
  def send_to_token(target, message, config, label \\ "relay target") do
    case do_send(target, message, config, label) do
      {:unregistered, _reason} -> {:error, :unregistered}
      other -> other
    end
  end

  @doc """
  Resolve the FCM credential set (`{:ok, config}`) or `:error`, logging
  nothing. The relay resolves once per batch.
  """
  @spec resolve_config() :: {:ok, keyword()} | :error
  def resolve_config do
    case resolve() do
      {:ok, config} -> {:ok, config}
      {:missing, _} -> :error
    end
  end

  @doc false
  # Public for `Platform.Push`: logs the not-configured line (which keys are
  # missing, never a value) when neither FCM nor the push relay is set up.
  def report_unconfigured do
    case resolve() do
      {:missing, missing} -> log_unconfigured(missing)
      {:ok, _} -> :ok
    end
  end

  @doc """
  The user's `fcm_devices` rows (the query `deliver_to_user/2` sends to).
  Public so `Platform.Push.Relay` addresses exactly the same set.
  """
  @spec devices_for_user(binary()) :: [FcmDevice.t()]
  def devices_for_user(user_id) do
    if Platform.UUID.valid?(user_id) do
      Repo.all(from(d in FcmDevice, where: d.user_id == ^user_id))
    else
      []
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp deliver(%FcmDevice{} = device, message, config) do
    case do_send(device, message, config, "device #{device.id}") do
      {:unregistered, reason} -> prune(device, reason)
      other -> other
    end
  end

  defp do_send(target, message, config, label) do
    case access_token(config) do
      {:ok, access_token} ->
        fn -> request(target, message, config, access_token) end
        |> with_transport_retry()
        |> handle_response(label)

      {:error, reason} ->
        Logger.error("[FCM] no access token (#{reason}); #{label} skipped")
        {:error, :no_access_token}
    end
  end

  defp request(device, message, config, access_token) do
    options =
      [
        method: :post,
        base_url: base_url(),
        url: "/v1/projects/#{config[:project_id]}/messages:send",
        headers: [{"authorization", "Bearer " <> access_token}],
        json: %{"message" => Map.put(message, "token", device.token)},
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:platform, :fcm_req_options, []))

    Req.request(options)
  rescue
    _ -> {:error, :request_failed}
  end

  # Retry ONLY a transport error (no HTTP status), per the backoff schedule.
  # A pooled connection to Google goes stale when idle; the first request on
  # it fails before FCM sees it, and the pool opens a fresh one. Any HTTP
  # answer, a 4xx or 5xx included, is final here.
  defp with_transport_retry(fun) do
    backoff = Application.get_env(:platform, :fcm_retry_backoff_ms, @default_backoff_ms)
    attempt_with_backoff(fun, backoff)
  end

  defp attempt_with_backoff(fun, backoff) do
    case fun.() do
      {:error, _} = error ->
        case backoff do
          [] ->
            error

          [ms | rest] ->
            if is_integer(ms) and ms > 0, do: Process.sleep(ms)
            attempt_with_backoff(fun, rest)
        end

      response ->
        response
    end
  end

  defp base_url do
    case fcm_app_env()[:base_url] do
      url when is_binary(url) and url != "" -> url
      _ -> @default_base_url
    end
  end

  defp handle_response({:ok, %{status: 200}}, _label), do: :ok

  defp handle_response({:ok, %{status: 404} = resp}, label) do
    case error_code(resp) do
      "UNREGISTERED" -> {:unregistered, "UNREGISTERED"}
      _ -> warn(label, 404, error_status(resp))
    end
  end

  defp handle_response({:ok, %{status: 400} = resp}, label) do
    if names_token?(resp),
      do: {:unregistered, "INVALID_ARGUMENT"},
      else: warn(label, 400, error_status(resp))
  end

  defp handle_response({:ok, %{status: 401} = resp}, label) do
    :persistent_term.erase(@access_token_key)
    warn(label, 401, error_status(resp))
  end

  defp handle_response({:ok, %{status: status} = resp}, label),
    do: warn(label, status, error_status(resp))

  # Transport failures are reported by the reason atom only: the exception
  # struct can carry the request it failed on, which holds the token.
  defp handle_response({:error, reason}, label) do
    Logger.warning("[FCM] request for #{label} failed: transport_error (#{reason_atom(reason)})")

    {:error, :transport_error}
  end

  defp reason_atom(%{__struct__: struct, reason: reason})
       when struct in [Req.TransportError, Req.HTTPError] and is_atom(reason),
       do: Atom.to_string(reason)

  defp reason_atom(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_atom(_), do: "unknown"

  defp prune(device, reason) do
    from(d in FcmDevice, where: d.id == ^device.id) |> Repo.delete_all()
    Logger.info("[FCM] device #{device.id} removed: #{reason}")
    {:error, :device_removed}
  end

  defp warn(label, status, reason) do
    Logger.warning("[FCM] #{label} push returned #{status}: #{reason || "unknown"}")
    {:error, {:http_error, status}}
  end

  # FCM v1 answers errors as google.rpc.Status:
  #   {"error": {"code", "message", "status", "details": [...]}}
  # Only the identifier-shaped `status` and FcmError `errorCode` strings are
  # ever echoed into a log; `message` is free text and never is.
  defp error_body(%{body: %{"error" => %{} = error}}), do: error

  defp error_body(%{body: body}) when is_binary(body) and body != "" do
    case Jason.decode(body) do
      {:ok, %{"error" => %{} = error}} -> error
      _ -> %{}
    end
  end

  defp error_body(_), do: %{}

  defp error_status(resp), do: resp |> error_body() |> Map.get("status") |> safe_identifier()

  defp error_code(resp) do
    resp
    |> details()
    |> Enum.find_value(fn
      %{"errorCode" => code} -> safe_identifier(code)
      _ -> nil
    end)
  end

  defp names_token?(resp) do
    error_status(resp) == "INVALID_ARGUMENT" and
      resp
      |> details()
      |> Enum.any?(fn
        %{"fieldViolations" => violations} when is_list(violations) ->
          Enum.any?(violations, &match?(%{"field" => "message.token"}, &1))

        _ ->
          false
      end)
  end

  defp details(resp) do
    case error_body(resp) do
      %{"details" => details} when is_list(details) -> details
      _ -> []
    end
  end

  defp safe_identifier(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Z_]{1,64}\z/, value), do: value
  end

  defp safe_identifier(_), do: nil

  # ── Access token ───────────────────────────────────────────────────────────

  # Cached per credential set: rotating the key, the account or the token
  # endpoint fetches a new token at once.
  defp access_token(config) do
    fingerprint =
      :crypto.hash(:sha256, [config[:client_email], config[:private_key], config[:token_uri]])

    now = System.system_time(:second)

    case :persistent_term.get(@access_token_key, nil) do
      {^fingerprint, token, expires_at} when now < expires_at - @token_refresh_margin_seconds ->
        {:ok, token}

      _ ->
        with {:ok, jwt} <- sign(config, now),
             {:ok, token, expires_in} <- exchange(jwt, config) do
          :persistent_term.put(@access_token_key, {fingerprint, token, now + expires_in})
          {:ok, token}
        end
    end
  end

  defp sign(config, now) do
    jwk = JOSE.JWK.from_pem(config[:private_key])

    {_meta, jwt} =
      JOSE.JWT.sign(
        jwk,
        %{"alg" => "RS256", "typ" => "JWT"},
        %{
          "iss" => config[:client_email],
          "scope" => @scope,
          "aud" => config[:token_uri],
          "iat" => now,
          "exp" => now + @jwt_lifetime_seconds
        }
      )
      |> JOSE.JWS.compact()

    {:ok, jwt}
  rescue
    _ -> {:error, "private key could not be used to sign"}
  catch
    _, _ -> {:error, "private key could not be used to sign"}
  end

  defp exchange(jwt, config) do
    url =
      case fcm_app_env()[:token_url] do
        url when is_binary(url) and url != "" -> url
        _ -> config[:token_uri]
      end

    fn -> token_request(url, jwt) end
    |> with_transport_retry()
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => token} = body}}
      when is_binary(token) and token != "" ->
        {:ok, token, expires_in(body)}

      {:ok, %{status: status}} ->
        {:error, "token endpoint returned #{status}"}

      {:error, reason} ->
        {:error, "token endpoint transport_error (#{reason_atom(reason)})"}
    end
  end

  defp token_request(url, jwt) do
    [
      method: :post,
      url: url,
      form: [grant_type: @jwt_bearer_grant, assertion: jwt],
      retry: false
    ]
    |> Keyword.merge(Application.get_env(:platform, :fcm_req_options, []))
    |> Req.request()
  rescue
    _ -> {:error, :request_failed}
  end

  defp expires_in(%{"expires_in" => seconds}) when is_integer(seconds) and seconds > 0,
    do: seconds

  defp expires_in(_), do: @jwt_lifetime_seconds

  # ── Configuration ──────────────────────────────────────────────────────────

  defp fcm_app_env, do: Application.get_env(:platform, :fcm, [])

  defp resolve do
    app_env = fcm_app_env()

    raw_account =
      presence(System.get_env("FCM_SERVICE_ACCOUNT_JSON")) ||
        presence(app_env[:service_account]) || vault_get("fcm-service-account")

    explicit_project =
      presence(System.get_env("FCM_PROJECT_ID")) || presence(app_env[:project_id]) ||
        vault_get("fcm-project-id")

    case decode_account(raw_account) do
      :absent ->
        {:missing, [:service_account]}

      :unparseable ->
        {:missing, [:"service_account (not a JSON object)"]}

      {:ok, account} ->
        project_id = explicit_project || presence(account["project_id"])

        missing =
          for(
            field <- @service_account_fields,
            !presence(account[field]),
            do: :"service_account.#{field}"
          ) ++ if(project_id, do: [], else: [:project_id])

        if missing == [] do
          {:ok,
           [
             project_id: project_id,
             client_email: account["client_email"],
             private_key: account["private_key"],
             token_uri: account["token_uri"]
           ]}
        else
          {:missing, missing}
        end
    end
  end

  defp decode_account(nil), do: :absent

  defp decode_account(%{} = map), do: {:ok, Map.new(map, fn {k, v} -> {to_string(k), v} end)}

  defp decode_account(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> :unparseable
    end
  end

  # Nothing at all is an unconfigured install: one quiet line. A service
  # account with a hole, or a project id with no account, is a
  # misconfiguration: an error naming the missing parts, never a value.
  defp log_unconfigured([:service_account]) do
    if unconfigured?() do
      Logger.info("[FCM] not configured, skipping Android push")
    else
      Logger.error("[FCM] half-configured: missing service_account; refusing to send")
    end
  end

  defp log_unconfigured(missing) do
    Logger.error(
      "[FCM] half-configured: missing #{Enum.map_join(missing, ", ", &Atom.to_string/1)}; " <>
        "refusing to send"
    )
  end

  defp unconfigured? do
    app_env = fcm_app_env()

    is_nil(
      presence(System.get_env("FCM_PROJECT_ID")) || presence(app_env[:project_id]) ||
        vault_get("fcm-project-id")
    )
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
  defp presence(%{} = value) when map_size(value) > 0, do: value
  defp presence(_), do: nil
end
