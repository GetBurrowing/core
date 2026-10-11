defmodule Platform.Push.RelayServer do
  @moduledoc """
  The push relay, relay side (task 01a1261e stage 2).

  A Burrow-operated install runs the same image with `PUSH_RELAY_SERVER=true`
  (`config :platform, :push_relay_server, enabled: true`). It then accepts
  `POST /api/push-relay/v1/notifications` from registered installs
  (`Platform.Push.RelayInstall`, bearer credential) and forwards each item
  to APNs or FCM with ITS OWN provider credentials, through the same
  per-token sends direct push uses (`APNs.send_to_token/5`,
  `FCM.send_to_token/4`). Off by default: every relay route is a 404 on a
  normal install.

  ## No plaintext crosses the relay, structurally

  Each item is a STRICT allow-list (`@allowed`): `platform`, `token`,
  `environment`, `install_host`, `unread_count`, `unread_as_of`, `sealed`,
  `collapse_id`. Any other key is refused (`{:unknown_field, key}`), so
  there is no field a title, body, author or space name could travel in.
  `sealed` is an HPKE blob (`Platform.Push.Seal`) only the device can open.
  The relay builds the provider body itself: a CONSTANT APNs alert
  ("Burrow" / "New notification", `mutable-content: 1` so the iOS NSE runs
  and decrypts) and a data-only FCM message.

  ## Nothing is stored, nothing sensitive is logged

  The relay persists only `push_relay_installs` rows. Log lines carry the
  install id, platform counts and result counts: never a request body, a
  token, a sealed blob, or any install-supplied string (an unknown key is
  echoed to the CALLER, never logged).

  ## Credentials never leave the relay

  Responses carry only `{"results": [{"status": ...}]}` or an error code.
  The APNs topic is the relay's configured one, never the caller's.
  """

  import Ecto.Query

  require Logger

  alias Platform.Push.APNs
  alias Platform.Push.FCM
  alias Platform.Push.RelayInstall
  alias Platform.Push.RelayRateLimit
  alias Platform.Push.Seal
  alias Platform.Repo

  @allowed ~w(platform token environment install_host unread_count unread_as_of sealed collapse_id)
  @max_items 100
  @default_rate_per_minute 1200
  @touch_interval_seconds 60

  @alert %{"title" => "Burrow", "body" => "New notification"}

  @apns_token ~r/\A[0-9A-Fa-f]{16,200}\z/
  @fcm_token ~r/\A[A-Za-z0-9_:\-]{20,4096}\z/
  @host ~r/\A[A-Za-z0-9.\-]{1,253}(:[0-9]{1,5})?\z/
  @base64url ~r/\A[A-Za-z0-9_-]+\z/

  @doc "The allow-listed item keys."
  @spec allowed_fields() :: [String.t()]
  def allowed_fields, do: @allowed

  @doc "The largest batch accepted."
  @spec max_items() :: pos_integer()
  def max_items, do: @max_items

  @doc "Whether this install runs relay mode."
  @spec enabled?() :: boolean()
  def enabled?, do: server_config()[:enabled] == true

  @doc "Items per install per minute."
  @spec rate_per_minute() :: pos_integer()
  def rate_per_minute do
    case server_config()[:rate_per_minute] do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_rate_per_minute
    end
  end

  defp server_config, do: Application.get_env(:platform, :push_relay_server, [])

  # ── installs ─────────────────────────────────────────────────────────────

  @doc """
  Register an install. Returns `{:ok, install, credential}`; the raw
  credential exists only in this return value.
  """
  @spec create_install(String.t(), String.t()) ::
          {:ok, RelayInstall.t(), String.t()} | {:error, Ecto.Changeset.t()}
  def create_install(name, host) do
    credential = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    %RelayInstall{}
    |> RelayInstall.changeset(%{name: name, host: host, credential_hash: hash(credential)})
    |> Repo.insert(log: false)
    |> case do
      {:ok, install} -> {:ok, install, credential}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Revoke an install by id. Idempotent; `{:error, :not_found}` for an unknown id."
  @spec revoke_install(String.t()) :: {:ok, RelayInstall.t()} | {:error, :not_found}
  def revoke_install(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %RelayInstall{} = install <-
           Repo.one(from(i in RelayInstall, where: i.id == ^id)) do
      install
      |> Ecto.Changeset.change(revoked_at: install.revoked_at || DateTime.utc_now())
      |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  The non-revoked install holding `credential`, or `:error`. Hash lookup
  only; the query is `log: false` so not even the hash reaches a debug log.
  """
  @spec verify_credential(String.t()) :: {:ok, RelayInstall.t()} | :error
  def verify_credential(credential) when is_binary(credential) and credential != "" do
    digest = hash(credential)

    case Repo.one(from(i in RelayInstall, where: i.credential_hash == ^digest), log: false) do
      %RelayInstall{revoked_at: nil} = install -> {:ok, install}
      _ -> :error
    end
  end

  def verify_credential(_), do: :error

  defp hash(raw), do: :crypto.hash(:sha256, raw)

  # ── validation ───────────────────────────────────────────────────────────

  @doc """
  Validate a request body. Returns `{:ok, items}` or an error naming at
  most a FIELD (never a value): `{:unknown_field, key}`, `{:invalid_field,
  key, index}`, `:too_many`, `:invalid_body`.
  """
  @spec validate(term()) ::
          {:ok, [map()]}
          | {:error,
             :invalid_body
             | :too_many
             | {:unknown_field, String.t()}
             | {:invalid_field, String.t(), non_neg_integer()}}
  def validate(%{"notifications" => items} = body) when is_list(items) do
    case Map.keys(body) -- ["notifications"] do
      [key | _] -> {:error, {:unknown_field, key}}
      [] when length(items) > @max_items -> {:error, :too_many}
      [] -> validate_items(items)
    end
  end

  def validate(_), do: {:error, :invalid_body}

  defp validate_items(items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {item, index}, {:ok, acc} ->
      case validate_item(item, index) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp validate_item(item, index) when is_map(item) do
    case Enum.find(Map.keys(item), &(&1 not in @allowed)) do
      nil -> check_fields(item, index)
      key -> {:error, {:unknown_field, to_string(key)}}
    end
  end

  defp validate_item(_item, index), do: {:error, {:invalid_field, "notifications", index}}

  defp check_fields(item, index) do
    checks = [
      {"platform", item["platform"] in ["ios", "android"]},
      {"token", valid_token?(item["platform"], item["token"])},
      {"environment", valid_environment?(item["platform"], item["environment"])},
      {"install_host", is_binary(item["install_host"]) and item["install_host"] =~ @host},
      {"unread_count", is_nil(item["unread_count"]) or non_neg_int?(item["unread_count"])},
      {"unread_as_of", is_nil(item["unread_as_of"]) or iso8601?(item["unread_as_of"])},
      {"sealed", is_nil(item["sealed"]) or valid_sealed?(item["sealed"])},
      {"collapse_id", is_nil(item["collapse_id"]) or valid_collapse?(item["collapse_id"])}
    ]

    case Enum.find(checks, fn {_field, ok} -> not ok end) do
      nil -> {:ok, item}
      {field, _} -> {:error, {:invalid_field, field, index}}
    end
  end

  defp valid_token?("ios", t) when is_binary(t), do: t =~ @apns_token
  defp valid_token?("android", t) when is_binary(t), do: t =~ @fcm_token
  defp valid_token?(_, _), do: false

  defp valid_environment?("ios", env), do: env in ["sandbox", "production"]
  defp valid_environment?(_, env), do: is_nil(env)

  defp non_neg_int?(n), do: is_integer(n) and n >= 0

  defp iso8601?(s) when is_binary(s), do: match?({:ok, _, _}, DateTime.from_iso8601(s))
  defp iso8601?(_), do: false

  defp valid_sealed?(s) when is_binary(s),
    do: byte_size(s) <= Seal.max_blob_bytes() and s =~ @base64url

  defp valid_sealed?(_), do: false

  defp valid_collapse?(s) when is_binary(s), do: s != "" and String.length(s) <= 64
  defp valid_collapse?(_), do: false

  # ── rate limit ───────────────────────────────────────────────────────────

  @doc "Count a batch against the install's window."
  @spec check_rate(RelayInstall.t(), non_neg_integer()) :: :ok | {:error, :rate_limited}
  def check_rate(%RelayInstall{id: id}, count),
    do: RelayRateLimit.check(id, count, rate_per_minute())

  # ── delivery ─────────────────────────────────────────────────────────────

  @doc """
  Deliver validated `items` for `install`. Returns one
  `%{"status" => "sent" | "unregistered" | "failed"}` per item, in request
  order. Deletes nothing (the relay stores no devices); the install prunes
  what comes back `unregistered`.
  """
  @spec deliver(RelayInstall.t(), [map()]) :: [map()]
  def deliver(%RelayInstall{} = install, items) do
    apns = if Enum.any?(items, &(&1["platform"] == "ios")), do: APNs.apns_config()

    fcm =
      if Enum.any?(items, &(&1["platform"] == "android")) do
        case FCM.resolve_config() do
          {:ok, config} -> config
          :error -> nil
        end
      end

    if is_nil(apns) and Enum.any?(items, &(&1["platform"] == "ios")),
      do: Logger.warning("[PushRelay] APNs is not configured on this relay; ios items failed")

    if is_nil(fcm) and Enum.any?(items, &(&1["platform"] == "android")),
      do: Logger.warning("[PushRelay] FCM is not configured on this relay; android items failed")

    results =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> %{"status" => send_item(item, index, apns, fcm)} end)

    touch(install)
    log_batch(install, items, results)
    results
  end

  @doc "The APNs body the relay sends for an item (constant alert, no plaintext)."
  @spec apns_body(map()) :: map()
  def apns_body(item) do
    %{
      "aps" => %{"alert" => @alert, "mutable-content" => 1, "sound" => "default"},
      "install_host" => item["install_host"],
      "unread_count" => item["unread_count"],
      "unread_as_of" => item["unread_as_of"],
      "sealed" => item["sealed"]
    }
    |> drop_nils()
  end

  @doc "The FCM v1 message (without `token`) the relay sends for an item: data-only."
  @spec fcm_message(map()) :: map()
  def fcm_message(item) do
    data =
      %{
        "install_host" => item["install_host"],
        "unread_count" => item["unread_count"],
        "unread_as_of" => item["unread_as_of"],
        "sealed" => item["sealed"]
      }
      |> drop_nils()
      |> Map.new(fn {k, v} -> {k, to_string(v)} end)

    android =
      case item["collapse_id"] do
        id when is_binary(id) -> %{"priority" => "high", "collapse_key" => id}
        _ -> %{"priority" => "high"}
      end

    %{"data" => data, "android" => android}
  end

  defp send_item(%{"platform" => "ios"}, _index, nil, _fcm), do: "failed"
  defp send_item(%{"platform" => "android"}, _index, _apns, nil), do: "failed"

  defp send_item(%{"platform" => "ios"} = item, index, config, _fcm) do
    target = %{token: item["token"], environment: item["environment"]}
    headers = APNs.alert_headers(config, item["collapse_id"])

    target
    |> APNs.send_to_token(headers, apns_body(item), config, "relay item #{index}")
    |> status()
  end

  defp send_item(%{"platform" => "android"} = item, index, _apns, config) do
    %{token: item["token"]}
    |> FCM.send_to_token(fcm_message(item), config, "relay item #{index}")
    |> status()
  end

  defp status(:ok), do: "sent"
  defp status({:error, :unregistered}), do: "unregistered"
  defp status(_), do: "failed"

  defp touch(%RelayInstall{id: id, last_used_at: last}) do
    now = DateTime.utc_now()

    if is_nil(last) or DateTime.diff(now, last) >= @touch_interval_seconds do
      from(i in RelayInstall, where: i.id == ^id) |> Repo.update_all(set: [last_used_at: now])
    end

    :ok
  end

  defp log_batch(install, items, results) do
    counts = Enum.frequencies_by(results, & &1["status"])
    platforms = Enum.frequencies_by(items, & &1["platform"])

    Logger.info(
      "[PushRelay] install #{install.id} batch=#{length(items)} " <>
        "ios=#{platforms["ios"] || 0} android=#{platforms["android"] || 0} " <>
        "sent=#{counts["sent"] || 0} unregistered=#{counts["unregistered"] || 0} " <>
        "failed=#{counts["failed"] || 0}"
    )
  end

  defp drop_nils(map), do: map |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
end
