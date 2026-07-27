defmodule Platform.Tasks.ArchitectureVerdictSourceVocabularyTest do
  @moduledoc """
  ADR-0046 member 5 — the anti-drift guard for
  `architecture_verdict["source"]`.

  ## The defect this exists because of

  Stage 1's `Plan` moduledoc documented the vocabulary inline as
  `"mcp" | "handle_output" | "deadline" | "human" | nil`. Stage 3's
  writer emitted `"architect"`, `"dispatch"`, `"deadline"` and `"human"`.
  Two of the documented values were unreachable and two of the emitted
  ones were undocumented — inside ONE stack, in the same fortnight, with
  nothing that could notice. The MCP-vs-`handle_output` distinction, the
  single thing the field exists to carry, was never expressible.

  Stage 4 had already built the right shape one file over: the tool's
  `limitations` prose is compared against
  `ToolSurface.architecture_verdict_error_codes/0` rather than restated.
  This file is that construction applied to `source`.

  ## What makes it a guard rather than a restatement

  The documented side is `Plan.architecture_verdict_sources/0`, which the
  moduledoc now CITES instead of spelling out (the third test below pins
  that, because inlining is what drifted). The emitted side is not a
  list — it is COLLECTED BY RUNNING every writer: both channels driven
  end to end, and every terminal resolution driven through
  `resolve_architecture_gate/3` with no `:source`, with the resolution
  list derived from `Plan.architecture_gate_states/0` so a seventh state
  cannot be added without deciding its source.

  Set equality between the two is failing in both directions by
  construction: a writer value nobody documented is an extra on the left,
  a documented value nothing emits is an extra on the right.

  ## VACUITY CONTROLS, MEASURED (both directions detonated)

    * ADD-TO-WRITER: changed
      `Tasks.architecture_verdict_source(:expired)` to `"timer"`. The
      changeset now refuses an undocumented source, so the write fails
      first — the guard failed on the `{:ok, resolved}` match with
      `has invalid source "timer"`, naming both the offending value and
      the allowed set. Detected.
    * ADD-TO-DOCS: appended `"architect"` to
      `Plan.architecture_verdict_sources/0` with no writer change. The
      guard failed on set equality, reporting
      `documented but unreachable: ["architect"]`. Detected.
    * RE-INLINE: replaced the moduledoc's accessor citation with the old
      literal list. The third test failed. Detected.

  Verbatim output for all three is in the stage-6 fix note.

  Not `async: true`: `resolve_architecture_gate/3` settles through
  `maybe_auto_approve/1`, which broadcasts on `tasks:board` and wakes the
  singleton `TaskRouterWatcher` (`019fa003-091a`).
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Federation.ToolSurface
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.ArchitectureReviewPlan
  alias Platform.Responsibilities.Responsibility
  alias Platform.Tasks
  alias Platform.Tasks.Plan

  defp u, do: System.unique_integer([:positive])

  setup do
    {:ok, project} = Tasks.create_project(%{name: "Verdict Source Project #{u()}"})
    %{project: project}
  end

  # A plan parked exactly where the gated submit leaves it: `pending_review`,
  # gate open, cursor at `:architecting`.
  defp gated_fixture(project, opts \\ []) do
    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Verdict source fixture #{u()}",
        status: "planning",
        auto_approve_plan: Keyword.get(opts, :auto_approve_plan, false),
        phase_assignees: %{
          "execution" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"},
          "review" => %{"assignee_id" => Ecto.UUID.generate(), "assignee_type" => "agent"}
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "S1"})
    {:ok, submitted} = plan |> Plan.changeset(%{status: "pending_review"}) |> Repo.update()
    {:ok, gated} = Tasks.open_architecture_gate(submitted, "moore")
    {:ok, _task} = Tasks.set_planning_step(task.id, :architecting)

    {task, gated, stage}
  end

  defp stored_source(%Plan{id: id}), do: stored_source(id)

  defp stored_source(plan_id) when is_binary(plan_id) do
    (Repo.get!(Plan, plan_id).architecture_verdict || %{}) |> Map.get("source")
  end

  defp user_fixture do
    n = u()

    Repo.insert!(%Platform.Accounts.User{
      name: "Overrider #{n}",
      email: "overrider-#{n}@example.com",
      oidc_sub: "verdict-source-sub-#{n}"
    })
  end

  defp verdict_errors(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Map.get(:architecture_verdict, [])
  end

  defp responsibility do
    %Responsibility{
      id: Ecto.UUID.generate(),
      key: ArchitectureReviewPlan.key(),
      feature: "architecture",
      trigger_kind: "event_topic",
      trigger_config: %{"topic" => "plan:submitted"},
      scope: "per_project",
      context_provided: ["plan_payload"],
      enabled: true
    }
  end

  # ── the five terminal resolutions, derived not copied ─────────────────
  #
  # Keyed off `Plan.architecture_gate_states/0` so that adding a seventh
  # terminal state without deciding what channel it reports raises HERE,
  # by name, instead of quietly escaping the collection below.
  @resolution_for_state %{
    "passed" => :pass,
    "rejected" => :reject,
    "expired" => :expired,
    "dispatch_failed" => :dispatch_failed,
    "human_override" => :human_override
  }

  defp terminal_resolutions do
    (Plan.architecture_gate_states() -- ["pending"])
    |> Enum.map(fn state ->
      Map.get(@resolution_for_state, state) ||
        flunk("""
        `#{state}` is a terminal architecture-gate state with no entry in
        @resolution_for_state, so this guard cannot collect the `source`
        its writer emits. Add the mapping and decide the channel.
        """)
    end)
  end

  # ── COLLECTORS: one per writer, each returns what actually landed ─────

  # Default per resolution, no `:source` opt — the shape `TaskRouter`'s
  # expiry sweep and `record_architecture_human_override/1` use.
  defp source_from_default(project, resolution) do
    {_task, gated, stage} = gated_fixture(project)

    opts =
      if resolution == :reject do
        [
          summary: "Boundary crossed.",
          findings: [
            %{
              "stage_id" => stage.id,
              "constraint" => "module_boundary",
              "detail" => "Move the query behind the context."
            }
          ]
        ]
      else
        []
      end

    capture_log([level: :info], fn ->
      assert {:ok, _resolved} = Tasks.resolve_architecture_gate(gated, resolution, opts)
    end)

    stored_source(gated)
  end

  # CHANNEL 1: the MCP tool a native architect calls.
  defp source_from_mcp_tool(project) do
    {_task, gated, _stage} = gated_fixture(project)

    assert {:ok, _} =
             ToolSurface.execute(
               "plan_architecture_verdict",
               %{
                 "plan_id" => gated.id,
                 "verdict" => "pass",
                 "summary" => "No new module, context, table or cross-context call."
               },
               %{}
             )

    stored_source(gated)
  end

  # CHANNEL 2: an external architect that can only answer in text.
  defp source_from_handle_output(project, output) do
    {task, gated, _stage} = gated_fixture(project)
    {:ok, _space} = ExecutionSpace.find_or_create(task.id)

    capture_log([level: :info], fn ->
      assert :ok =
               ArchitectureReviewPlan.handle_output(responsibility(), output, %{
                 task_id: task.id,
                 plan_id: gated.id
               })
    end)

    stored_source(gated)
  end

  # The human bypass, through the REAL entry point (`approve_plan/2`),
  # not through `resolve_architecture_gate/3` directly.
  defp source_from_human_override(project) do
    {_task, gated, _stage} = gated_fixture(project)
    user = user_fixture()

    assert {:ok, %Plan{status: "approved"}} = Tasks.approve_plan(gated, user.id)

    stored_source(gated)
  end

  # The level-triggered expiry PROJECTION — a reader-side writer of
  # `"source"` that never touches the row, and so would be missed by any
  # collection that only looked at persisted verdicts.
  defp source_from_expiry_projection(project) do
    {_task, gated, _stage} = gated_fixture(project)

    overdue =
      gated.architecture_verdict
      |> Map.put(
        "deadline_at",
        DateTime.utc_now() |> DateTime.add(-1, :second) |> DateTime.to_iso8601()
      )

    {:ok, _} =
      gated
      |> Plan.architecture_verdict_changeset(%{architecture_verdict: overdue})
      |> Repo.update()

    assert {:resolved, projected} = Tasks.architecture_gate(gated)
    Map.get(projected, "source")
  end

  # ── THE GUARD ─────────────────────────────────────────────────────────

  describe "GUARD: the documented `source` vocabulary is the emitted one" do
    test "every emitted source is documented, and every documented source is emitted", %{
      project: project
    } do
      defaults = Enum.map(terminal_resolutions(), &source_from_default(project, &1))

      emitted =
        MapSet.new(
          defaults ++
            [
              source_from_mcp_tool(project),
              source_from_handle_output(
                project,
                """
                Reviewed against the four constraints.

                ```json
                {"verdict": "pass", "summary": "Nothing crosses a boundary."}
                ```
                """
              ),
              # The unparseable branch is a SEPARATE writer of the same
              # channel — `dispatch_failed` with a named source is the
              # "replied, unreadable" case, and it must not smuggle in a
              # vocabulary of its own.
              source_from_handle_output(project, "Looks fine to me, no concerns."),
              source_from_human_override(project),
              source_from_expiry_projection(project)
            ]
        )

      channels = emitted |> Enum.reject(&is_nil/1) |> MapSet.new()
      documented = MapSet.new(Plan.architecture_verdict_sources())

      assert channels == documented,
             """
             `architecture_verdict["source"]` has drifted from its documentation.

             emitted but undocumented: #{inspect(MapSet.to_list(MapSet.difference(channels, documented)))}
             documented but unreachable: #{inspect(MapSet.to_list(MapSet.difference(documented, channels)))}

             Both are defects. An undocumented value is one a remote runtime
             will branch on wrongly; an unreachable one is a distinction the
             writers cannot actually make. Fix the writer or fix
             `Plan.architecture_verdict_sources/0` — do not fix the test.
             """

      # `nil` is documented as a value, not as a gap, so it has to be
      # reachable too: it is what "no channel answered" is written as.
      assert nil in emitted,
             "nil is documented as a `source` value but no writer emits it"

      # ANTI-VACUITY FLOOR. Set equality between two empty sets is a pass.
      # These two are the entire reason the field exists — MCP tool verdict
      # vs. external text-parse verdict — so if either stops being
      # reachable the guard above has stopped meaning anything.
      assert "mcp" in channels
      assert "handle_output" in channels
    end

    test "the unparseable external branch is `dispatch_failed` FROM a named channel", %{
      project: project
    } do
      # The distinction `source` buys over `state`, asserted directly: a
      # `dispatch_failed` that came back unreadable is not the same fact as
      # one where nothing came back. A writer that reverted to restating
      # the state (`"dispatch"`) or to `nil` here would collapse them.
      {task, gated, _stage} = gated_fixture(project)
      {:ok, _space} = ExecutionSpace.find_or_create(task.id)

      capture_log([level: :info], fn ->
        assert :ok =
                 ArchitectureReviewPlan.handle_output(responsibility(), "no json here", %{
                   task_id: task.id,
                   plan_id: gated.id
                 })
      end)

      verdict = Repo.get!(Plan, gated.id).architecture_verdict
      assert verdict["state"] == "dispatch_failed"
      assert verdict["source"] == "handle_output"

      # PAIRED CONTROL: the same state reached with no channel named stays
      # nil, so the assertion above is about the channel and not about
      # `dispatch_failed` being hardcoded somewhere.
      {_task2, gated2, _stage2} = gated_fixture(project)

      capture_log([level: :info], fn ->
        assert {:ok, _} = Tasks.resolve_architecture_gate(gated2, :dispatch_failed)
      end)

      assert Repo.get!(Plan, gated2.id).architecture_verdict["source"] == nil
    end

    test "the moduledoc cites the accessor instead of restating the values" do
      # Inlining IS the defect. `"state"` and `"constraint"` were written
      # as `one of \#{accessor}/0` and never drifted; `"source"` was
      # written as a literal union and drifted within one stack.
      moduledoc =
        case Code.fetch_docs(Plan) do
          {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) ->
            doc

          other ->
            flunk("""
            Could not read Plan's moduledoc to check it for inlined `source`
            literals (got #{inspect(other)}). This guard cannot silently pass.
            """)
        end

      # The verdict-shape block's own line, not the prose that discusses
      # it: `    "source"             => …`.
      [shape_line] =
        moduledoc
        |> String.split("\n")
        |> Enum.filter(&Regex.match?(~r/^\s+"source"\s+=>/, &1))

      assert shape_line =~ "architecture_verdict_sources/0",
             """
             `Plan`'s verdict-shape block must cite
             `architecture_verdict_sources/0` for "source", the way it already
             does for "state" and "constraint". Got:

               #{String.trim(shape_line)}

             A literal union here is what drifted from the writer last time,
             and nothing could tell, because the prose and the code had no
             shared artefact.
             """
    end
  end

  # ── the changeset refuses what the vocabulary does not contain ────────

  describe "GUARD: an undocumented source is refused at the schema boundary" do
    test "an unknown source is rejected; a documented one is accepted", %{project: project} do
      {_task, gated, _stage} = gated_fixture(project)

      # Absence half.
      assert {:error, changeset} =
               Tasks.record_architecture_verdict(gated, %{"state" => "passed"},
                 source: "architect"
               )

      assert Enum.any?(verdict_errors(changeset), &(&1 =~ "invalid source"))

      # The refusal is not a write: the gate is still open for the
      # positive control below, which is what proves the validator
      # discriminates rather than refusing everything.
      assert Tasks.architecture_gate_open?(gated)

      # Presence half.
      assert {:ok, resolved} =
               Tasks.record_architecture_verdict(gated, %{"state" => "passed"}, source: "mcp")

      assert resolved.architecture_verdict["source"] == "mcp"
    end
  end
end
