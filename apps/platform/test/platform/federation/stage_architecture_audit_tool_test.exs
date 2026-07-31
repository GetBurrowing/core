defmodule Platform.Federation.StageArchitectureAuditToolTest do
  @moduledoc """
  Task `019fa61c` stage 3 — `stage_architecture_audit`, the MCP surface a
  native architect actually calls.

  ## What this file is asserting

  Stages 1 and 2 built the row: a column, a guarded changeset, and a
  writer that records that an `architecture.audit_diff` fire went OUT.
  This stage builds the only way to say what came BACK. The load-bearing
  claim is not "the tool works" — it is that **the note and the row land
  together or not at all.** The defect this task exists to close was an
  architect producing a side effect (an execution-space annotation) that
  nothing counted; recording a row that nobody reads would be the same
  defect with the halves swapped. Every success assertion below therefore
  checks BOTH, and the duplicate-call test checks both are unchanged.

  Every absence assertion is paired with its positive control in the SAME
  test, so a validator that simply refuses everything fails the file.

  Not `async: true`: `StageAudit.record_note/3` posts through
  `ExecutionSpace.post_log/2`, which broadcasts on the chat topic, and
  several cases set the module-level `:architecture_audit_timeout_ms`
  app env.
  """
  use Platform.DataCase, async: false

  alias Platform.Architecture.StageAudit
  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Plan
  alias Platform.Tasks.Stage

  defp u, do: System.unique_integer([:positive])

  setup do
    previous = Application.get_env(:platform, :architecture_audit_timeout_ms)

    on_exit(fn ->
      if previous do
        Application.put_env(:platform, :architecture_audit_timeout_ms, previous)
      else
        Application.delete_env(:platform, :architecture_audit_timeout_ms)
      end
    end)

    {:ok, project} = Tasks.create_project(%{name: "Stage Audit Tool Project #{u()}"})

    %{project: project}
  end

  # A task with a plan, one stage, and a real execution space — the shape
  # `PlanEngine.after_stage_completed/1` leaves behind in production.
  defp audit_fixture(project, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Audit fixture #{u()}",
        status: "in_progress"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})

    {:ok, stage} =
      Tasks.create_stage(%{
        plan_id: plan.id,
        position: 1,
        name: "Audited stage #{u()}",
        description: "Edit only apps/platform/lib/platform/architecture/stage_audit.ex."
      })

    space =
      if Keyword.get(opts, :execution_space, true) do
        {:ok, space} = ExecutionSpace.find_or_create(task.id)
        space
      end

    %{task: task, plan: plan, stage: stage, space: space}
  end

  # The audit as `open_from_fire/2` writes it for a DISPATCHED fire. Built
  # through the real writer rather than by hand — a hand-written open row
  # would let this file pass against a writer that stopped agreeing with
  # the schema.
  defp open_audit!(%{stage: stage}) do
    {:ok, updated} = StageAudit.open_from_fire(stage, {:ok, :dispatched})

    assert updated.architecture_audit["state"] == "pending",
           "precondition: open_from_fire/2 must leave a pending audit"

    updated
  end

  defp opened_fixture(project, opts \\ []) do
    ctx = audit_fixture(project, opts)
    %{ctx | stage: open_audit!(ctx)}
  end

  defp stored_audit(%Stage{id: id}), do: Repo.get!(Stage, id).architecture_audit

  defp call(args), do: ToolSurface.execute("stage_architecture_audit", args, %{})

  defp note_args(stage, overrides \\ %{}) do
    Map.merge(
      %{
        "stage_id" => stage.id,
        "summary" => "clean — no drift, no new deps, no memory-pattern reintroduction."
      },
      overrides
    )
  end

  defp finding(overrides \\ %{}) do
    Map.merge(
      %{
        "constraint" => "module_boundary",
        "detail" => "Move the Chat query behind Platform.Chat.list_messages/1."
      },
      overrides
    )
  end

  # Every `[architect | audit_diff]` message in a space, newest last.
  defp annotations_in(nil), do: []

  defp annotations_in(space) do
    space.id
    |> ExecutionSpace.list_messages_with_participants()
    |> Enum.filter(fn m ->
      is_binary(m.content) and String.starts_with?(m.content, StageAudit.annotation_prefix())
    end)
  end

  # ── surface registration ─────────────────────────────────────────────

  describe "surface registration" do
    test "appears in the plan bundle with all six rubric components" do
      tools = ToolSurface.list_tools(["plan"])
      tool = Enum.find(tools, &(&1.name == "stage_architecture_audit"))

      assert tool, "stage_architecture_audit is not in the `plan` capability bundle"
      assert tool.bundle == "plan"

      for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
        assert Map.has_key?(tool, key), "rubric component #{inspect(key)} missing"
      end

      # PAIRED CONTROL: a tool that landed in no bundle, or in every
      # bundle, would satisfy the `in` check above by accident. `plan` is
      # the load-bearing choice — moore demonstrably carries it, because
      # `plan_architecture_verdict` lives there and she lands mcp-sourced
      # verdicts through it.
      refute Enum.any?(
               ToolSurface.list_tools(["task"]),
               &(&1.name == "stage_architecture_audit")
             )

      assert Enum.any?(tools, &(&1.name == "plan_architecture_verdict")),
             "the bundle assertion is only meaningful if the sibling architect tool is here too"
    end

    test "the limitations prose names exactly the error codes the clause emits" do
      # `intent_ack` / `task_ack` shipped `limitations` describing an error
      # taxonomy the code never emits, with no test guarding it. Remote
      # runtimes branch on these strings. This is that guard: the
      # documented set and the emitted set are COMPARED, not restated.
      tool =
        ToolSurface.list_tools(["plan"])
        |> Enum.find(&(&1.name == "stage_architecture_audit"))

      emitted = MapSet.new(ToolSurface.stage_audit_error_codes())

      documented =
        ToolSurface.stage_audit_error_codes()
        |> Enum.filter(&(tool.limitations =~ "`#{&1}`"))
        |> MapSet.new()

      assert documented == emitted,
             """
             Every code the clause can emit must be named in `limitations`.
             Missing: #{inspect(MapSet.difference(emitted, documented))}
             """
    end

    test "every declared code is REACHABLE — the taxonomy is not aspirational",
         %{project: project} do
      # The equality test above compares two lists in the same module. It
      # passes just as happily against a code nothing ever returns, which
      # is exactly the `intent_ack` failure. This test drives the surface
      # and collects the codes it ACTUALLY produces.
      ctx = opened_fixture(project)
      other = opened_fixture(project)

      observed =
        [
          call(note_args(ctx.stage, %{"stage_id" => Ecto.UUID.generate()})),
          call(note_args(ctx.stage, %{"summary" => "   "})),
          call(note_args(ctx.stage, %{"findings" => ["not an object"]})),
          call(note_args(ctx.stage, %{"findings" => [finding(%{"constraint" => "naming"})]})),
          call(note_args(audit_fixture(project).stage)),
          # `note_rejected`: a stage whose task has no execution space —
          # there is nowhere to post the note, so nothing is written.
          call(note_args(opened_fixture(project, execution_space: false).stage))
        ]
        |> Enum.map(fn {:error, refusal} -> refusal.code end)
        |> MapSet.new()

      # And the seventh, which needs a successful call first.
      assert {:ok, _} = call(note_args(other.stage))
      assert {:error, duplicate} = call(note_args(other.stage))

      observed = MapSet.put(observed, duplicate.code)

      assert observed == MapSet.new(ToolSurface.stage_audit_error_codes()),
             """
             The declared taxonomy and the reachable one disagree.
             Declared but never observed: #{inspect(MapSet.difference(MapSet.new(ToolSurface.stage_audit_error_codes()), observed))}
             Observed but undeclared: #{inspect(MapSet.difference(observed, MapSet.new(ToolSurface.stage_audit_error_codes())))}
             """
    end
  end

  # ── THE test of this stage: row and note, together or not at all ─────

  describe "GUARD: the row and the annotation land together" do
    test "a successful call leaves the row AND exactly one annotation", %{project: project} do
      ctx = opened_fixture(project)

      assert {:ok, result} =
               call(
                 note_args(ctx.stage, %{
                   "summary" => "divergence — the stage touched two subsystems.",
                   "findings" => [finding()]
                 })
               )

      assert result.state == "noted"
      assert result.source == "mcp"
      assert result.findings_count == 1
      assert result.task_id == ctx.task.id
      refute result.noted_after_deadline

      # HALF ONE — the row.
      audit = stored_audit(ctx.stage)
      assert audit["state"] == "noted"
      assert audit["source"] == "mcp"
      assert audit["resolved_at"]
      assert audit["summary"] =~ "divergence"
      assert [%{"constraint" => "module_boundary", "detail" => detail}] = audit["findings"]
      assert detail =~ "Platform.Chat.list_messages/1"

      # `read/1` agrees with the row — the projection must not disagree
      # with what was just written.
      assert {:resolved, projected} = StageAudit.read(ctx.stage.id)
      assert projected["state"] == "noted"

      # HALF TWO — the annotation. Neither half alone is evidence: a row
      # with no note is the operator-facing number this task exists to
      # make real, and a note with no row is today's bug.
      assert [annotation] = annotations_in(ctx.space)
      assert annotation.content =~ "divergence"
      assert annotation.content =~ "Platform.Chat.list_messages/1"

      # The prefix appears exactly once — the marker every execution-space
      # reader greps for must not be doubled.
      refute annotation.content =~
               StageAudit.annotation_prefix() <> StageAudit.annotation_prefix()
    end

    test "when the annotation cannot be posted, NOTHING is written", %{project: project} do
      # The other direction of the same invariant, and the reason
      # `note_rejected` exists. A task with no execution space has nowhere
      # to land the note; recording the row anyway would manufacture
      # exactly the uncountable-side-effect problem in reverse.
      ctx = opened_fixture(project, execution_space: false)

      assert {:error, refusal} = call(note_args(ctx.stage))
      assert refusal.code == :note_rejected
      assert refusal.suggestion =~ "together or not at all"

      assert stored_audit(ctx.stage)["state"] == "pending",
             "the audit must stay OPEN when its note could not be posted"

      refute stored_audit(ctx.stage)["summary"]

      # PAIRED POSITIVE CONTROL: the identical call against a stage whose
      # task HAS an execution space lands. Without this, the refusal above
      # passes against a clause that refuses everything.
      with_space = opened_fixture(project)
      assert {:ok, _} = call(note_args(with_space.stage))
      assert stored_audit(with_space.stage)["state"] == "noted"
      assert [_one] = annotations_in(with_space.space)
    end
  end

  # ── one-shot ─────────────────────────────────────────────────────────

  # WHAT GUARDS ONE-SHOT, measured rather than asserted. The property is
  # protected TWICE over: `open_audit/1` refuses a non-pending audit in
  # memory, and the guarded UPDATE carries its own `state = 'pending'`
  # predicate so zero rows affected IS the already-recorded answer.
  #
  # Those two mechanisms MASK EACH OTHER, and the controls say so. Deleting
  # the SQL predicate alone: this file stays fully green. Deleting the
  # in-memory clause alone (making it return `{:ok, audit}` for a terminal
  # row): also fully green. Deleting BOTH: four failures here. So the
  # BEHAVIOUR is guarded and the file detects its loss — but no test below
  # pins either mechanism individually, and that is not fixable by writing
  # a cleverer test.
  #
  # The reason it is not fixable is worth recording, because the obvious
  # attempt looks like it should work and does not. To reach the predicate
  # you need two writers that BOTH observed an open audit; the natural way
  # to stage that deterministically is to hand `record_note/3` a stale
  # `%Stage{}` loaded while the audit was still pending. That is
  # unreachable: `resolve_stage/1` re-reads the row by id
  # (`stage_audit.ex:514`) precisely so a caller holding a struct from
  # before the write cannot get a stale answer. The caller's struct is
  # discarded, so the in-memory gate always reflects committed state and
  # the predicate can only ever fire under genuine cross-connection
  # concurrency — which the Ecto sandbox, one connection per test, cannot
  # express. It is defence-in-depth against a race this suite cannot stage,
  # and calling it "tested" here would be the kind of claim this task
  # exists to stop shipping.
  #
  # AMENDED, stage 4, and the amendment is a correction rather than a
  # footnote. The re-read in `resolve_stage/1` is a THIRD mechanism, and
  # the test below does not pin it either: replace that clause with
  # `resolve_stage(%Stage{} = stage), do: stage` and this whole file stays
  # green, because the SQL predicate refuses the write for a different
  # reason and produces the identical `:audit_already_recorded`. Measured,
  # not reasoned.
  #
  # What DOES pin it is stage 4's external path, and only because it
  # exercises the property in the opposite direction: `handle_output/3`
  # hands `record_note/3` a `%Stage{}` whose `architecture_audit` is still
  # `nil` (the trigger meta's struct was loaded before the fire), so
  # without the re-read the in-memory gate answers `:audit_not_open` and
  # NOTHING is recorded. No SQL predicate can cover for that — a refusal
  # cannot be masked by a guard that never runs. See
  # `architecture_dispatch_test.exs` and
  # `plan_engine_architect_drift_hook_test.exs`, both of which fail on
  # that edit.
  describe "GUARD: one-shot, arbitrated on the persisted row" do
    test "a duplicate call is refused and changes neither the row nor the space",
         %{project: project} do
      ctx = opened_fixture(project)

      assert {:ok, _} =
               call(note_args(ctx.stage, %{"summary" => "first note", "findings" => [finding()]}))

      before = stored_audit(ctx.stage)

      assert {:error, refusal} =
               call(
                 note_args(ctx.stage, %{
                   "summary" => "second note, entirely different",
                   "findings" => [
                     finding(%{"constraint" => "data_model", "detail" => "Drop the column."})
                   ]
                 })
               )

      assert refusal.code == :audit_already_recorded
      refute refusal.recoverable

      # Byte-identical: the newer text must not have overwritten anything.
      assert stored_audit(ctx.stage) == before
      assert before["summary"] == "first note"

      # And still exactly ONE annotation — a refusal that still posted
      # would be a duplicate note in the human's log.
      assert [annotation] = annotations_in(ctx.space)
      assert annotation.content =~ "first note"
      refute annotation.content =~ "second note"
    end

    test "a STALE stage struct is safe — record_note/3 re-reads and refuses",
         %{project: project} do
      # Not a concurrency test (see the note above — that race is not
      # stageable here). This pins the property that MAKES the in-memory
      # gate trustworthy, and stage 4 depends on it directly:
      # `handle_output/3` will reach `record_note/3` carrying a `%Stage{}`
      # from the fire, not a fresh read, and that struct is by then
      # arbitrarily old. A writer that trusted it would overwrite a note
      # already landed by the MCP path — the two sources diverging again,
      # one layer down from the defect this task is closing.
      ctx = opened_fixture(project)
      stale = ctx.stage

      assert stale.architecture_audit["state"] == "pending",
             "precondition: the held struct must still believe the audit is open"

      assert {:ok, _} = call(note_args(ctx.stage, %{"summary" => "landed via mcp"}))

      # The struct in hand is now a lie. The writer must not believe it.
      assert stale.architecture_audit["state"] == "pending"

      assert {:error, :audit_already_recorded} =
               StageAudit.record_note(stale, %{summary: "clobber attempt", findings: []})

      assert stored_audit(ctx.stage)["summary"] == "landed via mcp"
      assert [annotation] = annotations_in(ctx.space)
      refute annotation.content =~ "clobber attempt"

      # PAIRED CONTROL: the staleness is what is refused, not the struct
      # entry point. The same direct call on a still-open audit lands, and
      # posts.
      other = opened_fixture(project)

      assert {:ok, _} =
               StageAudit.record_note(other.stage, %{summary: "uncontended", findings: []})

      assert stored_audit(other.stage)["state"] == "noted"
      assert [_one] = annotations_in(other.space)
    end

    test "an audit that never fired refuses distinctly from one already answered",
         %{project: project} do
      # The two "no" answers must be separable: an architect who was never
      # asked and an architect who was beaten to it need different next
      # actions, and collapsing them is the same conflation this whole
      # task is undoing one layer up.
      never_fired = audit_fixture(project)
      assert is_nil(stored_audit(never_fired.stage))

      assert {:error, not_open} = call(note_args(never_fired.stage))
      assert not_open.code == :audit_not_open
      assert not_open.error =~ "no fire was ever recorded"

      answered = opened_fixture(project)
      assert {:ok, _} = call(note_args(answered.stage))
      assert {:error, already} = call(note_args(answered.stage))
      assert already.code == :audit_already_recorded

      refute not_open.code == already.code
    end

    test "a TERMINAL non-noted audit is also already-recorded", %{project: project} do
      # `skipped` and `failed` are written at fire time by
      # `open_from_fire/2`. Neither is open, and an architect must not be
      # able to paper a failed fire over with a note that implies she read
      # something.
      for {fire, state} <- [{{:ok, :unfilled}, "skipped"}, {{:error, :boom}, "failed"}] do
        ctx = audit_fixture(project)
        {:ok, stage} = StageAudit.open_from_fire(ctx.stage, fire)
        assert stage.architecture_audit["state"] == state

        assert {:error, refusal} = call(note_args(stage))
        assert refusal.code == :audit_already_recorded
        assert stored_audit(stage)["state"] == state
        assert annotations_in(ctx.space) == []
      end
    end
  end

  # ── the late note ────────────────────────────────────────────────────

  describe "GUARD: a late note WINS and says so" do
    test "past the deadline the note is accepted and marks noted_after_deadline",
         %{project: project} do
      Application.put_env(:platform, :architecture_audit_timeout_ms, 1)
      ctx = opened_fixture(project)

      # The projection already calls it expired…
      Process.sleep(5)
      assert {:resolved, projected} = StageAudit.read(ctx.stage.id)
      assert projected["state"] == "expired"
      assert projected["source"] == "deadline"

      # …but the PERSISTED row is still pending, and that is what the
      # writer arbitrates on. An architect who engaged late still engaged.
      assert stored_audit(ctx.stage)["state"] == "pending"

      assert {:ok, result} = call(note_args(ctx.stage, %{"summary" => "late but read"}))
      assert result.state == "noted"
      assert result.noted_after_deadline == true

      audit = stored_audit(ctx.stage)
      assert audit["state"] == "noted"
      assert audit["source"] == "mcp"
      assert audit["noted_after_deadline"] == true

      # The upgrade must not ERASE the elapsed deadline — that is the
      # whole reason the extra key exists rather than just flipping the
      # state.
      assert audit["deadline_at"] == projected["deadline_at"]

      assert [_annotation] = annotations_in(ctx.space)
      assert StageAudit.read(ctx.stage.id) |> elem(1) |> Map.get("state") == "noted"
    end

    test "an ON-TIME note does NOT carry the marker", %{project: project} do
      # PAIRED CONTROL for the test above, and not optional: a writer that
      # stamped `noted_after_deadline` unconditionally would pass the
      # late case and be strictly worse than not having the key.
      Application.put_env(:platform, :architecture_audit_timeout_ms, 30 * 60 * 1_000)
      ctx = opened_fixture(project)

      assert {:ok, result} = call(note_args(ctx.stage))
      refute result.noted_after_deadline
      refute Map.has_key?(stored_audit(ctx.stage), "noted_after_deadline")
    end
  end

  # ── argument validation ──────────────────────────────────────────────

  describe "GUARD: a style objection has no representable value" do
    test "\"naming\" is refused and leaves the audit open; \"module_boundary\" lands it",
         %{project: project} do
      ctx = opened_fixture(project)

      assert {:error, refusal} =
               call(note_args(ctx.stage, %{"findings" => [finding(%{"constraint" => "naming"})]}))

      assert refusal.code == :invalid_constraint
      assert refusal.error =~ "not an architectural constraint"
      assert refusal.suggestion =~ "taste, naming or style"

      # A refused call must not consume the audit, and must not post.
      assert stored_audit(ctx.stage)["state"] == "pending"
      assert annotations_in(ctx.space) == []

      # PAIRED POSITIVE CONTROL: the identical payload with an allowed
      # constraint lands.
      assert {:ok, result} = call(note_args(ctx.stage, %{"findings" => [finding()]}))
      assert result.findings_count == 1
      assert stored_audit(ctx.stage)["state"] == "noted"
    end

    test "every value in Plan.architecture_constraints/0 is accepted", %{project: project} do
      # The closed set is closed from BOTH ends: the test above proves
      # nothing outside it gets in, this proves nothing inside it is
      # accidentally excluded. A typo in the tool's copy of the list would
      # otherwise pass the file.
      for constraint <- Plan.architecture_constraints() do
        ctx = opened_fixture(project)

        assert {:ok, _} =
                 call(
                   note_args(ctx.stage, %{
                     "findings" => [finding(%{"constraint" => constraint})]
                   })
                 ),
               "constraint #{inspect(constraint)} is in Plan.architecture_constraints/0 but the tool refused it"

        assert [%{"constraint" => ^constraint}] = stored_audit(ctx.stage)["findings"]
      end
    end
  end

  describe "GUARD: argument shape" do
    test "a blank summary is refused; a clean-result summary is not", %{project: project} do
      ctx = opened_fixture(project)

      for blank <- ["", "   ", nil, 42] do
        assert {:error, refusal} = call(note_args(ctx.stage, %{"summary" => blank}))
        assert refusal.code == :missing_summary
        assert refusal.suggestion =~ "no drift, no new deps"
        assert stored_audit(ctx.stage)["state"] == "pending"
      end

      # PAIRED CONTROL, and the case that matters most in practice: a
      # CLEAN audit is still a summary. The prompt asks for one precisely
      # so "the architect found nothing" stops looking like "the architect
      # never ran".
      assert {:ok, result} =
               call(note_args(ctx.stage, %{"summary" => "clean — nothing to flag."}))

      assert result.findings_count == 0
      assert result.summary == "clean — nothing to flag."
      assert [annotation] = annotations_in(ctx.space)
      assert annotation.content =~ "clean"
    end

    test "findings are OPTIONAL — omitted, nil and [] all land a clean audit",
         %{project: project} do
      for findings <- [:omitted, nil, []] do
        ctx = opened_fixture(project)

        args =
          case findings do
            :omitted -> note_args(ctx.stage)
            other -> note_args(ctx.stage, %{"findings" => other})
          end

        assert {:ok, result} = call(args)
        assert result.findings_count == 0
        assert stored_audit(ctx.stage)["findings"] == []
      end
    end

    test "a malformed finding is refused and nothing is written", %{project: project} do
      ctx = opened_fixture(project)

      malformed = [
        ["not a list of objects"],
        [finding(%{"detail" => "  "})],
        [finding(%{"detail" => nil})],
        "findings as a bare string"
      ]

      for findings <- malformed do
        assert {:error, refusal} = call(note_args(ctx.stage, %{"findings" => findings})),
               "expected #{inspect(findings)} to be refused"

        assert refusal.code == :malformed_finding
        assert refusal.suggestion =~ "WHAT TO CHANGE"
      end

      assert stored_audit(ctx.stage)["state"] == "pending"
      assert annotations_in(ctx.space) == []

      # PAIRED CONTROL: a well-formed finding on the same audit lands.
      assert {:ok, _} = call(note_args(ctx.stage, %{"findings" => [finding()]}))
      assert stored_audit(ctx.stage)["state"] == "noted"
    end

    test "an unknown or malformed stage_id refuses as stage_not_found", %{project: project} do
      for bad <- [Ecto.UUID.generate(), "not-a-uuid", "", nil, 7] do
        assert {:error, refusal} = call(note_args(%Stage{id: "x"}, %{"stage_id" => bad}))
        assert refusal.code == :stage_not_found
        refute refusal.recoverable
      end

      # PAIRED CONTROL: a real stage id resolves.
      ctx = opened_fixture(project)
      assert {:ok, _} = call(note_args(ctx.stage))
    end
  end

  # ── identity ─────────────────────────────────────────────────────────

  describe "resolved_by" do
    test "records the calling agent, and READS BACK string-keyed", %{project: project} do
      ctx = opened_fixture(project)
      agent_id = Ecto.UUID.generate()

      assert {:ok, _} =
               ToolSurface.execute(
                 "stage_architecture_audit",
                 note_args(ctx.stage),
                 %{agent_id: agent_id}
               )

      # This pins the READ shape, which is what every consumer of the row
      # depends on — and that is all it pins. An earlier version of this
      # comment claimed the assertion also catches a writer that builds the
      # map with ATOM keys; it does not, and the control was run. Switching
      # `stage_audit_resolved_by/1` to `%{kind: kind, id: id}` leaves this
      # file fully green: atoms are encoded as JSON strings on the way into
      # the `:map` column and come back string-keyed either way, so the
      # write-side distinction is invisible after one round trip. Asserting
      # on a RE-READ row is the honest scope — `resolved_by` is
      # string-keyed by the time anyone reads it, whatever the writer typed.
      assert stored_audit(ctx.stage)["resolved_by"] == %{"kind" => "agent", "id" => agent_id}
    end

    test "a context with no identity still lands the note", %{project: project} do
      # `resolved_by` is evidence, not a precondition. An architect whose
      # runtime did not populate the identity must still be able to record
      # what she found — refusing here would lose the audit to protect an
      # attribution field.
      ctx = opened_fixture(project)

      assert {:ok, _} = call(note_args(ctx.stage))
      assert stored_audit(ctx.stage)["state"] == "noted"
      refute stored_audit(ctx.stage)["resolved_by"]
    end
  end
end
