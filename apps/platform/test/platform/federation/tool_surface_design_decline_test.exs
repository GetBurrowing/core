defmodule Platform.Federation.ToolSurfaceDesignDeclineTest do
  @moduledoc """
  `task_design_decline` — the MCP surface a dispatched designer actually
  calls to say "this needs no design direction" (task `019fa504` stage 2,
  ADR-0046 member 7).

  ## What this file is asserting, and why the bundle assertion is the point

  Stage 1 built `PreplanStep.decline/3`. A plain Elixir function is not an
  exit for a designer: a designer runtime reaches Suite ONLY through
  `Platform.Federation.ToolSurface` via `/mcp`. So the load-bearing claim
  of this stage is not "the tool works" — it is that the exit is
  **reachable from the runtime that needs it, without a new grant**.

  That claim is only testable as a PAIR. `task_design_decline` appearing in
  `ToolAuthorization.tool_names/1` for a runtime holding exactly `["task"]`
  is satisfied just as well by a tool that landed in every bundle, or in
  none-and-therefore-listed-by-accident. The control — the same assertion
  inverted for a runtime holding exactly `["canvas"]` — is what makes the
  first one mean "in the task bundle". Mirrors `tool_authorization_test.exs`
  and the paired bundle control in `plan_architecture_verdict_tool_test.exs`.

  The `task` bundle specifically, because that is where `task_attach_canvas`
  lives — the designer's PROVEN delivery path (`prompt_templates.ex`'s
  `design.task_direction.v1` names it as the one deliverable instruction).
  Co-locating the decline makes its reachability co-extensive with a path
  already known to work on every designer runtime in existence. A new
  bundle would ship an affordance nobody can call until someone hand-edits
  every `tool_profile` row — which is the failure mode this task exists
  to fix, re-committed. That co-extensiveness is asserted directly below,
  not left as prose.

  ## The refusal taxonomy is compared, not restated

  The 2026-07-26 e2e journal records `intent_ack` / `task_ack` shipping
  `limitations` prose describing an error taxonomy the code never emits,
  with no test guarding it. Remote runtimes branch on these strings. So the
  documented set (`limitations`) and the emitted set (every refusal driven
  through `execute/3`) are compared against each other, exactly as
  `plan_architecture_verdict_tool_test.exs` does for the architect's tool.

  ## Vacuity disclosure

  `{:error, :invalid_note}` from `decline/3` maps to `missing_reason` and
  not to `decline_failed`, but is UNREACHABLE through this tool: the
  argument validator refuses a non-binary `reason` before the call is made.
  The clause exists so a future caller that skips the validator cannot have
  its own bad argument reported as a fact about the task's state. It is
  pinned at the `PreplanStep` level below rather than pretended to be
  exercised through `execute/3`.

  Not `async: true`: `decline/3` writes through `Tasks.record_planning_step/3`,
  which broadcasts `{:task_updated, _}` on `tasks:board` and wakes the
  singleton `TaskRouterWatcher` — the same reason
  `plan_architecture_verdict_tool_test.exs` gives in its moduledoc.
  """

  use Platform.DataCase, async: false

  alias Platform.Design.PreplanStep
  alias Platform.ExternalUserFixtures, as: World
  alias Platform.Federation.ToolAuthorization
  alias Platform.Federation.ToolSurface
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task, as: TaskSchema
  alias Platform.Tenancy

  # Stage 1's own doctest example, and `task_router_test.exs`'s
  # `@design_ui_title` — a title whose classifier verdict is not in doubt,
  # so `matched` is non-empty and the evidence annotations are real.
  @ui_title "Add an epic-create FAB above the board"
  @reason "The change is not visual; it deletes a deprecated module."

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Decline Tool Project #{unique()}"})

    %{project: project}
  end

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp unique, do: System.unique_integer([:positive])

  # Raw `Ecto.Changeset.change/2` rather than `Tasks.create_task/1`, the same
  # shape `preplan_step_test.exs` uses: it lets a fixture carry a
  # `planning_step_outcomes` value the public changeset would refuse, which is
  # how the `decline_failed` branch is reached deterministically below.
  defp task!(project, title, attrs \\ %{}) do
    now = DateTime.utc_now()

    %TaskSchema{}
    |> Ecto.Changeset.change(
      Map.merge(
        %{
          project_id: project.id,
          title: title,
          status: "planning",
          inserted_at: now,
          updated_at: now
        },
        attrs
      )
    )
    |> Repo.insert!()
  end

  defp reload(%TaskSchema{id: id}), do: Repo.get!(TaskSchema, id)

  defp design_entry(task), do: (reload(task).planning_step_outcomes || %{})["design"]

  defp cursor(task), do: reload(task).planning_step

  # Returns the function's VALUE (unlike `capture_log/2`), because the
  # refusal-taxonomy sweep below needs the envelopes, not the log.
  defp quietly(fun) do
    {result, _log} = ExUnit.CaptureLog.with_log(fun)
    result
  end

  defp decline(args, context \\ %{}) do
    quietly(fn -> ToolSurface.execute("task_design_decline", args, context) end)
  end

  defp runtime(owner_user_id, modules) do
    Platform.RuntimeProfileFixtures.runtime!(owner_user_id, modules)
  end

  # ── surface registration ──────────────────────────────────────────────────

  describe "surface registration" do
    test "appears in the task bundle with all six rubric components" do
      tool =
        ToolSurface.list_tools(["task"])
        |> Enum.find(&(&1.name == "task_design_decline"))

      assert tool, "task_design_decline is not in the `task` capability bundle"
      assert tool.bundle == "task"

      for key <- [:name, :description, :parameters, :returns, :limitations, :when_to_use] do
        assert Map.has_key?(tool, key), "rubric component #{inspect(key)} missing"
      end

      # PAIRED CONTROL for the bundle assertion: a tool that landed in no
      # bundle, or in every bundle, would satisfy the `find` above by accident.
      refute Enum.any?(
               ToolSurface.list_tools(["plan"]),
               &(&1.name == "task_design_decline")
             )

      assert Enum.any?(ToolSurface.tool_definitions(), &(&1.name == "task_design_decline"))
    end

    test "the limitations prose names exactly the refusal codes the clause emits" do
      tool =
        ToolSurface.list_tools(["task"])
        |> Enum.find(&(&1.name == "task_design_decline"))

      codes = ToolSurface.design_decline_error_codes()

      documented =
        codes
        |> Enum.filter(&(tool.limitations =~ "`#{&1}`"))
        |> MapSet.new()

      assert documented == MapSet.new(codes),
             """
             Every code the clause can emit must be named in `limitations`.
             Missing: #{inspect(MapSet.difference(MapSet.new(codes), documented))}
             """
    end
  end

  # ── THE guard of this stage: reachability, as a pair ──────────────────────

  describe "GUARD — reachable from a designer runtime holding only `task`" do
    setup do
      org = Tenancy.get_org_by_slug!("sxi")

      internal = World.create_user!()
      World.plain_member!(internal, org)

      %{internal_id: internal.id}
    end

    test "granted by the task bundle and by no other bundle", %{internal_id: internal_id} do
      designer = runtime(internal_id, ["task"])
      other = runtime(internal_id, ["canvas"])

      designer_names = ToolAuthorization.tool_names(designer)
      other_names = ToolAuthorization.tool_names(other)

      assert "task_design_decline" in designer_names
      assert :ok = ToolAuthorization.authorize("task_design_decline", designer)

      # PAIRED CONTROL. Without it the assertion above cannot distinguish
      # "in the task bundle" from "in every bundle" — and a tool leaked into
      # every bundle is a different bug wearing this one's passing test.
      refute "task_design_decline" in other_names

      assert {:error, :forbidden} =
               ToolAuthorization.authorize("task_design_decline", other)

      # The reachability claim the bundle choice rests on, asserted rather
      # than argued: the decline is grantable by exactly the grant that
      # already carries the designer's delivery path, so no `tool_profile`
      # row anywhere has to change for a dispatched designer to reach it.
      assert "task_attach_canvas" in designer_names
      refute "task_attach_canvas" in other_names
    end
  end

  # ── the closed refusal taxonomy ───────────────────────────────────────────

  describe "GUARD — every refusal carries a code from the closed set" do
    test "the observed code set is exactly the documented one", %{project: project} do
      open = task!(project, @ui_title, %{planning_step: "designing"})
      never_fired = task!(project, @ui_title)

      # A step that IS open, whose write cannot land: the pre-seeded
      # `"bogus"` key fails `Task.planning_step_changeset/2`'s step-key
      # validation when `record_planning_step/3` merges `"design"` into it,
      # so `decline/3` returns `{:error, %Ecto.Changeset{}}` from the writer.
      # This is the only branch of the taxonomy that is not an argument or a
      # state check, and it is reached for real rather than mocked.
      unwritable =
        task!(project, @ui_title, %{
          planning_step: "designing",
          planning_step_outcomes: %{"bogus" => %{"outcome" => "failed"}}
        })

      cases = [
        {:missing_task_id, %{"reason" => @reason}},
        {:missing_task_id, %{"task_id" => "   ", "reason" => @reason}},
        {:missing_task_id, %{"task_id" => 42, "reason" => @reason}},
        {:missing_reason, %{"task_id" => open.id}},
        {:missing_reason, %{"task_id" => open.id, "reason" => "   "}},
        {:missing_reason, %{"task_id" => open.id, "reason" => "short"}},
        {:task_not_found, %{"task_id" => Ecto.UUID.generate(), "reason" => @reason}},
        {:task_not_found, %{"task_id" => "not-a-uuid", "reason" => @reason}},
        {:step_not_open, %{"task_id" => never_fired.id, "reason" => @reason}},
        {:decline_failed, %{"task_id" => unwritable.id, "reason" => @reason}}
      ]

      observed =
        for {expected, args} <- cases, into: MapSet.new() do
          assert {:error, envelope} = decline(args),
                 "expected #{expected} for #{inspect(args)}, got a success"

          assert Map.has_key?(envelope, :code),
                 "refusal for #{inspect(args)} carries no `code`: #{inspect(envelope)}"

          assert envelope.code == expected, "for #{inspect(args)}: #{inspect(envelope)}"
          assert is_binary(envelope.error) and envelope.error != ""
          assert is_binary(envelope.suggestion) and envelope.suggestion != ""

          envelope.code
        end

      assert observed == MapSet.new(ToolSurface.design_decline_error_codes()),
             """
             The emitted taxonomy and the declared one disagree.
             Emitted-but-undeclared: #{inspect(MapSet.difference(observed, MapSet.new(ToolSurface.design_decline_error_codes())))}
             Declared-but-unexercised: #{inspect(MapSet.difference(MapSet.new(ToolSurface.design_decline_error_codes()), observed))}
             """

      # PAIRED CONTROL for the whole sweep: a clause that refused EVERYTHING
      # would satisfy every assertion above. The open step still declines.
      assert {:ok, %{outcome: "not_applicable"}} =
               decline(%{"task_id" => open.id, "reason" => @reason})
    end

    test "a refused call changes nothing about the step it names", %{project: project} do
      open = task!(project, @ui_title, %{planning_step: "designing"})

      assert {:error, %{code: :missing_reason}} = decline(%{"task_id" => open.id})

      assert design_entry(open) == nil
      assert cursor(open) == "designing"
    end

    test "step_not_open never overwrites a step that already settled", %{project: project} do
      settled = task!(project, @ui_title, %{planning_step: "designing"})

      quietly(fn -> PreplanStep.expire(settled, 1_800_000) end)
      quietly(fn -> PreplanStep.decline(settled, "already upgraded once") end)

      before = design_entry(settled)
      assert before["reason"] == PreplanStep.reasons().declined

      assert {:error, %{code: :step_not_open, recoverable: false}} =
               decline(%{"task_id" => settled.id, "reason" => @reason})

      assert design_entry(settled) == before
    end

    # The clause exists but the argument validator makes it unreachable
    # through `execute/3`; pinned here at its own level rather than faked.
    test "a non-binary note is a caller error, not a statement about the step" do
      assert {:error, :invalid_note} = PreplanStep.decline(Ecto.UUID.generate(), nil)
    end
  end

  # ── the happy path, through the tool ──────────────────────────────────────

  describe "GUARD — an open step closes through execute/3" do
    test "records not_applicable and the caller's identity, while a timeout on the same shape still records failed",
         %{project: project} do
      agent_id = Ecto.UUID.generate()
      task = task!(project, @ui_title, %{planning_step: "designing"})

      assert {:ok, result} =
               decline(%{"task_id" => task.id, "reason" => @reason}, %{agent_id: agent_id})

      assert result.task_id == task.id
      assert result.outcome == "not_applicable"
      assert result.reason == PreplanStep.reasons().declined
      assert result.declined_after_timeout == false

      # PIN THE POSITIVE FIRST — every refutation below passes trivially on a
      # task whose design step never ran.
      entry = design_entry(task)
      assert entry["outcome"] == "not_applicable"
      assert entry["reason"] == PreplanStep.reasons().declined
      assert entry["decline_note"] == @reason
      assert cursor(task) == "planning"

      # The audit trail matches what `task_attach_canvas` writes for a
      # delivered canvas: same `%{kind, id}` shape, same source (`context`).
      assert entry["declined_by"] == %{"kind" => "agent", "id" => agent_id}

      refute entry["outcome"] == "failed"
      refute Tasks.planning_gate_failed?(reload(task))
      assert Tasks.failed_planning_steps(reload(task)) == []

      # PAIRED DISTINGUISHABILITY CONTROL — same title, same open cursor;
      # only the closing path differs. Without it the block above cannot tell
      # "a decline records not_applicable" from "the design step stopped
      # recording failures at all".
      expired = task!(project, @ui_title, %{planning_step: "designing"})
      quietly(fn -> PreplanStep.expire(expired, 1_800_000) end)

      control = design_entry(expired)
      assert control["outcome"] == "failed"
      assert control["reason"] == PreplanStep.reasons().timeout
      assert Tasks.planning_gate_failed?(reload(expired))

      assert entry["outcome"] != control["outcome"]
      assert entry["reason"] != control["reason"]
    end

    test "an unidentifiable caller still closes the step, without a null attribution", %{
      project: project
    } do
      task = task!(project, @ui_title, %{planning_step: "designing"})

      assert {:ok, %{outcome: "not_applicable"}} =
               decline(%{"task_id" => task.id, "reason" => @reason}, %{})

      entry = design_entry(task)

      # Attribution is omitted, not written as nil: a decline is a STEP CLOSE
      # first. Refusing it over a missing audit field would park the planner
      # for the full deadline over metadata.
      assert entry["reason"] == PreplanStep.reasons().declined
      refute Map.has_key?(entry, "declined_by")

      # PAIRED CONTROL: the key is writable at all, so its absence above is a
      # property of the empty context and not of a dropped `Map.put`.
      identified = task!(project, @ui_title, %{planning_step: "designing"})
      user_id = Ecto.UUID.generate()

      assert {:ok, _} =
               decline(%{"task_id" => identified.id, "reason" => @reason}, %{user_id: user_id})

      assert design_entry(identified)["declined_by"] == %{"kind" => "user", "id" => user_id}
    end

    test "a decline that arrives after the deadline upgrades the record and says so", %{
      project: project
    } do
      task = task!(project, @ui_title, %{planning_step: "designing"})
      quietly(fn -> PreplanStep.expire(task, 1_800_000) end)

      # Both sides of the upgrade are asserted: it IS a failure before.
      assert design_entry(task)["outcome"] == "failed"
      assert [%{step: "design"}] = Tasks.failed_planning_steps(reload(task))

      assert {:ok, result} = decline(%{"task_id" => task.id, "reason" => @reason})

      assert result.outcome == "not_applicable"
      assert result.declined_after_timeout == true

      entry = design_entry(task)
      assert entry["outcome"] == "not_applicable"
      assert entry["declined_after_timeout"] == true

      # …and the merge-time warning clears, which is what the upgrade is for.
      assert Tasks.failed_planning_steps(reload(task)) == []
    end
  end
end
