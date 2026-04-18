defmodule Platform.Chat.AttachmentStorage.BootCheck do
  @moduledoc """
  One-shot supervisor child that verifies the chat attachment storage root
  is usable before the rest of the supervision tree starts.

  Runs `Platform.Chat.AttachmentStorage.ensure_writable!/0`, which raises
  if the path cannot be created or written. Because `init/1` returns
  `:ignore`, no process is kept around after the check passes — the
  supervisor sees a successful "start" and moves on. If the check raises,
  the supervisor treats it as a failed `start_link` and aborts startup
  with a standard OTP crash report (hitting whatever log backends are
  configured).

  Skipped entirely when `:skip_attachment_storage_check` is true — set in
  dev/test config so those environments don't need a writable
  `/data/platform/chat_uploads`.

  On Linux, also emits a warning if the storage root is NOT a filesystem
  mountpoint — the path being writable doesn't prove it's persistent
  (tmpfs and container overlay layers both pass sentinel writes). The
  warning is a loud signal for ops without blocking non-Linux dev
  machines.
  """

  use GenServer

  require Logger

  alias Platform.Chat.AttachmentStorage

  @proc_mounts "/proc/mounts"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, :ok)
  end

  @impl true
  def init(:ok) do
    AttachmentStorage.ensure_writable!()
    warn_if_not_mountpoint(AttachmentStorage.storage_root())
    :ignore
  end

  defp warn_if_not_mountpoint(root) do
    normalized = String.trim_trailing(root, "/")

    case File.read(@proc_mounts) do
      {:ok, content} ->
        mountpoints =
          content
          |> String.split("\n", trim: true)
          |> Enum.map(fn line -> line |> String.split(" ", parts: 3) |> Enum.at(1) end)
          |> Enum.reject(&is_nil/1)

        unless normalized in mountpoints do
          Logger.warning(
            "[chat.attachment_storage] #{normalized} is writable but not a filesystem mountpoint. " <>
              "Attachments will NOT survive container restarts unless a persistent volume is mounted at this path. " <>
              "This is the failure mode that caused the blank-grey-box attachment bug. " <>
              "Ignore this warning only on dev machines; in prod this is an ops issue."
          )
        end

      {:error, _reason} ->
        # /proc/mounts is not readable on non-Linux (e.g., macOS dev).
        # Skip the mountpoint check silently on those platforms.
        :ok
    end
  end
end
