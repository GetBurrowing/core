defmodule Platform.Memory.TelemetryHandler do
  @moduledoc """
  Bridges org memory entry telemetry events to the configured memory provider.

  When an org memory entry is written, this handler loads the full entry from
  the database and forwards it to the configured `Platform.Memory.Provider`
  for indexing. Volume is low (~5–50 writes/day), so synchronous ingest is
  appropriate.

  The ingest runs in the process that emitted the event, so its bound is the
  short `:timeout` (default 5s), not the long `:ingest_timeout` that
  fire-and-forget callers take: a journal write must not wait up to two
  minutes on the embed round-trip. It passes `ingest_timeout:` equal to the
  configured `:timeout` explicitly, because ingest no longer reads `:timeout`
  (task 01a0d8c9).

  Attach in Application.start/2 alongside other telemetry handlers.
  """

  require Logger

  @handler_id "platform-memory-telemetry"
  @events [[:platform, :org, :memory_entry_written]]
  @default_blocking_timeout 5_000

  @doc """
  Attach the memory telemetry handler. Idempotent — a duplicate attach
  is a no-op (see `Platform.Audit.TelemetryHandler.attach/0`).
  """
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the memory telemetry handler."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event([:platform, :org, :memory_entry_written], _measurements, metadata, _config) do
    if Platform.Memory.enabled?() do
      entry = Platform.Repo.get(Platform.Org.WikiJournalEntry, metadata.memory_entry_id)

      if entry do
        case Platform.Memory.ingest([entry], ingest_timeout: blocking_timeout()) do
          {:ok, _count} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "Memory provider ingest failed for entry #{entry.id}: #{inspect(reason)}"
            )
        end
      else
        Logger.warning(
          "Memory telemetry handler: entry #{metadata.memory_entry_id} not found in database"
        )
      end
    end
  rescue
    error ->
      Logger.error(
        "Memory telemetry handler crashed: #{Exception.format(:error, error, __STACKTRACE__)}"
      )
  end

  # The short, search-class bound: this ingest blocks the emitting process.
  defp blocking_timeout do
    :platform
    |> Application.get_env(:memory_service, [])
    |> Keyword.get(:timeout, @default_blocking_timeout)
  end
end
