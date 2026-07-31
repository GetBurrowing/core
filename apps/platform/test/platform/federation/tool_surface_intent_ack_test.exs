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
    * bundle exposure via `list_tools(["task"])` — the tool has to
      inherit the bundle every dispatch-capable runtime already holds,
      not invent a new one.

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

  # ── Happy paths ────────────────────────────────────────────────────────────

  describe "execute/3 happy paths" do
    test "working acks the row and does NOT advance the cursor", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)
      _behind = enqueue!(meeting_id)

      {:ok, result} =
        ack(row.id, %{"subagent_id" => "higgins.moon", "status" => "working"})

      assert result.intent_id == row.id
      assert result.meeting_id == meeting_id
      # The word you send is not the word you get back: `working` is
      # what the runtime did, `:acked` is what the queue now believes.
      assert result.status == :acked
      assert result.subagent_id == "higgins.moon"
      assert %DateTime{} = result.acked_at

      # Still holding the queue open — the target confirmed a spawn,
      # not a result.
      assert IntentQueue.cursor(meeting_id) == row.id
      assert row!(meeting_id, row.id).status == :acked
    end

    test "completed advances the cursor", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      {:ok, _} = ack(row.id, %{"subagent_id" => "higgins.moon", "status" => "working"})

      {:ok, result} =
        ack(row.id, %{"subagent_id" => "higgins.moon", "status" => "completed"})

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

    # FINDING (019fa609 stage 4), pinned rather than fixed.
    #
    # `subagent_id` is declared `required: true` on intent_ack, so the generic
    # argument gate added in stage 3 now answers an absent or blank one BEFORE
    # execute/3 runs — and the gate has no way to record the attempt. The
    # counter above therefore only advances for a subagent_id the gate lets
    # through (whitespace-only is also treated as absent by the gate, so in
    # practice only the >128-byte case still reaches the handler over the wire).
    #
    # That is why ToolSurface.validate_subagent_id/1 was NOT deleted with the
    # other presence checks in this stage: the gate does not reproduce its side
    # effect, and the plan's instruction is to record a behaviour change of this
    # kind rather than quietly absorb it. This test asserts the seam in both
    # directions so a later fix has to update it deliberately.
    test "the gate answers an absent subagent_id before the counter can see it",
         %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      # Handler path (execute/3): the attempt IS evidence.
      {:error, handler_err} = ack(row.id, %{"status" => "working"})
      assert handler_err.error =~ "subagent_id is required"
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 1

      # Wire path (dispatch/3): refused earlier, and NOT counted.
      {:error, gate_err} =
        ToolArguments.dispatch(
          "intent_ack",
          %{"intent_id" => row.id, "status" => "working"},
          %{}
        )

      assert gate_err.code == :missing_subagent_id
      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 1

      # The oversized id is the one rejection shape the gate still passes
      # through, so the counter keeps working for it.
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

      assert IntentQueue.rejected_ack_count(meeting_id, row.id) == 2
    end

    test "a counted intent that then times out is :no_ack_spawn_failed" do
      meeting_id = Platform.Types.UUIDv7.generate()
      {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 400)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      row = dispatch!(meeting_id)
      {:error, _} = ack(row.id, %{"subagent_id" => "   ", "status" => "working"})

      Process.sleep(700)

      assert row!(meeting_id, row.id).status == :no_ack_spawn_failed
    end

    test "an uncounted intent that times out is plain :timed_out" do
      meeting_id = Platform.Types.UUIDv7.generate()
      {:ok, _pid} = IntentQueue.ensure_started(meeting_id, ack_timeout_ms: 400)
      on_exit(fn -> IntentQueue.stop(meeting_id) end)

      row = dispatch!(meeting_id)

      Process.sleep(700)

      assert row!(meeting_id, row.id).status == :timed_out
    end
  end

  # ── Error envelopes ────────────────────────────────────────────────────────

  describe "execute/3 error envelopes" do
    test "unknown intent_id is :not_found and unrecoverable" do
      {:error, err} =
        ack(Platform.Types.UUIDv7.generate(), %{
          "subagent_id" => "higgins.moon",
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
        ack(row.id, %{"subagent_id" => "higgins.moon", "status" => "working"})

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
          %{"status" => "working", "subagent_id" => "higgins.moon"},
          %{}
        )

      assert err.error =~ "intent_id is required"
      assert err.code == :missing_intent_id
      assert err.recoverable == true
    end

    test "an unrecognised status is rejected with the allowed set", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      {:error, err} = ack(row.id, %{"subagent_id" => "higgins.moon", "status" => "finished"})

      assert err.error =~ "status must be one of"
      assert err.error =~ "cancel_honored"
      assert err.recoverable == true
      assert row!(meeting_id, row.id).status == :dispatched
    end

    test "a missing status is rejected", %{meeting_id: meeting_id} do
      row = dispatch!(meeting_id)

      {:error, err} = ack(row.id, %{"subagent_id" => "higgins.moon"})

      assert err.error =~ "status must be one of"
    end

    test "acking a queued intent is :invalid_ack_state", %{meeting_id: meeting_id} do
      row = enqueue!(meeting_id)

      {:error, err} = ack(row.id, %{"subagent_id" => "higgins.moon", "status" => "working"})

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
    test "intent_ack ships in the task bundle alongside task_ack" do
      names = ToolSurface.list_tools(["task"]) |> Enum.map(& &1.name)

      # Inheriting the `task` bundle is the point — every
      # dispatch-capable runtime already holds it, so no runtime needs
      # a permissions change to answer a meeting intent.
      assert "intent_ack" in names
      assert "task_ack" in names
    end

    test "the descriptor declares the four ack statuses and requires subagent_id" do
      descriptor =
        ToolSurface.list_tools(["task"])
        |> Enum.find(&(&1.name == "intent_ack"))

      assert descriptor.parameters.intent_id.required
      assert descriptor.parameters.subagent_id.required
      assert descriptor.parameters.status.required
      refute descriptor.parameters.note.required

      for status <- ~w(working completed rejected cancel_honored) do
        assert descriptor.parameters.status.description =~ status
      end
    end
  end
end
