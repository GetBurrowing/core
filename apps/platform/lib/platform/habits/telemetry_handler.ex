defmodule Platform.Habits.TelemetryHandler do
  @moduledoc """
  Records learnable interactions from the one emission seam
  (`0061-learned-defaults.md` § 7). Task 01a1b6a1 stage 2.

  Attached once in `Application.start/2`, and guarded by
  `Platform.Telemetry.HandlerGuardian`. On every
  `[:platform, :interaction, :choice]` event it calls
  `Platform.Habits.record/1` with the event metadata, synchronously, in the
  emitting process.

  ## Never crash

  `:telemetry` detaches a handler that raises, VM-wide. Every path is
  rescued: an invalid signal is logged and dropped. `DBConnection.OwnershipError`
  (an emitter with no sandbox connection, reachable only under an ExUnit
  sandbox in manual mode) is swallowed quietly.
  """

  require Logger

  alias Platform.Habits

  @handler_id "platform-habits-telemetry"

  @doc "Attach the handler. Idempotent."
  @spec attach() :: :ok
  def attach do
    case :telemetry.attach(@handler_id, Habits.choice_event(), &__MODULE__.handle_event/4, %{}) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach(@handler_id)

  @doc "The id this handler attaches under."
  @spec handler_id() :: String.t()
  def handler_id, do: @handler_id

  @doc false
  def handle_event(_event, _measurements, metadata, _config) do
    case Habits.record(metadata) do
      {:ok, _} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "[Habits] choice event refused errors=#{inspect(changeset_errors(changeset))}"
        )

        :ok
    end
  rescue
    DBConnection.OwnershipError ->
      :ok

    error ->
      Logger.error(
        "[Habits] choice event crashed " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp changeset_errors(%Ecto.Changeset{errors: errors}), do: errors
  defp changeset_errors(other), do: other
end
