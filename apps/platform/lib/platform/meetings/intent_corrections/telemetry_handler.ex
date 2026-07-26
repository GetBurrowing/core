defmodule Platform.Meetings.IntentCorrections.TelemetryHandler do
  @moduledoc """
  Writes the two SYSTEM-originated `meeting_intent_corrections` rows
  (task 019f70b8 stage 6, AC14).

  Attach once in `Application.start/2`:

      Platform.Meetings.IntentCorrections.TelemetryHandler.attach()

  ## Handled events

  | Telemetry event                                          | `correction`         | `reason`       |
  |----------------------------------------------------------|----------------------|----------------|
  | `[:platform, :meetings, :intent_rejected]`                | `:removed_no_action` | `:wrong_target`|
  | `[:platform, :meetings, :intent_no_ack_spawn_failed]`     | `:removed_no_action` | `:other`       |

  A rejected ack is the target agent saying "this was not mine" — the
  cleanest wrong-target signal the system produces, and one no human had
  to notice. A `:no_ack_spawn_failed` timeout is the runtime saying it
  could not spawn a subagent at all; systemic spawn failure against a
  particular target is tuning signal about routing to unreliable
  targets, so it is recorded with `reason: :other` rather than being
  mislabelled a wrong target.

  Both are `:removed_no_action`: neither event tells us what the RIGHT
  intent or target would have been, and `:corrected` rows are required
  to carry that.

  ## Why telemetry rather than a direct call

  `Platform.Meetings.IntentQueue.Server` holds no DB connection by
  design — it is a per-meeting ETS owner whose whole point is that it
  dies with the meeting. It emits these two events at the transition
  sites because that is the only place that still holds BOTH the
  pre-transition status (which becomes `dispatch_outcome`) and the row's
  classification fields. The durable write lives out here.

  ## `dispatch_outcome` is the status the row was in

  For a rejected ack that is `:dispatched` or `:acked` — where the
  intent had actually got to when the target pushed it back — NOT the
  `:completed` the row lands on. The queue's `emit_rejected_hook/4`
  passes the pre-transition status for exactly this reason. The
  distinction is load-bearing for tuning: "the target rejected it before
  acking" and "the target acked, looked, and rejected it" are different
  failures.

  ## Never crash, never block

  `:telemetry` detaches a handler that raises, which would silently kill
  every subsequent correction for the life of the node — so every path
  here is rescued. One rescue is narrower than the rest:
  `DBConnection.OwnershipError` means the emitting process has no
  sandbox connection, which can only happen under an ExUnit sandbox
  (the intent-queue unit tests run `async: true` with no `DataCase`).
  That is not a failure worth a warning on every run, so it is swallowed
  quietly; anything else is logged loudly.
  """

  require Logger

  alias Platform.Meetings.IntentCorrections

  @handler_id "platform-meetings-intent-corrections"

  @rejected_event [:platform, :meetings, :intent_rejected]
  @no_ack_spawn_failed_event [:platform, :meetings, :intent_no_ack_spawn_failed]

  @events [@rejected_event, @no_ack_spawn_failed_event]

  @doc "Attach the handler to both correction-hook events."
  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, %{})
  end

  @doc "Detach the handler. Useful in tests that assert the no-write invariant."
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc "The telemetry events this handler writes corrections for."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc false
  def handle_event(event, _measurements, metadata, _config) do
    case correction_attrs(event, metadata) do
      nil ->
        :ok

      attrs ->
        case IntentCorrections.create_correction(attrs) do
          {:ok, _correction} ->
            :ok

          {:error, changeset} ->
            Logger.warning(
              "[IntentCorrections] auto-write rejected event=#{inspect(event)} " <>
                "errors=#{inspect(changeset.errors)}"
            )

            :ok
        end
    end
  rescue
    # See moduledoc: no sandbox connection in the emitting process. Only
    # reachable under ExUnit; a production node always has one.
    DBConnection.OwnershipError ->
      :ok

    error ->
      Logger.error(
        "[IntentCorrections] auto-write crashed event=#{inspect(event)} " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # ── Event → row ────────────────────────────────────────────────────────────

  defp correction_attrs(@rejected_event, metadata) do
    base_attrs(metadata, :removed_no_action, :wrong_target)
  end

  defp correction_attrs(@no_ack_spawn_failed_event, metadata) do
    base_attrs(metadata, :removed_no_action, :other)
  end

  defp correction_attrs(_event, _metadata), do: nil

  defp base_attrs(metadata, correction, reason) do
    %{
      meeting_id: Map.get(metadata, :meeting_id),
      transcript_chunk_excerpt: Map.get(metadata, :chunk_excerpt),
      classified_intent: stringify(Map.get(metadata, :classified_intent)),
      classified_target_agent_id: Map.get(metadata, :target_agent_id),
      dispatch_outcome: normalize_outcome(Map.get(metadata, :dispatch_outcome)),
      correction: correction,
      reason: reason,
      # System-originated: no human producer clicked anything.
      actor_participant_id: nil
    }
  end

  # Queue rows carry `classified_intent` as whatever the classifier
  # parsed — a binary in practice, an atom in hand-driven tests. The
  # column is a string either way.
  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  # `Ecto.Enum` casts a string or an atom, but only for values in the
  # set. A queue status with no corresponding corpus outcome (there are
  # none today, and there would be one the moment a tenth status ships)
  # is dropped to nil rather than failing the whole write — a correction
  # with an unknown outcome still teaches the classifier something.
  defp normalize_outcome(nil), do: nil

  defp normalize_outcome(outcome) do
    if outcome in Platform.Meetings.IntentCorrection.dispatch_outcomes() do
      outcome
    else
      nil
    end
  end
end
