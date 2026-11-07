defmodule Platform.SupportAccess.StateFile do
  @moduledoc """
  The host state file (task 01a1b362 stage 1, ADR 0059): the JSON at
  `SUPPORT_ACCESS_STATE_PATH` (default `/var/lib/burrow-support/state.json`,
  bind-mounted from the host by the installer) that the host's sshd
  principals command reads to decide whether a repair certificate may log in.

      {"version": 1, "enabled": true, "principal": "support-<INSTALL_ID>",
       "repair_sessions": [{"id": "...", "not_after": "2026-11-07T01:00:00Z"}]}

  It holds no secret. `repair_sessions` lists only ACTIVE repair sessions,
  and is empty whenever `enabled` is false.

  ## Write discipline

  Written to a sibling temp file and renamed over the target, so a reader
  sees the old file or the new one, never half of one. Rewritten on every
  toggle, grant, session end and sweeper tick.

  A failed write never undoes the change that triggered it. The error is
  recorded on the settings row (`state_file_error`) for the owner's Support
  card, logged once on the transition into failure, and retried on the next
  sweeper tick. The host script fails closed on its own: it also checks each
  session's `not_after`, and refuses on a missing or unparsable file.
  """

  require Logger

  alias Platform.SupportAccess
  alias Platform.SupportAccess.Config
  alias Platform.SupportAccess.Settings

  @version 1

  @doc "The document the file should hold now."
  @spec document(DateTime.t()) :: map()
  def document(now \\ DateTime.utc_now()) do
    enabled = Settings.enabled?()

    sessions =
      if enabled do
        Enum.map(SupportAccess.active_sessions("repair", now), fn s ->
          %{"id" => s.id, "not_after" => DateTime.to_iso8601(DateTime.truncate(s.not_after, :second))}
        end)
      else
        []
      end

    %{
      "version" => @version,
      "enabled" => enabled,
      "principal" => Config.principal(),
      "repair_sessions" => sessions
    }
  end

  @doc "Rewrites the file. Returns `:ok` or `{:error, reason}` (never raises)."
  @spec write(DateTime.t()) :: :ok | {:error, String.t()}
  def write(now \\ DateTime.utc_now()) do
    path = Config.state_path()
    previous_error = Settings.get().state_file_error

    result =
      try do
        atomic_write(path, Jason.encode!(document(now)))
      rescue
        e -> {:error, Exception.message(e)}
      end

    case result do
      :ok ->
        Settings.put_bookkeeping(state_file_error: nil, state_file_written_at: now)
        :ok

      {:error, reason} ->
        reason = to_string(reason)

        if previous_error == nil,
          do: Logger.warning("[support_access] state file write failed: #{reason}")

        Settings.put_bookkeeping(state_file_error: String.slice(reason, 0, 500))
        {:error, reason}
    end
  end

  defp atomic_write(path, body) do
    tmp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(tmp, body),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, "#{:file.format_error(reason)} (#{path})"}
    end
  end
end
