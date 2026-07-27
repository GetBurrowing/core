defmodule Platform.Federation.PlanArchitectureVerdictToolTest do
  @moduledoc """
  ADR-0046 member 5, stage 4 — `plan_architecture_verdict`, the MCP
  surface a native architect actually calls.

  ## What this file is asserting, and why it is not a "guards only" stage

  Stages 1 and 3 built the state machine. This stage builds the two ways
  a verdict gets INTO it. The load-bearing claim here is not "the tool
  works" — it is that **the contract is enforced at the boundary rather
  than requested in the prompt.** ADR-0046:95 says the architect rejects
  for architecture and explicitly not for taste, naming or style. As
  prose that is unenforceable: a model told not to reject on style
  produces a differently-worded style rejection. A CLOSED `constraint`
  vocabulary means a style objection has no representable value at all.

  Every absence assertion below is paired with its positive control in
  the SAME test, so a validator that simply refuses everything fails the
  file. The measured vacuity-control results are recorded on each guard.

  Not `async: true`: `resolve_architecture_gate/3` settles through
  `maybe_auto_approve/1`, which broadcasts on `tasks:board` and wakes the
  singleton `TaskRouterWatcher` (`019fa003-091a`). Fixtures go through
  `Repo.insert!` where the shape allows, for the same reason.
  """
  use Platform.DataCase, async: false

  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, Task}

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Verdict Tool Project #{u()}"})
    %{project: project}
  end

  # A task that WOULD auto-approve once the gate releases: the flag plus
  # both `auto_approve_precondition/2` legs. Without all three the
  # full-chain guard below would pass for the wrong reason.
  defp gate_fixture(project, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Verdict fixture #{u()}",
        status: "planning",
        auto_approve_plan: Keyword.get(opts, :auto_approve_plan, true),
        phase_assignees: %{
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})

    {task, plan, stage}
  end

  # The state the gated submit leaves behind, reached directly so these
  # tests exercise the TOOL rather than re-testing stage 2's branch.
  defp open_gate!(task, plan) do
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, "moore")
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)
    gated
  end

  defp gated_fixture(project, opts \\ []) do
    {task, plan, stage} = gate_fixture(project, opts)
    {task, open_gate!(task, plan), stage}
  end

  defp verdict_state(%Plan{id: id}), do: verdict_state(id)

  defp verdict_state(plan_id) when is_binary(plan_id) do
    (Repo.get!(Plan, plan_id).architecture_verdict || %{}) |> Map.get("state")
  end

  defp stored_verdict(%Plan{id: id}), do: Repo.get!(Plan, id).architecture_verdict

  defp call(args), do: ToolSurface.execute("plan_architecture_verdict", args, %{})

  defp reject_args(plan, stage, overrides \\ %{}) do
    Map.merge(
      %{
        "plan_id" => plan.id,
        "verdict" => "reject",
        "summary" => "Stage 1 crosses a context boundary.",
        "findings" => [
          %{
            "stage_id" => stage.id,
            "constraint" => "module_boundary",
            "detail" => "Move the Chat query behind Platform.Chat.list_messages/1."
          }
        ]
      },
      overrides
    )
  end

  # ── the tool is on the surface, with the six-component rubric ─────────
  #
  # The rubric itself is asserted for EVERY tool by
  # `tool_surface_test.exs`'s "all_tools/0 …" block, which this stage
  # extended with the name rather than duplicating. What is here is the
  # bundle placement, which that block does not pin per-tool.

  describe "surface registration" do
    test "appears in the plan bundle with all six rubric components" do
      tools = ToolSurface.list_tools(["plan"])
      tool = Enum.find(tools, &(&1.name == "plan_architecture_verdict"))

      assert tool, "plan_architecture_verdict is not in the `plan` capability bundle"
      assert tool.bundle == "plan"

      for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
        assert Map.has_key?(tool, key), "rubric component #{inspect(key)} missing"
      end

      # PAIRED CONTROL for the bundle assertion: a tool that landed in no
      # bundle, or in every bundle, would satisfy the `in` check above by
      # accident.
      refute Enum.any?(
               ToolSurface.list_tools(["task"]),
               &(&1.name == "plan_architecture_verdict")
             )
    end

    test "the limitations prose names exactly the error codes the clause emits" do
      # The 2026-07-26 e2e journal records `intent_ack` / `task_ack`
      # shipping `limitations` prose describing an error taxonomy the code
      # never emits, with no test guarding it. Remote runtimes branch on
      # these strings. This is that guard: the documented set and the
      # emitted set are compared, not restated.
      tool =
        ToolSurface.list_tools(["plan"])
        |> Enum.find(&(&1.name == "plan_architecture_verdict"))

      documented =
        ToolSurface.architecture_verdict_error_codes()
        |> Enum.filter(&(tool.limitations =~ "`#{&1}`"))
        |> MapSet.new()

      assert documented == MapSet.new(ToolSurface.architecture_verdict_error_codes()),
             """
             Every code the clause can emit must be named in `limitations`.
             Missing: #{inspect(MapSet.difference(MapSet.new(ToolSurface.architecture_verdict_error_codes()), documented))}
             """
    end
  end

  # ── DETECTOR / GUARD: the closed constraint vocabulary ────────────────
  #
  # THE test of this stage. Both halves in one test on purpose: the
  # refusal alone would pass against a clause that refuses every reject,
  # and the acceptance alone would pass against a clause with no
  # vocabulary check at all.
  #
  # VACUITY CONTROL, MEASURED: dropping the `constraint in
  # Plan.architecture_constraints()` leg of `validate_verdict_finding/2`
  # makes the FIRST half fail (`"naming"` is accepted, the gate resolves
  # `rejected`) while the second half still passes. Replacing the whole
  # finding validator with a blanket refusal makes the SECOND half fail.
  # Neither half is vacuous.

  describe "GUARD: a style objection has no representable value" do
    test "\"naming\" is refused and leaves the gate pending; \"module_boundary\" resolves it",
         %{project: project} do
      {_task, gated, stage} = gated_fixture(project)

      assert {:error, refusal} =
               call(
                 reject_args(gated, stage, %{
                   "findings" => [
                     %{
                       "stage_id" => stage.id,
                       "constraint" => "naming",
                       "detail" => "I would have called this something else."
                     }
                   ]
                 })
               )

      assert refusal.code == :invalid_constraint
      assert refusal.error =~ "not an architectural constraint"
      assert refusal.suggestion =~ "taste, naming or style"

      # The gate is UNTOUCHED — a refused call must not consume it.
      assert verdict_state(gated) == "pending"
      assert Tasks.architecture_gate_open?(gated)

      # PAIRED POSITIVE CONTROL: the identical payload with an allowed
      # constraint is accepted and resolves the gate.
      assert {:ok, result} = call(reject_args(gated, stage))

      assert result.verdict == "reject"
      assert result.state == "rejected"
      assert result.findings_count == 1
      assert verdict_state(gated) == "rejected"
      refute Tasks.architecture_gate_open?(gated)
    end

    test "every value in Plan.architecture_constraints/0 is accepted", %{project: project} do
      # The closed set is closed from BOTH ends: the test above proves
      # nothing outside it gets in, this proves nothing inside it is
      # accidentally excluded. A typo in the tool's copy of the list would
      # otherwise pass the file.
      for constraint <- Plan.architecture_constraints() do
        {_task, gated, stage} = gated_fixture(project)

        assert {:ok, _result} =
                 call(
                   reject_args(gated, stage, %{
                     "findings" => [
                       %{
                         "stage_id" => stage.id,
                         "constraint" => constraint,
                         "detail" => "Change the shape at stage 1."
                       }
                     ]
                   })
                 ),
               "constraint #{inspect(constraint)} is in Plan.architecture_constraints/0 but the tool refused it"

        assert verdict_state(gated) == "rejected"
      end
    end
  end

  # ── GUARD: an unactionable reject cannot be sent ──────────────────────

  describe "GUARD: reject shape" do
    test "reject with empty findings is refused and the gate stays pending", %{project: project} do
      {_task, gated, stage} = gated_fixture(project)

      for empty <- [[], nil] do
        assert {:error, refusal} = call(reject_args(gated, stage, %{"findings" => empty}))
        assert refusal.code == :missing_findings
        assert refusal.suggestion =~ "one finding per objection"
        assert verdict_state(gated) == "pending"
      end

      # PAIRED CONTROL: the same call WITH findings lands.
      assert {:ok, _} = call(reject_args(gated, stage))
      assert verdict_state(gated) == "rejected"
    end

    test "a pass needs no findings — the requirement is reject-only", %{project: project} do
      {_task, gated, _stage} = gated_fixture(project)

      assert {:ok, result} =
               call(%{
                 "plan_id" => gated.id,
                 "verdict" => "pass",
                 "summary" => "No new module, no new table. Clean."
               })

      assert result.state == "passed"
      assert result.findings_count == 0
    end

    test "a stage_id from a different plan is refused", %{project: project} do
      {_task, gated, _stage} = gated_fixture(project)
      {_other_task, _other_plan, foreign_stage} = gate_fixture(project)

      assert {:error, refusal} =
               call(
                 reject_args(gated, foreign_stage, %{
                   "findings" => [
                     %{
                       "stage_id" => foreign_stage.id,
                       "constraint" => "data_model",
                       "detail" => "Widen the column."
                     }
                   ]
                 })
               )

      assert refusal.code == :foreign_stage_id
      assert refusal.suggestion =~ "stale context"
      assert verdict_state(gated) == "pending"
    end

    test "a blank detail is refused — \"what is wrong\" is not \"what to change\"", %{
      project: project
    } do
      {_task, gated, stage} = gated_fixture(project)

      assert {:error, refusal} =
               call(
                 reject_args(gated, stage, %{
                   "findings" => [
                     %{"stage_id" => stage.id, "constraint" => "data_model", "detail" => "   "}
                   ]
                 })
               )

      assert refusal.code == :malformed_finding
      assert verdict_state(gated) == "pending"
    end

    test "a blank summary is refused on both verdicts", %{project: project} do
      {_task, gated, stage} = gated_fixture(project)

      assert {:error, %{code: :missing_summary}} =
               call(%{"plan_id" => gated.id, "verdict" => "pass", "summary" => "  "})

      assert {:error, %{code: :missing_summary}} =
               call(reject_args(gated, stage, %{"summary" => nil}))

      assert verdict_state(gated) == "pending"
    end

    test "a verdict word outside pass/reject is refused", %{project: project} do
      {_task, gated, _stage} = gated_fixture(project)

      assert {:error, refusal} =
               call(%{"plan_id" => gated.id, "verdict" => "maybe", "summary" => "Unsure."})

      assert refusal.code == :invalid_verdict
      assert verdict_state(gated) == "pending"
    end
  end

  # ── GUARD: gate-state refusals name the ACTUAL state ──────────────────

  describe "GUARD: gate state" do
    test "a plan whose gate never opened is refused with gate_not_open", %{project: project} do
      {_task, plan, _stage} = gate_fixture(project)

      assert {:error, refusal} =
               call(%{"plan_id" => plan.id, "verdict" => "pass", "summary" => "Looks fine."})

      assert refusal.code == :gate_not_open
      assert refusal.error =~ "never opened"
      assert is_nil(Repo.get!(Plan, plan.id).architecture_verdict)
    end

    test "an expired gate is refused NAMING the expiry, not with a generic error", %{
      project: project
    } do
      Application.put_env(:platform, :architecture_gate_timeout_ms, 0)
      on_exit(fn -> Application.delete_env(:platform, :architecture_gate_timeout_ms) end)

      {_task, gated, _stage} = gated_fixture(project)

      assert {:error, refusal} =
               call(%{"plan_id" => gated.id, "verdict" => "pass", "summary" => "Late."})

      assert refusal.code == :gate_already_resolved

      assert refusal.error =~ "expired",
             "a duplicate/late call must read as an explanation, not a mystery — got: #{refusal.error}"
    end

    test "an unknown plan_id and a non-UUID plan_id both refuse rather than raise" do
      # `Accounts.get_user/1` raises `Ecto.Query.CastError` on a non-UUID
      # binary because it is a bare `Repo.get/2` — stage 3 hit that. The
      # same shape would apply here, so `verdict_plan/1` casts first. A
      # tool clause that raises is a 500 to the remote runtime, not a
      # refusal it can act on.
      for bad <- [Ecto.UUID.generate(), "not-a-uuid", nil, 42] do
        assert {:error, %{code: :plan_not_found}} =
                 call(%{"plan_id" => bad, "verdict" => "pass", "summary" => "x"})
      end
    end
  end

  # ── GUARD: the full chain an agent actually walks ─────────────────────

  describe "GUARD: submit → gate opens → tool passes → plan approves" do
    test "an auto_approve_plan task lands approved / \"system:auto\" through the tool", %{
      project: project
    } do
      {task, plan, _stage} = gate_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      # Held: the deferred tail has NOT run yet.
      assert Repo.get!(Plan, gated.id).status == "pending_review"
      assert Repo.get!(Task, task.id).planning_step == "architecting"

      assert {:ok, result} =
               call(%{
                 "plan_id" => gated.id,
                 "verdict" => "pass",
                 "summary" => "No new module, context, table or cross-context call. Pass."
               })

      assert result.state == "passed"

      approved = Repo.get!(Plan, gated.id)
      assert approved.status == "approved"
      assert approved.approved_by == "system:auto"

      # The cursor came back off `:architecting` — the gate is what
      # parked it there.
      assert Repo.get!(Task, task.id).planning_step == "planning"
    end
  end

  # ── GUARD: idempotence at the boundary ────────────────────────────────

  describe "GUARD: a duplicate call is harmless" do
    test "the second call returns the already-resolved envelope and re-approves nothing", %{
      project: project
    } do
      {task, plan, _stage} = gate_fixture(project, auto_approve_plan: true)
      gated = open_gate!(task, plan)

      args = %{"plan_id" => gated.id, "verdict" => "pass", "summary" => "Clean."}

      assert {:ok, _first} = call(args)

      first_row = Repo.get!(Plan, gated.id)
      first_verdict = first_row.architecture_verdict

      assert {:error, refusal} = call(args)
      assert refusal.code == :gate_already_resolved
      assert refusal.recoverable == false

      second_row = Repo.get!(Plan, gated.id)

      # NOTHING moved: not the verdict, not the plan, not the approver.
      assert second_row.architecture_verdict == first_verdict
      assert second_row.status == first_row.status
      assert second_row.approved_by == first_row.approved_by
      assert second_row.updated_at == first_row.updated_at

      # And no second plan version appeared.
      assert length(Tasks.list_plans(task.id)) == 1
    end

    test "a reject after a pass is refused — the gate is one-shot, not last-writer-wins", %{
      project: project
    } do
      {_task, gated, stage} = gated_fixture(project)

      assert {:ok, _} =
               call(%{"plan_id" => gated.id, "verdict" => "pass", "summary" => "Clean."})

      assert {:error, %{code: :gate_already_resolved}} = call(reject_args(gated, stage))

      assert verdict_state(gated) == "passed"
    end
  end

  # ── GUARD: what the tool actually stores ──────────────────────────────

  describe "the persisted verdict" do
    test "carries the architect's summary, normalised findings and the source", %{
      project: project
    } do
      {_task, gated, stage} = gated_fixture(project)

      assert {:ok, _} =
               call(
                 reject_args(gated, stage, %{
                   "summary" => "  Stage 1 duplicates the sibling's helper.  ",
                   "findings" => [
                     %{
                       "stage_id" => stage.id,
                       "constraint" => "duplicated_logic",
                       "detail" => "  Call Platform.Tasks.list_stages/1 instead.  "
                     }
                   ]
                 })
               )

      verdict = stored_verdict(gated)

      assert verdict["state"] == "rejected"
      assert verdict["summary"] == "Stage 1 duplicates the sibling's helper."
      assert verdict["source"] == "architect"
      assert verdict["resolved_at"]

      assert [%{"stage_id" => sid, "constraint" => "duplicated_logic", "detail" => detail}] =
               verdict["findings"]

      assert sid == stage.id
      assert detail == "Call Platform.Tasks.list_stages/1 instead."

      # The gate's opening fields survived the merge — a resolver that
      # replaced the map rather than merging would lose the deadline and
      # with it the ability to tell a late verdict from a timely one.
      assert verdict["opened_at"]
      assert verdict["deadline_at"]
      assert verdict["architect_agent_id"] == "moore"
    end

    test "records the calling agent as resolved_by", %{project: project} do
      {_task, gated, _stage} = gated_fixture(project)

      assert {:ok, _} =
               ToolSurface.execute(
                 "plan_architecture_verdict",
                 %{"plan_id" => gated.id, "verdict" => "pass", "summary" => "Clean."},
                 %{agent_id: "moore"}
               )

      assert stored_verdict(gated)["resolved_by"] == "moore"
    end
  end
end
