defmodule Platform.Updates do
  @moduledoc """
  The core side of the host updater (task 01a1b7b6 stage 3).

  The updater (`deployment/installer/updater/burrow_update.py`, stage 1) runs
  as root on the host. Core never reaches it except through two mounts:

    * `core_dir` (rw, default `/run/burrow/updater/core`), holding `staging/`
      and `inbox/`. Core writes a file to `staging/` and renames it into
      `inbox/`, so the updater's path unit never sees a half-written file.
    * `status_path` (ro, default `/run/burrow/updater/status/status.json`),
      which the updater rewrites atomically after every run.

  Core writes exactly two shapes, and nothing a caller passes can widen them:

    * `inbox/request.json` = `{action, request_id, requested_at}`, with
      `action` one of `check`, `update`, `rollback`;
    * `inbox/settings.json` = `{auto_update}`.

  Neither `request/2` nor `set_auto_update/2` takes a map, so no image, no
  channel and no extra key can reach the host. The updater re-validates
  everything anyway (an allowlist of keys, a 4 KiB cap, no symlinks).

  Authorization is the caller's: `PlatformWeb.AdminUpdatesLive` re-checks
  `Platform.Tenancy.root_admin?/1` on mount and on every event before it calls
  in here. The actor passed in is recorded in the audit log.

  Config: `config :platform, Platform.Updates, core_dir: ..., status_path: ...`
  (runtime env `BURROW_UPDATER_CORE_DIR` / `BURROW_UPDATER_STATUS`).
  """

  require Logger

  @default_core_dir "/run/burrow/updater/core"
  @default_status_path "/run/burrow/updater/status/status.json"

  # status.json is a few hundred bytes; anything past this is not the updater's.
  @max_status_bytes 65_536

  # stage 1's last_result enum, verbatim.
  @last_results ~w(never_run ok up_to_date skipped_bad_digest no_release_on_channel
                   deferred_meeting_live held_irreversible rolled_back rollback_failed
                   failed_rollback_blocked pinned not_pinnable refused checked)

  @channels ~w(stable edge pinned)

  @actions %{check: "check", update: "update", rollback: "rollback"}

  @type status :: %{
          channel: String.t() | nil,
          auto_update: boolean() | nil,
          last_result: String.t() | nil,
          last_checked_at: String.t() | nil,
          deferred_since: String.t() | nil,
          current: %{digest: String.t() | nil, commit: String.t() | nil} | nil,
          available: %{digest: String.t() | nil} | nil,
          last_rollback:
            %{at: String.t() | nil, from: String.t() | nil, to: String.t() | nil} | nil,
          pending_irreversible: [String.t()] | nil,
          last_request:
            %{request_id: String.t() | nil, result: String.t() | nil, reason: String.t() | nil}
            | nil,
          error: String.t() | nil
        }

  @doc "stage 1's `last_result` values."
  def last_results, do: @last_results

  @doc "The inbox/staging root core writes into."
  def core_dir, do: config(:core_dir, @default_core_dir)

  @doc "The status.json the updater publishes (read-only to core)."
  def status_path, do: config(:status_path, @default_status_path)

  @doc """
  The updater's last published status, known keys only.

  `:not_installed` when the file does not exist (no updater on this host).
  `{:error, reason}` when it exists but cannot be read or parsed, or is over
  #{@max_status_bytes} bytes. Never raises.
  """
  @spec status() :: status() | :not_installed | {:error, term()}
  def status do
    path = status_path()

    case read_capped(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> normalize(map)
          {:ok, _} -> {:error, :not_an_object}
          {:error, _} -> {:error, :malformed}
        end

      {:error, :enoent} ->
        :not_installed

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error -> {:error, {:unreadable, Exception.message(error)}}
  end

  defp read_capped(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @max_status_bytes + 1) do
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
            data when byte_size(data) > @max_status_bytes -> {:error, :oversize}
            data -> {:ok, data}
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize(map) do
    %{
      channel: enum(map["channel"], @channels),
      auto_update: bool(map["auto_update"]),
      last_result: enum(map["last_result"], @last_results),
      last_checked_at: str(map["last_checked_at"]),
      deferred_since: str(map["deferred_since"]),
      current: sub(map["current"], digest: &str/1, commit: &str/1),
      available: sub(map["available"], digest: &str/1),
      last_rollback: sub(map["last_rollback"], at: &str/1, from: &str/1, to: &str/1),
      pending_irreversible: str_list(map["pending_irreversible"]),
      last_request: sub(map["last_request"], request_id: &str/1, result: &str/1, reason: &str/1),
      error: str(map["error"])
    }
  end

  defp sub(map, fields) when is_map(map) do
    Map.new(fields, fn {key, cast} -> {key, cast.(Map.get(map, Atom.to_string(key)))} end)
  end

  defp sub(_other, _fields), do: nil

  defp enum(value, allowed) when is_binary(value), do: if(value in allowed, do: value)
  defp enum(_value, _allowed), do: nil

  defp bool(value) when is_boolean(value), do: value
  defp bool(_value), do: nil

  defp str(value) when is_binary(value), do: value
  defp str(_value), do: nil

  defp str_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp str_list(_other), do: nil

  @doc """
  The `update` object `/health` carries, or `nil` when the updater is not
  installed or its status cannot be read.

  `%{channel, auto_update, last_result, last_checked_at, last_rollback}`,
  with `last_rollback` as `%{at, from, to}` in commits. No digests, paths or
  request ids: the updater records a rollback end as the image ref when it
  could not read a commit, and such an end is reported as `nil`.
  """
  @spec health_summary() :: map() | nil
  def health_summary do
    case status() do
      %{} = status ->
        %{
          channel: status.channel,
          auto_update: status.auto_update,
          last_result: status.last_result,
          last_checked_at: status.last_checked_at,
          last_rollback: rollback_commits(status.last_rollback)
        }

      _ ->
        nil
    end
  end

  defp rollback_commits(%{} = rollback) do
    %{at: rollback.at, from: commit(rollback.from), to: commit(rollback.to)}
  end

  defp rollback_commits(_), do: nil

  @doc "`value` when it is a git commit (7-40 lowercase hex), else `nil`."
  def commit(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, value), do: value
  end

  def commit(_), do: nil

  @doc """
  Ask the updater to `:check`, `:update` or `:rollback`.

  Writes exactly `{action, request_id, requested_at}` to
  `staging/<request_id>.json`, then renames it to `inbox/request.json`.
  Returns `{:ok, request_id}`, or `{:error, reason}` (nothing in the inbox).
  An unknown action raises `FunctionClauseError` and writes nothing.
  """
  @spec request(:check | :update | :rollback, term()) :: {:ok, String.t()} | {:error, term()}
  def request(action, actor) when is_map_key(@actions, action) do
    request_id = Platform.Types.UUIDv7.generate()

    body = %{
      "action" => Map.fetch!(@actions, action),
      "request_id" => request_id,
      "requested_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    with :ok <- deliver("request.json", body) do
      audit(actor, "update_requested", %{"action" => body["action"], "request_id" => request_id})
      {:ok, request_id}
    end
  end

  @doc """
  Turn automatic updates on or off. Writes exactly `{auto_update}` through
  staging into `inbox/settings.json`.
  """
  @spec set_auto_update(boolean(), term()) :: :ok | {:error, term()}
  def set_auto_update(enabled, actor) when is_boolean(enabled) do
    with :ok <- deliver("settings.json", %{"auto_update" => enabled}) do
      audit(actor, "auto_update_set", %{"auto_update" => enabled})
      :ok
    end
  end

  defp deliver(name, body) do
    dir = core_dir()
    staging = Path.join(dir, "staging")
    inbox = Path.join(dir, "inbox")
    tmp = Path.join(staging, Ecto.UUID.generate() <> ".json")

    with true <- File.dir?(staging) || {:error, :no_staging_dir},
         true <- File.dir?(inbox) || {:error, :no_inbox_dir},
         :ok <- File.write(tmp, Jason.encode!(body)),
         :ok <- rename_or_clean(tmp, Path.join(inbox, name)) do
      :ok
    else
      {:error, reason} = error ->
        Logger.warning("updater #{name} not delivered: #{inspect(reason)}")
        error
    end
  end

  defp rename_or_clean(tmp, dest) do
    case File.rename(tmp, dest) do
      :ok ->
        :ok

      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  defp audit(actor, action, metadata) do
    Platform.Audit.record(%{
      event_type: "platform.updates." <> action,
      actor_id: actor_id(actor),
      actor_type: if(actor_id(actor), do: "user", else: "system"),
      resource_type: "install_updater",
      action: action,
      metadata: metadata
    })
  rescue
    # The file is already in the inbox; an audit failure must not report the
    # request as failed.
    error -> Logger.warning("updates audit failed: #{Exception.message(error)}")
  end

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(_), do: nil

  defp config(key, default) do
    :platform
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(key)
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end
end
