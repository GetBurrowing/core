defmodule Platform.Meetings.IntentCorrections.TelemetryHandlerTest do
  @moduledoc """
  Unit tests for
  `Platform.Meetings.IntentCorrections.TelemetryHandler` — the bridge
  from the intent queue's two correction hooks to a durable
  `meeting_intent_corrections` row (task 019f70b8 stage 6, AC14).

  The end-to-end wiring (real dispatch → real ack → real row) lives in
  `intent_dispatcher_test.exs`. What is proved HERE is the mapping and
  the crash-proofness: `:telemetry` permanently detaches a handler that
  raises, so a single bad payload must not be able to silence every
  correction for the life of the node.

  This module never calls `detach/0`. `:telemetry` handlers are
  VM-global, so a detach inside an `async: true` case would silently
  disable corrections for every other async case running beside it —
  the exact shape of the `Platform.Audit.TelemetryHandler` leak already
  recorded in org memory, where an `on_exit` detach made downstream
  audit writes vanish with no failure to point at. Every case here
  either drives `handle_event/4` directly or reads the attachment
  state.
  """

  use Platform.DataCase, async: true

  import ExUnit.CaptureLog

  alias Platform.Meetings.IntentCorrection
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentCorrections.TelemetryHandler
  alias Platform.Repo

  @rejected [:platform, :meetings, :intent_rejected]
  @no_ack_spawn_failed [:platform, :meetings, :intent_no_ack_spawn_failed]

  defp metadata(overrides \\ %{}) do
    Map.merge(
      %{
        meeting_id: Platform.Types.UUIDv7.generate(),
        room_id: "room-#{System.unique_integer([:positive])}",
        intent_id: Platform.Types.UUIDv7.generate(),
        classified_intent: "visual_adjust",
        target_role: "designer",
        target_agent_id: Platform.Types.UUIDv7.generate(),
        chunk_excerpt: "make the sidebar narrower",
        subagent_id: "higgins.moon",
        dispatch_outcome: :dispatched
      },
      overrides
    )
  end

  defp corrections_for(meeting_id), do: IntentCorrections.list_for_meeting(meeting_id)

  # One entry per (handler, event) pair, so a duplicate attach would show
  # the same id twice for a single event.
  defp attached_ids, do: @rejected |> :telemetry.list_handlers() |> Enum.map(& &1.id)

  describe "attachment" do
    test "the application attaches the handler at boot" do
      # The regression this guards is a one-line deletion in
      # `Platform.Application.start/2`: every correction would silently
      # stop being written and every existing test would still pass,
      # because the queue's telemetry emit does not care whether anyone
      # is listening.
      handler_ids =
        @rejected
        |> :telemetry.list_handlers()
        |> Enum.map(& &1.id)

      assert "platform-meetings-intent-corrections" in handler_ids
    end

    test "both correction hooks are subscribed" do
      assert TelemetryHandler.events() == [@rejected, @no_ack_spawn_failed]

      for event <- TelemetryHandler.events() do
        handler_ids = event |> :telemetry.list_handlers() |> Enum.map(& &1.id)
        assert "platform-meetings-intent-corrections" in handler_ids
      end
    end

    test "re-attaching over the boot-time handler is a no-op, not a duplicate" do
      # Two attached copies would write two rows per correction and
      # double-weight that exemplar in every subsequent prompt.
      #
      # Since task 019f9d80 stage 2 `attach/0` is idempotent, so its
      # return value no longer distinguishes "already attached" from
      # "just installed". Assert the boot-time attach is ALREADY in place
      # first: otherwise this case would quietly install the handler for
      # the rest of the VM and mask the boot-attachment test above. Never
      # detach here — a detach inside an `async: true` case is exactly the
      # VM-global leak this task exists to remove.
      assert "platform-meetings-intent-corrections" in attached_ids()

      assert :ok = TelemetryHandler.attach()

      assert Enum.count(attached_ids(), &(&1 == "platform-meetings-intent-corrections")) == 1
    end
  end

  describe "a rejected ack" do
    test "writes a removed_no_action / wrong_target row" do
      meta = metadata()

      :ok = TelemetryHandler.handle_event(@rejected, %{count: 1}, meta, %{})

      assert [correction] = corrections_for(meta.meeting_id)

      assert correction.correction == :removed_no_action
      assert correction.reason == :wrong_target
      assert correction.classified_intent == "visual_adjust"
      assert correction.classified_target_agent_id == meta.target_agent_id
      assert correction.transcript_chunk_excerpt == "make the sidebar narrower"
      assert correction.dispatch_outcome == :dispatched
      assert is_nil(correction.actor_participant_id)
    end

    test "carries an :acked outcome through unchanged" do
      meta = metadata(%{dispatch_outcome: :acked})

      :ok = TelemetryHandler.handle_event(@rejected, %{count: 1}, meta, %{})

      assert [%{dispatch_outcome: :acked}] = corrections_for(meta.meeting_id)
    end
  end

  describe "a no_ack_spawn_failed timeout" do
    test "writes a reason: :other row, not a wrong-target one" do
      meta = metadata(%{dispatch_outcome: :no_ack_spawn_failed})

      :ok = TelemetryHandler.handle_event(@no_ack_spawn_failed, %{count: 1}, meta, %{})

      assert [correction] = corrections_for(meta.meeting_id)

      assert correction.correction == :removed_no_action
      assert correction.dispatch_outcome == :no_ack_spawn_failed

      # A runtime that cannot spawn a subagent is an UNRELIABLE target,
      # which is different from the WRONG target. Collapsing the two
      # would teach the classifier to stop routing to an agent whose
      # only problem was its runtime.
      assert correction.reason == :other
      refute correction.reason == :wrong_target
    end
  end

  describe "resilience" do
    test "an unhandled event writes nothing and does not raise" do
      before_count = Repo.aggregate(IntentCorrection, :count)

      assert :ok =
               TelemetryHandler.handle_event(
                 [:platform, :meetings, :intent_completed],
                 %{count: 1},
                 metadata(),
                 %{}
               )

      assert Repo.aggregate(IntentCorrection, :count) == before_count
    end

    test "a payload the changeset rejects logs and returns :ok" do
      before_count = Repo.aggregate(IntentCorrection, :count)

      log =
        capture_log(fn ->
          assert :ok =
                   TelemetryHandler.handle_event(
                     @rejected,
                     %{count: 1},
                     metadata(%{meeting_id: nil}),
                     %{}
                   )
        end)

      assert log =~ "auto-write rejected"
      assert Repo.aggregate(IntentCorrection, :count) == before_count
    end

    test "an unknown dispatch_outcome degrades to nil rather than losing the row" do
      meta = metadata(%{dispatch_outcome: :abandoned})

      :ok = TelemetryHandler.handle_event(@rejected, %{count: 1}, meta, %{})

      assert [correction] = corrections_for(meta.meeting_id)
      assert is_nil(correction.dispatch_outcome)
      assert correction.classified_intent == "visual_adjust"
    end

    test "an atom classified_intent is stringified rather than crashing the cast" do
      meta = metadata(%{classified_intent: :off_topic})

      :ok = TelemetryHandler.handle_event(@rejected, %{count: 1}, meta, %{})

      assert [%{classified_intent: "off_topic"}] = corrections_for(meta.meeting_id)
    end

    test "an emitter with no sandbox connection is a silent no-op, not a log flood" do
      # The intent-queue unit tests run `async: true` with no `DataCase`,
      # so their queue servers emit these events from processes that hold
      # no Repo connection at all. A bare `spawn/1` reproduces that:
      # `Task.async/1` would propagate `$callers` and inherit ownership.
      parent = self()
      meta = metadata()

      log =
        capture_log(fn ->
          spawn(fn ->
            result = TelemetryHandler.handle_event(@rejected, %{count: 1}, meta, %{})
            send(parent, {:handled, result})
          end)

          assert_receive {:handled, :ok}, 1_000
        end)

      refute log =~ "auto-write crashed"
      assert corrections_for(meta.meeting_id) == []
    end
  end
end
