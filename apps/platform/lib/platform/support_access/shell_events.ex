defmodule Platform.SupportAccess.ShellEvents do
  @moduledoc """
  Ingests the host-written repair shell log (task 01a1b362 stage 1, ADR
  0059): the JSONL at `SUPPORT_SHELL_EVENTS_PATH` (default
  `/var/lib/burrow-support/events.jsonl`), appended by the installer's shell
  wrapper. One line per event:

      {"event": "shell_opened" | "shell_command" | "shell_closed",
       "session_id": "<support session id>", "command": "...", "ts": "..."}

  Each complete line becomes one audit row, `support.shell_opened`,
  `support.shell_command` (command text truncated to 500 characters) or
  `support.shell_closed`, carrying the session id. A line whose session id is
  not a known repair session, or that does not parse, is recorded as
  `support.shell_unmatched` and its content is not copied.

  The read offset is persisted on the settings row, so a restart resumes
  where it stopped. A trailing line without its newline is left for the next
  tick. A file shorter than the offset (rotated or truncated) is read from
  the start.

  The host writes this file as root, and a repair session is root: this
  record is what the host reported, not proof of what ran.
  """

  alias Platform.SupportAccess
  alias Platform.SupportAccess.Config
  alias Platform.SupportAccess.Session
  alias Platform.SupportAccess.Settings

  @max_command 500
  @max_read 1024 * 1024
  @events %{
    "shell_opened" => "support.shell_opened",
    "shell_command" => "support.shell_command",
    "shell_closed" => "support.shell_closed"
  }

  @doc "Reads new complete lines. Returns the number of lines ingested."
  @spec ingest() :: non_neg_integer()
  def ingest do
    path = Config.shell_events_path()

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> ingest(path, size)
      {:error, _} -> 0
    end
  end

  defp ingest(path, size) do
    offset =
      case Settings.get().shell_events_offset do
        n when is_integer(n) and n <= size -> n
        _ -> 0
      end

    with true <- size > offset,
         {:ok, chunk} <- read_from(path, offset, min(size - offset, @max_read)) do
      lines = complete_lines(chunk)
      consumed = Enum.reduce(lines, 0, fn line, acc -> acc + byte_size(line) + 1 end)
      Enum.each(lines, &record_line/1)
      Settings.put_bookkeeping(shell_events_offset: offset + consumed)
      length(lines)
    else
      _ -> 0
    end
  end

  defp read_from(path, offset, length) do
    File.open(path, [:read, :binary], fn file ->
      case :file.pread(file, offset, length) do
        {:ok, data} -> data
        _ -> ""
      end
    end)
  end

  # Every line that ends in "\n"; a trailing partial line is not returned.
  defp complete_lines(chunk) do
    parts = :binary.split(chunk, "\n", [:global])
    Enum.drop(parts, -1)
  end

  defp record_line(line) do
    with {:ok, %{"event" => event, "session_id" => session_id} = map} <- Jason.decode(line),
         {:ok, event_type} <- Map.fetch(@events, event),
         %Session{kind: "repair"} = session <- known_session(session_id) do
      metadata =
        %{"support_session_id" => session.id, "host_ts" => string(map["ts"])}
        |> maybe_command(event, map["command"])

      SupportAccess.audit(event_type, %{
        action: event,
        resource_type: "support_session",
        resource_id: session.id,
        metadata: metadata
      })
    else
      _ ->
        SupportAccess.audit("support.shell_unmatched", %{
          action: "shell_unmatched",
          resource_type: "support_session",
          metadata: %{"bytes" => byte_size(line), "claimed_session_id" => claimed(line)}
        })
    end
  end

  defp claimed(line) do
    case Jason.decode(line) do
      {:ok, %{"session_id" => id}} when is_binary(id) -> String.slice(id, 0, 64)
      _ -> nil
    end
  end

  defp known_session(id) when is_binary(id), do: SupportAccess.get_session(id)
  defp known_session(_), do: nil

  defp maybe_command(metadata, "shell_command", command) when is_binary(command),
    do: Map.put(metadata, "command", String.slice(command, 0, @max_command))

  defp maybe_command(metadata, _event, _command), do: metadata

  defp string(value) when is_binary(value), do: String.slice(value, 0, 64)
  defp string(_), do: nil
end
