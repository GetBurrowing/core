defmodule Platform.Memory.TelemetryHandler do
  @moduledoc """
  Bridges org memory entry telemetry events to the configured memory provider.

  When an org memory entry is written, this handler loads the full entry from
  the database and forwards it to the configured `Platform.Memory.Provider`
  for indexing. Volume is low (~5–50 writes/day), so synchronous ingest is
  appropriate.

  Attach in Application.start/2 alongside other telemetry handlers.
  """

  require Logger

  @handler_id "platform-memory-telemetry"
  @events [[:platform, :org, :memory_entry_written]]

  @doc "Attach the memory telemetry handler. Idempotent."
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  @doc "Detach the memory telemetry handler."
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event([:platform, :org, :memory_entry_written], _measurements, metadata, _config) do
    if Platform.Memory.enabled?() do
      entry = Platform.Repo.get(Platform.Org.MemoryEntry, metadata.memory_entry_id)

      if entry do
        case Platform.Memory.ingest([entry]) do
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
end
