defmodule Platform.Federation.ToolSurfaceIntentAckTest do
  @moduledoc """
  Coverage for the `intent_ack` MCP tool (task 019f70b8 stage 3).

  Executes the tool through `Platform.Federation.ToolSurface.execute/3`
  — i.e. as an MCP client would — and asserts on:

    * the return envelope per ack status, including the fact that the
      status you SEND is not the status you get back (`working` →
      `acked`, `rejected` → `completed`),
    * the four `subagent_id` rejection shapes, each proving the queue
      row is **byte-identical** afterwards (AC5),
    * the rejected-attempt counter that turns a later timeout from
      `:timed_out` into `:no_ack_spawn_failed` (AC6),
    * bundle exposure via `list_tools(["meetings"])` — the tool has to
      sit in a bundle every dispatch-capable runtime actually holds
      (task 01a08875 stage 1). It shipped in `task` here, on the
      rationale that "every dispatch-capable runtime already holds
      `task`". That was false WHEN WRITTEN, not a claim that went
      stale: `task` has never appeared in
      `AgentRuntime.default_tool_profile/0` on any commit. So a
      runtime on the defaults was dispatched meeting intents it could
      not ack, and since `ToolAuthorization.authorize/2` refuses ABOVE
      `ToolSurface.execute/3` the queue never heard about the refusal —
      the intent held the meeting's SERIAL cursor for the full
      `:awaiting_delivery` window (the ack timeout doubled, because the
      shorter `:awaiting_ack` phase only arms on first contact and a
      refusal is not contact) and then landed plain `:timed_out`,
      indistinguishable from an offline runtime.

  The central assertion of this file is negative: a schema-rejected ack
  must never be a partial ack. The queue is ack-gated, so a row that
  believes a subagent exists when none does is worse than a row that
  knows nothing — it would sit in `:acked` until the ack window expires
  and report `:timed_out` when the truth is `:no_ack_spawn_failed`.

  async: false — the per-meeting queue supervisor and its Registry are
  application-global singletons.
  """

  use Platform.DataCase, async: false

  alias Platform.Federation.ToolArguments
  alias Platform.Federation.ToolSurface
  alias Platform.Meetings.IntentCorrections
  alias Platform.Meetings.IntentQueue
  alias Platform.Meetings.PubSub, as: MeetingsPubSub

  setup do
    meeting_id = Platform.Types.UUIDv7.generate()
    {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 60_000)
    on_exit(fn -> IntentQueue.stop(meeting_id) end)

    {:ok, meeting_id: meeting_id}
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp enqueue!(meeting_id, attrs \\ %{}) do
    {:ok, row} =
      IntentQueue.enqueue(
        meeting_id,
        Map.merge(
          %{
            room_id: "room-#{System.unique_integer([:positive])}",
            dedupe_key: "dk-#{System.unique_integer([:positive])}",
            classified_intent: "book_followup",
            target_role: "designer",
            confidence: 0.91,
            chunk_excerpt: "can someone book the follow-up"
          },
          attrs
        )
      )

    row
  end

  # Drive a row to `:dispatched` without a dispatcher, by claiming the
  # cursor and committing it the way the dispatcher would. Keeps this
  # file focused on the tool rather than on dispatch resolution.
  defp dispatch!(meeting_id, attrs \\ %{}) do
    row = enqueue!(meeting_id, attrs)
    {:ok, ^row} = IntentQueue.claim_next(meeting_id)
    {:ok, dispatched} = IntentQueue.transition(meeting_id, row.id, :dispatched)
    dispatched
  end

  defp row!(meeting_id, intent_id) do
    {:ok, row} = IntentQueue.get(meeting_id, intent_id)
    row
  end

  defp ack(intent_id, args) do
    ToolSurface.execute("intent_ack", Map.put(args, "intent_id", intent_id), %{})
  end

  # The WIRE path both federation transports take: the argument gate, then
  # execute/3.
  defp wire_ack(intent_id, args) do
    ToolArguments.dispatch("intent_ack", Map.put(args, "intent_id", intent_id), %{})
  end

  # ── Happy paths ────────────────────────────────────────────────────────────

  describe "execute/3 happy paths" do
    test "working acks the row and does NOT advance the cursor", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)
      _behind = enqueue!(meeting_id)

      {:ok, result} =
        ack(row.id, %{"subagent_id" => "higgins.test-host", "status" => "working"})

      assert result.intent_id == row.id
      assert result.meeting_id == meeting_id
      # The word you send is not the word you get back: `working` is
      # what the runtime did, `:acked` is what the queue now believes.
      assert result.status == :acked
      assert result.subagent_id == "higgins.test-host"
      assert %DateTime{} = result.acked_at

      # Still holding the queue open — the target confirmed a spawn,
      # not a result.
      assert IntentQueue.cursor(meeting_id) == row.id
      assert row!(meeting_id, row.id).status == :acked
    end

    test "completed advances the cursor", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      {:ok, _} = ack(row.id, %{"subagent_id" => "higgins.test-host", "status" => "working"})

      {:ok, result} =
        ack(row.id, %{"subagent_id" => "higgins.test-host", "status" => "completed"})

      assert result.status == :completed
      assert IntentQueue.cursor(meeting_id) == nil
      assert row!(meeting_id, row.id).completed_at
    end

    test "rejected lands terminal and advances, carrying the note", %{meeting_id: meeting_id} do
      handler_id = "intent-ack-rejected-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:platform, :meetings, :intent_rejected],
        fn _e, _m, meta, _ -> send(parent, {:rejected_hook, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      row = dispatch!(meeting_id)

      {:ok, result} =
        ack(row.id, %{
          "subagent_id" => "afd767f1e0cc81633",
          "status" => "rejected",
          "note" => "this is a designer thing, not mine"
        })

      assert result.status == :completed
      assert IntentQueue.cursor(meeting_id) == nil

      # The tuning signal stage 6 writes its correction row from.
      assert_receive {:rejected_hook, meta}, 1_000
      assert meta.intent_id == row.id
      assert meta.note == "this is a designer thing, not mine"
      assert meta.dispatch_outcome == :dispatched
    end

    test "cancel_honored lands :cancelled from an in-flight row", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)
      {:ok, _} = ack(row.id, %{"subagent_id" => "cancel-probe-9x", "status" => "working"})

      {:ok, result} =
        ack(row.id, %{"subagent_id" => "cancel-probe-9x", "status" => "cancel_honored"})

      assert result.status == :cancelled
      assert row!(meeting_id, row.id).cancelled_at
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "cancel_honored on an already-completed row is :cancelled_late, not a crash",
         %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)
      {:ok, _} = ack(row.id, %{"subagent_id" => "racer", "status" => "completed"})

      # The target finished before the cancel reached it. Neither an
      # error nor a silent overwrite — a status the UI can explain.
      {:ok, result} = ack(row.id, %{"subagent_id" => "racer", "status" => "cancel_honored"})

      assert result.status == :cancelled_late
    end

    test "the ack resolves the meeting from the intent id alone", %{meeting_id: meeting_id} do
      # A remote runtime is given an intent_id and nothing else. If the
      # tool needed a meeting_id it would be unusable from a runtime.
      row = dispatch!(meeting_id)

      {:ok, result} =
        ack(row.id, %{"subagent_id" => "no-meeting-id-supplied", "status" => "working"})

      assert result.meeting_id == meeting_id
    end
  end

  # ── subagent_id rejection: zero mutation (AC5) ─────────────────────────────

  describe "subagent_id validation leaves the row untouched (AC5)" do
    for {label, args} <- [
          {"missing subagent_id key", %{}},
          {"empty subagent_id string", %{"subagent_id" => ""}},
          {"whitespace-only subagent_id", %{"subagent_id" => "   \t  "}},
          {"oversized subagent_id (>128 bytes)", %{"subagent_id" => String.duplicate("x", 129)}}
        ] do
      test "rejects #{label} with the row byte-identical", %{meeting_id: meeting_id} do
        row = dispatch!(meeting_id)
        before = row!(meeting_id, row.id)

        :ok = MeetingsPubSub.subscribe_intents(meeting_id)

        args =
          %{"status" => "working"}
          |> Map.merge(unquote(Macro.escape(args)))

        {:error, err} = ack(row.id, args)

        assert err.recoverable == true
        assert is_binary(err.error)
        assert err.suggestion =~ ~r/spawn|subagent_id/i

        # BYTE-IDENTICAL. Not "still dispatched" — identical. A partial
        # ack that stamped, say, `acked_at` while rejecting the id
        # would pass a weaker assertion and still be a real defect.
        assert row!(meeting_id, row.id) == before
        assert before.status == :dispatched
        assert before.subagent_id == nil
        assert before.acked_at == nil

        # And nothing went out on the wire either.
        refute_receive {:intent_acked, _}, 100

        MeetingsPubSub.unsubscribe_intents(meeting_id)
      end
    end

    test "a valid ack after four rejected ones succeeds", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      for bad <- [%{}, %{"subagent_id" => ""}, %{"subagent_id" => "  "}] do
        {:error, _} = ack(row.id, Map.merge(%{"status" => "working"}, bad))
      end

      assert row!(meeting_id, row.id).status == :dispatched

      {:ok, result} = ack(row.id, %{"subagent_id" => "finally.valid", "status" => "working"})
      assert result.status == :acked
      assert result.subagent_id == "finally.valid"
    end
  end

  # ── Rejected-attempt counter (AC6) ─────────────────────────────────────────

  describe "rejected attempts feed the :no_ack_spawn_failed split (AC6)" do
    test "each rejected ack is counted against the intent", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 0

      {:error, _} = ack(row.id, %{"status" => "working"})
      {:error, _} = ack(row.id, %{"subagent_id" => "", "status" => "working"})

      # This is the evidence that distinguishes "the runtime tried and
      # couldn't name a subagent" from "the runtime said nothing".
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 2
    end

    # FINDING (019fa609 stage 4), FIXED by task 01a1f53c-1825.
    #
    # `subagent_id` used to be declared `required: true` on intent_ack, so the
    # generic argument gate answered an absent or blank one BEFORE execute/3
    # ran — and the gate has no way to record the attempt, so over the wire
    # the AC6 counter only advanced for an oversized id.
    #
    # The requirement is now conditional on status (optional for `rejected`),
    # which the per-parameter gate cannot express, so the descriptor says
    # `required: false` and the handler enforces it. The handler's refusal
    # keeps the gate's `:missing_subagent_id` code and DOES count the attempt.
    # This test was updated deliberately to pin the new behaviour: the wire
    # path and the handler path now agree.
    test "an absent subagent_id on the wire is refused with :missing_subagent_id and counted",
         %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      # Handler path (execute/3): the attempt IS evidence.
      {:error, handler_err} = ack(row.id, %{"status" => "working"})
      assert handler_err.error =~ "subagent_id is required"
      assert handler_err.code == :missing_subagent_id
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 1

      # Wire path (dispatch/3): same refusal, now ALSO counted.
      {:error, gate_err} =
        ToolArguments.dispatch(
          "intent_ack",
          %{"intent_id" => row.id, "status" => "working"},
          %{}
        )

      assert gate_err.code == :missing_subagent_id
      assert gate_err.recoverable == true
      assert gate_err.error == "intent_ack: subagent_id is required for status working"
      assert gate_err.suggestion =~ "rejected"
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 2

      # A blank id is no longer swallowed by the gate either.
      {:error, _} =
        ToolArguments.dispatch(
          "intent_ack",
          %{"intent_id" => row.id, "status" => "working", "subagent_id" => "  "},
          %{}
        )

      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 3

      {:error, _} =
        ToolArguments.dispatch(
          "intent_ack",
          %{
            "intent_id" => row.id,
            "status" => "working",
            "subagent_id" => String.duplicate("x", 129)
          },
          %{}
        )

      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 4
      assert row!(meeting_id, row.id).status == :dispatched
    end

    # Both of these used to `Process.sleep(ack_timeout_ms + 300)`. Task
    # 019ff292 stage 2 split the window in two, and a row nobody has
    # receipted is resolved by the OUTER, transmission-anchored bound
    # (`delivery_timeout_ms`), not by the responder's `ack_timeout_ms` —
    # so a fixed sleep sized off the ack window now wakes up while the
    # row is still legitimately `:dispatched`. Waiting on the queue's
    # own broadcast instead is both correct and immune to the next
    # change of this kind.
    #
    # What they assert is unchanged: WHICH failure a silent dispatch
    # resolves to. That split is driven by the rejected-ack counter and
    # is orthogonal to which bound expired.
    test "a counted intent that then times out is :no_ack_spawn_failed" do
      meeting_id = Platform.Types.UUIDv7.generate()
      {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 400)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      row = dispatch!(meeting_id)
      {:error, _} = ack(row.id, %{"subagent_id" => "   ", "status" => "working"})

      intent_id = row.id
      assert_receive {:intent_no_ack_spawn_failed, %{id: ^intent_id}}, 3_000

      assert row!(meeting_id, row.id).status == :no_ack_spawn_failed
    end

    test "an uncounted intent that times out is plain :timed_out" do
      meeting_id = Platform.Types.UUIDv7.generate()
      {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 400)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      :ok = MeetingsPubSub.subscribe_intents(meeting_id)

      row = dispatch!(meeting_id)

      intent_id = row.id
      assert_receive {:intent_timed_out, %{id: ^intent_id}}, 3_000

      assert row!(meeting_id, row.id).status == :timed_out
    end
  end

  # ── subagent_id is conditional on status (task 01a1f53c-1825) ─────────────

  describe "subagent_id is optional for rejected only (wire path)" do
    # NAMED TEST A. Through `ToolArguments.dispatch/3`, because the wire gate
    # is where the reported refusal lived — `execute/3` alone never showed it.
    test "rejected with no subagent_id advances the queue and records the correction",
         %{meeting_id: meeting_id} do
      handler_id = "intent-ack-rejected-no-id-#{System.unique_integer([:positive])}"
      parent = self()

      :telemetry.attach(
        handler_id,
        [:platform, :meetings, :intent_rejected],
        fn _e, _m, meta, _ -> send(parent, {:rejected_hook, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      row =
        dispatch!(meeting_id, %{
          classified_intent: "not-mine-no-subagent",
          chunk_excerpt: "someone should redo the onboarding illustrations"
        })

      behind = enqueue!(meeting_id)

      assert {:ok, %{status: :completed, subagent_id: nil} = result} =
               wire_ack(row.id, %{
                 "status" => "rejected",
                 "note" => "a designer thing, not mine"
               })

      assert result.intent_id == row.id
      assert IntentQueue.cursor(meeting_id) == nil
      assert row!(meeting_id, row.id).subagent_id == nil

      # Declining is not a failed ack attempt.
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 0

      assert_receive {:rejected_hook, meta}, 1_000
      assert meta.intent_id == row.id
      assert meta.subagent_id == nil
      assert meta.note == "a designer thing, not mine"

      # The durable tuning signal, written by the boot-attached
      # IntentCorrections.TelemetryHandler from that hook.
      assert [correction] = IntentCorrections.list_for_meeting(meeting_id)
      assert correction.meeting_id == meeting_id
      assert correction.reason == :wrong_target
      assert correction.correction == :removed_no_action
      assert correction.classified_intent == "not-mine-no-subagent"
      assert correction.transcript_chunk_excerpt =~ "onboarding illustrations"

      # The queue moved on: the next intent can be claimed.
      assert {:ok, %{id: behind_id}} = IntentQueue.claim_next(meeting_id)
      assert behind_id == behind.id
    end

    # NAMED TEST B, plus its working / cancel_honored siblings. A mutation
    # that made subagent_id optional for every status turns all three red.
    for status <- ~w(completed working cancel_honored) do
      test "#{status} with no subagent_id is still refused", %{meeting_id: meeting_id} do
        row = dispatch!(meeting_id)
        before = row!(meeting_id, row.id)

        :ok = MeetingsPubSub.subscribe_intents(meeting_id)

        assert {:error, %{code: :missing_subagent_id} = err} =
                 wire_ack(row.id, %{"status" => unquote(status)})

        assert err.recoverable == true
        assert err.error =~ unquote(status)

        after_row = row!(meeting_id, row.id)
        assert after_row == before
        assert after_row.status == :dispatched
        assert after_row.subagent_id == nil
        assert after_row.acked_at == nil
        assert IntentQueue.cursor(meeting_id) == row.id
        assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 1

        refute_receive {:intent_acked, _}, 100
        MeetingsPubSub.unsubscribe_intents(meeting_id)
      end
    end

    test "working with a real id, then rejected with no id, keeps the real id",
         %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      assert {:ok, %{status: :acked, subagent_id: "real-spawn.4f2a"}} =
               wire_ack(row.id, %{"status" => "working", "subagent_id" => "real-spawn.4f2a"})

      assert {:ok, %{status: :completed, subagent_id: "real-spawn.4f2a"}} =
               wire_ack(row.id, %{"status" => "rejected"})

      assert row!(meeting_id, row.id).subagent_id == "real-spawn.4f2a"
      assert IntentQueue.cursor(meeting_id) == nil
    end

    test "a supplied subagent_id is still validated for rejected", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      for bad <- ["", "   ", String.duplicate("x", 129)] do
        assert {:error, _} = wire_ack(row.id, %{"status" => "rejected", "subagent_id" => bad})
      end

      assert row!(meeting_id, row.id).status == :dispatched
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 3
    end

    test "the queue itself refuses a nil subagent_id for any status but rejected",
         %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      for status <- [:working, :completed, :cancel_honored] do
        assert_raise FunctionClauseError, fn ->
          IntentQueue.ack(meeting_id, row.id, nil, status)
        end
      end

      assert row!(meeting_id, row.id).status == :dispatched
      assert {:ok, %{status: :completed}} = IntentQueue.ack(meeting_id, row.id, nil, :rejected)
    end
  end

  # ── Error envelopes ────────────────────────────────────────────────────────

  describe "execute/3 error envelopes" do
    test "unknown intent_id is :not_found and unrecoverable" do
      {:error, err} =
        ack(Platform.Types.UUIDv7.generate(), %{
          "subagent_id" => "higgins.test-host",
          "status" => "working"
        })

      assert err.error =~ "Intent not found"
      assert err.recoverable == false
      assert err.suggestion =~ "meeting-lifetime"
    end

    test "an intent whose meeting has ended is :not_found", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)
      :ok = IntentQueue.stop(meeting_id)

      # The queue is meeting-lifetime by design — there is nothing left
      # to ack, and pretending otherwise would mean resurrecting state
      # the ETS-ephemeral rule deliberately doesn't keep.
      {:error, err} =
        ack(row.id, %{"subagent_id" => "higgins.test-host", "status" => "working"})

      assert err.error =~ "Intent not found"
    end

    # Migrated to dispatch/3 in 019fa609 stage 4. intent_ack's own
    # validate_intent_id/1 is gone — IntentQueue.locate/1 guards on is_binary,
    # so a nil intent_id reaching execute/3 now raises rather than refusing.
    # subagent_id is supplied because the gate refuses on the first missing
    # parameter in declaration order and would otherwise name that one.
    test "missing intent_id is rejected before anything else" do
      {:error, err} =
        ToolArguments.dispatch(
          "intent_ack",
          %{"status" => "working", "subagent_id" => "higgins.test-host"},
          %{}
        )

      assert err.error =~ "intent_id is required"
      assert err.code == :missing_intent_id
      assert err.recoverable == true
    end

    test "an unrecognised status is rejected with the allowed set", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      {:error, err} = ack(row.id, %{"subagent_id" => "higgins.test-host", "status" => "finished"})

      assert err.error =~ "status must be one of"
      assert err.error =~ "cancel_honored"
      assert err.recoverable == true
      assert row!(meeting_id, row.id).status == :dispatched
    end

    test "a missing status is rejected", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      {:error, err} = ack(row.id, %{"subagent_id" => "higgins.test-host"})

      assert err.error =~ "status must be one of"
    end

    test "acking a queued intent is :invalid_ack_state", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)

      {:error, err} = ack(row.id, %{"subagent_id" => "higgins.test-host", "status" => "working"})

      assert err.error =~ "queued"
      assert err.recoverable == false
      assert row!(meeting_id, row.id).status == :queued
    end

    test "acking an already-completed intent is :invalid_ack_state", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)
      {:ok, _} = ack(row.id, %{"subagent_id" => "done", "status" => "completed"})

      {:error, err} = ack(row.id, %{"subagent_id" => "done", "status" => "working"})

      assert err.error =~ "completed"
    end
  end

  # ── Bundle exposure ────────────────────────────────────────────────────────

  describe "tool descriptor" do
    # Task 01a08875 stage 1 — `intent_ack` moved from `task` to `meetings`.
    # BOTH directions are asserted: presence in `meetings` alone still passes
    # against a descriptor that was COPIED rather than moved, and a copy leaves
    # the unreachable `task` registration exactly where it was.
    #
    # `task_ack` is asserted to have STAYED, in both directions, because the
    # pairing with it is a NAMING symmetry and not a capability one. The two
    # serve different queues with different lifetimes — `task_ack` writes
    # `execution_leases`, `intent_ack` writes meeting-lifetime ETS — which is
    # why the move must not drag its sibling along. (The descriptor's "same
    # contract and the same validation as `task_ack`" line was dropped by task
    # 01a1f53c-1825, when intent_ack's subagent_id became optional for
    # `rejected`.)
    #
    # Nobody loses reach: migration 20260908150000 appended `meetings` to EVERY
    # `agent_runtimes` row unconditionally, so every runtime holding `task`
    # today also holds `meetings`.
    test "intent_ack ships in the meetings bundle, not the task bundle" do
      meetings = ToolSurface.list_tools(["meetings"]) |> Enum.map(& &1.name)
      task = ToolSurface.list_tools(["task"]) |> Enum.map(& &1.name)

      assert "intent_ack" in meetings
      refute "intent_ack" in task

      assert "task_ack" in task
      refute "task_ack" in meetings
    end

    # Task 01a1f53c-1825: subagent_id is conditional (optional for
    # `rejected` only), which the per-parameter gate cannot express, so it is
    # declared `required: false` and the handler enforces the rule.
    test "the descriptor declares the four ack statuses and a conditional subagent_id" do
      descriptor =
        ToolSurface.list_tools(["meetings"])
        |> Enum.find(&(&1.name == "intent_ack"))

      assert descriptor.parameters.intent_id.required
      refute descriptor.parameters.subagent_id.required

      for text <- [
            descriptor.description,
            descriptor.parameters.subagent_id.description,
            descriptor.limitations
          ] do
        assert text =~ "`rejected`"
        assert text =~ "`working`, `completed` and `cancel_honored`"
      end

      assert descriptor.description =~ "declining an intent needs no subagent"
      refute descriptor.description =~ "Same contract and the same validation as `task_ack`"
      assert descriptor.parameters.status.required
      refute descriptor.parameters.note.required

      for status <- ~w(working completed rejected cancel_honored) do
        assert descriptor.parameters.status.description =~ status
      end
    end
  end
end
