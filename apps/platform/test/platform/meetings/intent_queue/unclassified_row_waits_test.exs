defmodule Platform.Meetings.IntentQueue.UnclassifiedRowWaitsTest do
  @moduledoc """
  A `:queued` row with no `classified_intent` is not claimable
  (task 01a06638 stage 5).

  The row shape is the one `Platform.Meetings.PressCard.open/3` writes:
  a push-to-talk card enqueued at key-down, before anything has been
  said, with `classified_intent: nil` and `target_role: nil`. Before this
  fix `Server.oldest_queued/1` handed it to the dispatcher on the very
  next poll, `dispatch_row/3` failed it `:no_target_role`, and the
  mirror closed the board card `:dismissed` about 1ms after the press
  — with the dispatcher disabled in `config/test.exs`, no test could
  see it. This file boots a real `IntentDispatcher` so it can.

  Positive control in the same file: once the row carries an intent it
  IS claimed on the next drain, and a classified row enqueued BEHIND
  an unclassified one is claimed ahead of it rather than blocked by it.
  """

  use Platform.DataCase, async: false

  alias Platform.Meetings.Candidates
  alias Platform.Meetings.IntentDispatcher
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.MeetingCandidate

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Platform.Repo, {:shared, self()})

    meeting_id = Ecto.UUID.generate()
    {:ok, _pid} = IntentQueue.ensure_started(meeting_id)
    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    name = :"intent_dispatcher_unclassified_#{System.unique_integer([:positive])}"
    {:ok, _pid} = start_supervised({IntentDispatcher, name: name, tick_interval_ms: 60_000})
    # Let `init/1` subscribe before the first enqueue notifies.
    Process.sleep(20)

    %{meeting_id: meeting_id, dispatcher: name}
  end

  # The press card's row, byte for byte the fields `PressCard.open/3`
  # sets — no intent, no role, nothing said.
  defp press_shaped_attrs do
    %{
      room_id: Ecto.UUID.generate(),
      speaker: "alice",
      source: :push_to_talk,
      dedupe_key: "press-#{System.unique_integer([:positive])}",
      chunk_excerpt: nil,
      classified_intent: nil,
      target_role: nil
    }
  end

  defp classified_attrs do
    %{
      room_id: Ecto.UUID.generate(),
      dedupe_key: "spoken-#{System.unique_integer([:positive])}",
      classified_intent: "off_topic",
      target_role: "null",
      transcript_chunk_id: Ecto.UUID.generate(),
      chunk_excerpt: "just small talk"
    }
  end

  defp status_of(meeting_id, id) do
    {:ok, row} = IntentQueue.get(meeting_id, id)
    row.status
  end

  test "an unclassified row is left :queued by the dispatcher, and its card stays open",
       %{meeting_id: meeting_id, dispatcher: name} do
    {:ok, row} = IntentQueue.enqueue(meeting_id, press_shaped_attrs())

    # The enqueue notify already woke the dispatcher; drain explicitly
    # too so the assertion does not depend on mailbox timing.
    assert IntentDispatcher.drain(meeting_id, name) == :empty
    assert IntentDispatcher.drain(meeting_id, name) == :empty

    assert status_of(meeting_id, row.id) == :queued
    assert IntentQueue.cursor(meeting_id) == nil

    # The deliverable: the board card the mirror wrote is still an OPEN,
    # unclassified card — not `:closed` / `:dismissed`.
    assert %MeetingCandidate{state: state, closed_reason: nil, disposition: nil} =
             Candidates.get_by_intent_id(row.id)

    assert state != :closed
  end

  test "positive control: the same row IS claimed once it carries an intent",
       %{meeting_id: meeting_id, dispatcher: name} do
    {:ok, row} = IntentQueue.enqueue(meeting_id, press_shaped_attrs())
    assert IntentDispatcher.drain(meeting_id, name) == :empty
    assert status_of(meeting_id, row.id) == :queued

    # The reconcile: intent and role land on the row, status unchanged.
    {:ok, _} =
      IntentQueue.transition(meeting_id, row.id, :queued, %{
        classified_intent: "off_topic",
        target_role: "null"
      })

    assert IntentDispatcher.drain(meeting_id, name) == :dispatched
    # `off_topic` is unroutable, so the dispatcher commits it — the
    # point is that it was CLAIMED, which the nil-intent row never is.
    assert status_of(meeting_id, row.id) == :dispatch_failed
  end

  test "an unclassified row does not block a classified row queued behind it",
       %{meeting_id: meeting_id, dispatcher: name} do
    {:ok, press} = IntentQueue.enqueue(meeting_id, press_shaped_attrs())
    {:ok, spoken} = IntentQueue.enqueue(meeting_id, classified_attrs())

    # Whichever of the notify or this call gets there first, the
    # classified row is the one that moves.
    _ = IntentDispatcher.drain(meeting_id, name)
    _ = IntentDispatcher.drain(meeting_id, name)

    assert status_of(meeting_id, press.id) == :queued
    assert status_of(meeting_id, spoken.id) == :dispatch_failed
  end
end
