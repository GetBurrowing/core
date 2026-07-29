defmodule Platform.Orchestration.PromptTemplatesTest do
  @moduledoc """
  Asserts that the seeded prompt templates carry the e2e_behavior + manual_approval
  guidance that downstream stages (planner output, dispatch routing) depend on.
  """
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Orchestration.ContextAssembler
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments

  # Migrations are not on the compiled path, so the stage-6 template
  # migration has to be loaded before its `up/0` can be driven directly.
  # Mirrors `test/platform/data_migrations/*_test.exs`.
  @intent_classify_corrections_migration Path.join([
                                           __ENV__.file
                                           |> Path.dirname()
                                           |> Path.dirname()
                                           |> Path.dirname()
                                           |> Path.dirname(),
                                           "priv/repo/migrations/20260726000100_update_intent_classify_prompt_with_corrections.exs"
                                         ])

  setup_all do
    Code.require_file(@intent_classify_corrections_migration)
    :ok
  end

  describe "default_content_for_slug/1 — dispatch.planning" do
    test "instructs the planner to emit 2-5 adversarial e2e_behavior validations per task" do
      # v2: validations are pluralised (the planner-authored adversarial test
      # plan, user-approved at plan time). The "exactly one" wording is gone.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")
      assert is_binary(content)

      assert content =~ "e2e_behavior"
      assert content =~ "2-5"
      assert content =~ "adversarial"
      assert content =~ "evaluation_payload"
      refute content =~ "exactly one e2e_behavior"
    end

    test "documents the three required payload keys (no failure_feedback in v2)" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      for key <- ~w(setup actions expected) do
        assert content =~ key, "expected dispatch.planning to mention #{key}"
      end

      # v2: failure_feedback is no longer planner-supplied. The template must
      # explicitly forbid pre-writing it.
      refute content =~ "\"failure_feedback\":"
    end

    test "scopes manual_approval to UI-touching stages with file-path tokens" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "manual_approval"

      assert content =~ ".heex"
      assert content =~ "assets/js/"
      assert content =~ "tasks_live.ex"
    end

    test "forbids code_review and forbids pre-writing failure_feedback" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "code_review"
      assert content =~ "Forbidden"
      assert content =~ "Pre-writing"
      assert content =~ "failure_feedback"
    end

    test "includes two side-by-side adversarial e2e_behavior payload examples" do
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      # Two worked cases (Case A happy path, Case B edge case) replace v1's
      # single example.
      assert content =~ "Case A"
      assert content =~ "Case B"
      assert content =~ "\"kind\": \"e2e_behavior\""
      assert content =~ "\"setup\":"
      # v2: the worked examples MUST NOT include a failure_feedback field.
      refute content =~ "\"failure_feedback\":"
    end

    test "carries the previous_rejection_reason placeholder for the reopen-with-feedback flow" do
      # Task 019dfad1 stage 3: a re-dispatched planner (after a reopen-with-
      # feedback) needs to see what didn't work last time. The template
      # exposes a {{previous_rejection_reason}} placeholder pre-rendered by
      # the heartbeat scheduler — empty string when no qualifying plan
      # exists, otherwise the bounded "## Previous attempt — what didn't
      # work" section.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "{{previous_rejection_reason}}",
             "dispatch.planning must keep the previous_rejection_reason placeholder"

      # The hardcoded defaults declare the variable so prod's
      # PromptTemplate row carries the right schema after a fresh seed
      # (force-update migrations refresh content but not the variables
      # list — the next clean seed picks up the new list).
      defaults = PromptTemplates.default_templates()
      planning = Enum.find(defaults, &(&1.slug == "dispatch.planning"))

      assert planning, "dispatch.planning should appear in default_templates/0"

      assert "previous_rejection_reason" in planning.variables,
             "dispatch.planning variables list must include previous_rejection_reason"
    end

    test "scopes the planner to implementation + validation only — system auto-injects the deploy stage" do
      # Clear separation of concerns: planner plans, deployer deploys. The
      # planner must NOT author a deploy / open-PR / merge stage; the system
      # auto-injects it from the resolved deploy strategy when the task
      # transitions to `deploying` (see PlanEngine.maybe_inject_deploy_or_complete/2
      # and DeployStageBuilder.build_stage/2).
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      # Role-separation guidance the planner must read.
      assert content =~ "system auto-injects"
      assert content =~ "Deployer"
      assert content =~ "deploying"
      assert content =~ "Stage scope"

      # Explicit forbid-list: the template names the deploy-authoring phrases
      # the planner MUST NOT emit as stages. The phrases appear ONCE inside
      # that forbid list (a "Do NOT include …" sentence) and nowhere else.
      assert content =~ "Do NOT include a stage like"

      for phrase <- ["Deploy via PR merge", "Open PR", "Watch CI"] do
        occurrences = content |> String.split(phrase) |> length() |> Kernel.-(1)

        assert occurrences == 1,
               "expected #{inspect(phrase)} to appear exactly once (inside the forbid list); got #{occurrences}"
      end

      # The forbid list and the auto-inject explanation must occur together.
      assert content =~
               ~r/Do NOT include a stage like.*Deploy via PR merge.*Open PR.*Watch CI.*Merge/s
    end

    test "carries the Design involvement section — detection, brand already resolved, pre-plan canvas (tasks 019f4f1d → 019f9b29-5ecd)" do
      # RETARGETED, not loosened (task 019f9b29-5ecd stage 6, ADR-0046
      # member 7). The detection half is unchanged and still asserted: the
      # planner still has to recognise a UI/UX task, because that is what
      # decides whether the canvas matters. What ADR-0046 decision 1
      # reverses is the two items underneath it — brand resolution and the
      # planner-authored advisory stage both moved into the pre-plan design
      # step, so a planner still doing them does each job twice.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      # (a) Detection — kept verbatim from 019f4f1d.
      assert content =~ "Design involvement (UI/UX tasks)"
      assert content =~ "looks, feels, moves, or is interacted with"

      # (b) Brand is resolved upstream, in code, and the planner is told
      # not to redo it. `Platform.Design.Brand` is named so the reader can
      # find where the cascade went (stage 2 of this task).
      assert content =~ "Platform.Design.Brand"
      assert content =~ "you do not resolve it and you do not escalate"
      assert content =~ "do not add a stage that asks"

      # (c) The canvas the pre-plan step produces, and what to do when
      # there isn't one. `canvas_get` is the actionable half — see the
      # dispatch-context guard below for the proof it has an id to fetch.
      assert content =~ "Design runs BEFORE planning"
      assert content =~ "canvas_get"
      assert content =~ ~s(Do NOT author a "Design direction" stage)
      assert content =~ "not_applicable"
      assert content =~ "proceed and do not wait"

      # The superseded instructions are GONE, not merely unmentioned. Each
      # of these paired with a positive assertion above, so a truncated or
      # empty template fails the positives rather than passing the refutes.
      refute content =~ "Add an early advisory design stage",
             "the planner must no longer author its own design stage"

      refute content =~ "Route this stage to Saru automatically",
             "designer routing is the pre-plan dispatch's job, not a planned stage's"

      refute content =~ "Resolve brand context",
             "brand resolution moved into Platform.Design.Brand (stage 2)"
    end

    test "no longer teaches planners to set responsibility on any stage (tasks 019f5d47 → 019f9b29-5ecd)" do
      # RETARGETED. 019f5d47 stage 5 taught planners to set
      # responsibility: "designer" so TaskRouter.do_dispatch/2 could route
      # a planned stage to Saru. ADR-0046 makes the designer dispatch
      # happen BEFORE planning, so that field has nothing left to route and
      # member 9 is about to delete `Stage.responsibility` outright. This
      # stage removes only the instruction to author it — landing that
      # first is what makes member 9's deletion safe, because no
      # newly-submitted plan will carry the field.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      # POSITIVE CONTROL, paired with the refutes below: the replacement
      # instruction is present. Without this pair, the refutes would pass
      # against an empty or truncated template.
      assert content =~ "canvas_get"
      assert content =~ "do NOT set `responsibility` on any stage"

      refute content =~ ~s(responsibility: "designer"),
             "the planner must not be told to emit the responsibility field"

      refute content =~ "Platform.Roles.agent_id_for_role/1",
             "role resolution for design happens before planning, not per-stage"

      refute content =~ "Do NOT hardcode an agent_id",
             "the whole agent-routing paragraph is gone, not just its field name"
    end

    test "items 3 and 4 of the Design involvement section survive byte-identical (task 019f9b29-5ecd stage 6)" do
      # The lifecycle move touches WHO resolves brand and WHO produces the
      # direction. It does not touch how implementation stages reference
      # tokens, nor the manual_approval screenshot gate. Asserting the
      # exact substrings keeps unrelated churn out of a migration a
      # reviewer has to diff against the live DB row.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~
               "3. **Reference the resolved brand identity in implementation stage descriptions** — name the semantic token slots the coder must use (primary/on-primary, accent, surface, muted, border, destructive), not raw hex and not \"match the brand\". If the project is in exploring mode, say so in the stage description instead."

      assert content =~
               "4. Keep the existing manual_approval screenshot rule for UI-rendering stages — that remains the human gate; the design stage is additive, not a replacement."
    end

    test "the live dispatch.planning row serves the retargeted section, not just the code default (task 019f9b29-5ecd stage 6)" do
      # `render_template/2` reads the DB row, never `do_default_templates/0`.
      # `seed_defaults/0` is INSERT-only, so editing the code default alone
      # changes the fallback and leaves every deployed planner reading the
      # old instruction — which is why this stage ships a force-update
      # migration.
      #
      # Both halves are load-bearing and neither is redundant:
      #   * the equality catches a `lib/` revert (the migrated row would
      #     then disagree with the reverted default),
      #   * the substring catches a migration that never ran (equality
      #     alone passes trivially when BOTH the code and the DB are stale).
      row = PromptTemplates.get_template_by_slug("dispatch.planning")
      assert row, "the dispatch.planning row must exist in a migrated test DB"

      assert row.content =~ "canvas_get",
             "the live row is stale — 20260726051347 has not run on this database"

      refute row.content =~ ~s(responsibility: "designer")

      assert row.content == PromptTemplates.default_content_for_slug("dispatch.planning"),
             "the live row and the shipped default have diverged"
    end

    test "a task with an attached design canvas gives the canvas_get instruction an id to fetch (task 019f9b29-5ecd stage 6)" do
      # The prompt tells the planner to read the design canvas with
      # `canvas_get`. That is only actionable if the dispatch context the
      # planner receives carries the canvas id — no new template variable
      # was added, so `ContextAssembler`'s `:canvases` list is the whole
      # supply. Assert the pair: the instruction, and the id it needs.
      #
      # NOTE: the `:canvases`-is-populated half alone is already covered by
      # `ContextAssemblerTest` "surfaces an attached canvas in :canvases
      # with flat fields" and passes independently of this stage. The
      # joint assertion is the new claim.
      {:ok, project} =
        Tasks.create_project(%{
          name: "Design Preplan Project",
          repo_url: "https://github.com/test/design-preplan",
          tech_stack: %{"language" => "elixir"}
        })

      {:ok, task} =
        Tasks.create_task(%{
          project_id: project.id,
          title: "Restyle the task cards",
          description: "Make the card grid readable at 375px",
          priority: "high"
        })

      {:ok, space} =
        Chat.create_space(%{
          name: "Design Preplan Space",
          slug: "design-preplan-#{System.unique_integer([:positive])}",
          kind: "channel"
        })

      {:ok, participant} =
        Chat.add_participant(space.id, %{
          participant_type: "agent",
          participant_id: Ecto.UUID.generate(),
          display_name: "Designer",
          joined_at: DateTime.utc_now()
        })

      {:ok, canvas} =
        Chat.create_canvas(%{
          "space_id" => space.id,
          "created_by" => participant.id,
          "title" => "Design direction — task cards"
        })

      {:ok, _} =
        CanvasAttachments.attach_canvas(:system, task.id, canvas.id,
          note: "pre-plan design direction",
          attached_by: %{kind: "agent", id: participant.id}
        )

      context = ContextAssembler.build(task.id)

      assert Enum.any?(context.canvases, &(&1.id == canvas.id)),
             "the planner's dispatch context must carry the attached design canvas id"

      assert PromptTemplates.default_content_for_slug("dispatch.planning") =~ "canvas_get",
             "the id is only useful if the prompt still tells the planner to fetch it"
    end
  end

  describe "default_content_for_slug/1 — dispatch.in_review" do
    test "no longer mentions e2e behavioral validation (handled by dispatch.review_e2e)" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")
      assert is_binary(content)

      refute content =~ "e2e_behavior",
             "dispatch.in_review should not mention e2e_behavior — that's dispatch.review_e2e's job"
    end

    test "still covers the manual_approval / UI-judgment review path" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")

      assert content =~ "manual_approval"
      assert content =~ "review_request_create" or content =~ "suite_review_request_create"
    end

    test "evidence-capture step routes through hive-local CDP via federation preamble" do
      # After task 019f5e2a stage 3, the evidence-workflow copy is folded
      # into `federation_preamble` rather than a standalone
      # {{evidence_workflow_reference}} placeholder. dispatch.in_review must
      # keep the `{{federation_preamble}}` placeholder so the capture step
      # reaches the agent.
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")

      assert content =~ "{{federation_preamble}}",
             "dispatch.in_review must keep the federation_preamble placeholder (Stage 3 retrofit)"
    end

    test "routes UI tasks through Saru's advisory design review before the human gate (task 019f4f1d)" do
      # First applied live via prompt_template_update on 2026-07-11 and
      # upstreamed here so force-update migrations preserve it. Saru's review
      # is advisory evidence bundled into the human review request — it must
      # never replace human approval nor block the review request.
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")

      assert content =~ "Design review (Saru)"
      assert content =~ "BEFORE creating the human review request"
      assert content =~ "never replaces human approval"
      assert content =~ "create the review request anyway"
    end
  end

  describe "default_content_for_slug/1 — dispatch.in_progress" do
    test "carries the federation_preamble placeholder for the CDP capture step" do
      # After task 019f5e2a stage 3, the CDP evidence-capture instructions
      # ship via `{{federation_preamble}}` rather than a standalone
      # {{evidence_workflow_reference}} placeholder.
      content = PromptTemplates.default_content_for_slug("dispatch.in_progress")
      assert is_binary(content)

      assert content =~ "{{federation_preamble}}",
             "dispatch.in_progress must keep the federation_preamble placeholder (Stage 3 retrofit)"
    end

    test "uses a single pre-rendered {{git_workflow_block}} variable, not piecewise task_slug" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_progress")

      # The Git Workflow section is now pre-rendered at the assigns layer
      # (HeartbeatScheduler.git_workflow_section/1) so the DB template and the
      # hardcoded enrichment path share one source of truth.
      assert content =~ "{{git_workflow_block}}"
      refute content =~ "{{task_slug}}"
      refute content =~ "git worktree add ../worktrees/{{task_slug}}"
    end

    test "the variables list registers git_workflow_block and drops task_slug" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.in_progress"))

      assert descriptor
      assert "git_workflow_block" in descriptor.variables
      refute "task_slug" in descriptor.variables
    end

    test "render_template interpolates a pre-rendered non-stack git workflow block verbatim" do
      :ok = PromptTemplates.seed_defaults()

      git_block = """

      ## Git Workflow (CRITICAL)
      Repository: https://github.com/test/router
      Base branch: main

      1. Create a worktree from the latest main branch:
         ```
         git fetch origin
         git worktree add ../worktrees/019e2474 -b task/019e2474 origin/main
         cd ../worktrees/019e2474
         ```
      """

      assigns = %{
        task_title: "Ordinary task",
        stage_info: "Plan: v1 (stage 1/1 — coding)",
        git_workflow_block: git_block,
        provider_specific_guidance: "",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.in_progress", assigns)

      assert rendered =~ "Ordinary task"
      assert rendered =~ "git worktree add ../worktrees/019e2474 -b task/019e2474 origin/main"
      refute rendered =~ "Task Stack Membership"
      refute rendered =~ "{{task_slug}}"
    end

    test "render_template interpolates a pre-rendered stack-member git workflow block" do
      :ok = PromptTemplates.seed_defaults()

      git_block = """

      ## Git Workflow (CRITICAL)
      Repository: https://github.com/test/router
      Base branch: main

      1. Create a worktree from the latest main branch:
         ```
         git fetch origin
         git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001 origin/main
         cd ../worktrees/019e2474-11c1-7000-8000-000000000001
         ```

      ## Task Stack Membership
      This task is a stack member (part of task stack `019e2782-09d6-7e2c-9502-c106290e5add`).
      - stack_id: `019e2782-09d6-7e2c-9502-c106290e5add`
      - Rollup branch: `stack/meeting-module`
      """

      assigns = %{
        task_title: "Stack member task",
        stage_info: "Plan: v1 (stage 1/1 — coding)",
        git_workflow_block: git_block,
        provider_specific_guidance: "",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.in_progress", assigns)

      assert rendered =~
               "git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001"

      assert rendered =~ "## Task Stack Membership"
      assert rendered =~ "stack_id: `019e2782-09d6-7e2c-9502-c106290e5add`"
    end

    # Task 019f7b7e stage 3 — the stage-2 reservation is inert unless the
    # dispatch template actually renders it.
    test "carries the {{migration_slot_section}} placeholder before the git workflow block" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_progress")

      assert content =~ "{{migration_slot_section}}"

      slot_at = :binary.match(content, "{{migration_slot_section}}") |> elem(0)
      git_at = :binary.match(content, "{{git_workflow_block}}") |> elem(0)

      assert slot_at < git_at,
             "the reserved migration timestamp must appear before the branch/commit instructions"
    end

    test "the variables list registers migration_slot_section" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.in_progress"))

      assert descriptor
      assert "migration_slot_section" in descriptor.variables
    end

    test "render_template interpolates a pre-rendered migration slot section" do
      :ok = PromptTemplates.seed_defaults()

      slot_section = """

      ## Reserved migration timestamp

      `20260719120100`
      """

      assigns = %{
        task_title: "Stack member task",
        stage_info: "Plan: v1 (stage 3/5 — coding)",
        migration_slot_section: slot_section,
        git_workflow_block: "\n## Git Workflow (CRITICAL)\n",
        provider_specific_guidance: "",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.in_progress", assigns)

      assert rendered =~ "## Reserved migration timestamp"
      assert rendered =~ "`20260719120100`"
      refute rendered =~ "{{migration_slot_section}}"
    end

    test "an absent migration_slot_section assign renders empty, not a literal placeholder" do
      # Backwards compatibility: solo tasks and stack members without a
      # reservation must see a prompt with no leftover mustache tag.
      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        task_title: "Ordinary task",
        stage_info: "Plan: v1 (stage 1/1 — coding)",
        git_workflow_block: "\n## Git Workflow (CRITICAL)\n",
        provider_specific_guidance: "",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.in_progress", assigns)

      refute rendered =~ "{{migration_slot_section}}"
      refute rendered =~ "## Reserved migration timestamp"
    end
  end

  describe "default_content_for_slug/1 — dispatch.review_e2e" do
    test "exists as a seeded template slug" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      assert is_binary(content),
             "dispatch.review_e2e must be registered in default_templates/0"
    end

    test "references the three evaluation_payload fields (no failure_feedback in v2) and pending list" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      for token <- ~w(setup actions expected validation_id) do
        assert content =~ token, "expected dispatch.review_e2e to mention #{token}"
      end

      # v2: failure_feedback is composed by the review agent at observation
      # time from what was expected vs what was seen — it's no longer a
      # planner-supplied payload field. The template must NOT instruct the
      # agent to expect it in the payload.
      refute content =~ "failure_feedback from the payload"
      refute content =~ "verbatim failure_feedback"
    end

    test "handles multiple pending e2e validations and instructs per-validation disposition" do
      # v2: the dispatcher renders ALL pending e2e_behavior validations into a
      # JSON array under pending_e2e_validations_json; the template walks them
      # individually.
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      assert content =~ "pending_e2e_validations_json"
      assert content =~ "Run each one"

      assert content =~ "post your own observation" or
               content =~ "Post that same observation"

      assert content =~ "Do NOT skip validations"
    end

    test "instructs the agent to disposition via validation_evaluate (passed/failed)" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      assert content =~ "validation_evaluate"
      assert content =~ "passed"
      assert content =~ "failed"
    end

    test "forbids self-bouncing the task status" do
      content = PromptTemplates.default_content_for_slug("dispatch.review_e2e")

      # Plan engine handles the in_review→in_progress transition on a failed
      # e2e_behavior verdict; the agent must not call task_update for it.
      assert content =~ "task_update" or content =~ "self-bounce" or
               content =~ "do not transition" or content =~ "Do NOT"
    end

    test "renders pending validations payload when supplied via assigns" do
      assigns = %{
        task_title: "Render dependency badges",
        pending_e2e_validations_json:
          ~s([{"validation_id":"00000000-0000-0000-0000-deadbeefcafe","evaluation_payload":{"setup":"create A and B","actions":"complete A","expected":"badge clears"}}]),
        execution_space_id: "11111111-1111-1111-1111-111111111111",
        repo_url: "git@github.com:acme/widgets.git",
        task_slug: "deadbeef",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      # Seed the template into the test DB so render_template can find it.
      :ok = PromptTemplates.seed_defaults()
      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.review_e2e", assigns)

      assert rendered =~ "Render dependency badges"
      assert rendered =~ "00000000-0000-0000-0000-deadbeefcafe"
      assert rendered =~ "create A and B"
      assert rendered =~ "11111111-1111-1111-1111-111111111111"
      assert rendered =~ "git@github.com:acme/widgets.git"
      assert rendered =~ "deadbeef"
    end
  end

  describe "default_content_for_slug/1 — dispatch.triage_dispatch" do
    # Task 019f5e2b (meeting-to-tasks pipeline stack member M4) Stage 2
    # ships the real triage-officer runtime body. These guards lock the
    # body's declared surface — placeholders wired, downstream module
    # references named, sibling helpers cited so a future edit that
    # drops one of these tokens is caught before the runtime silently
    # loses a step. Stage 4 owns these assertions; Stages 1–3 shipped
    # the code.

    test "exists as a seeded template slug" do
      content = PromptTemplates.default_content_for_slug("dispatch.triage_dispatch")

      assert is_binary(content),
             "dispatch.triage_dispatch must be registered in default_templates/0"
    end

    test "wires the shared federation_preamble + skills_reference placeholders" do
      content = PromptTemplates.default_content_for_slug("dispatch.triage_dispatch")

      # M1 helper — pulled in as a mustache placeholder so the shared
      # federation preamble stays in one place.
      assert content =~ "{{federation_preamble}}",
             "triage_dispatch must open with the M1 federation_preamble placeholder"

      # Every dispatch template ends with the skills-reference block so
      # the discovery instruction stays uniform across dispatch kinds.
      assert content =~ "{{skills_reference}}",
             "triage_dispatch must close with the shared skills_reference placeholder"
    end

    test "names the downstream Triage surface + skill slug + canvas API" do
      content = PromptTemplates.default_content_for_slug("dispatch.triage_dispatch")

      # Stack member E's filing surface — the template must direct the
      # runtime here rather than reimplementing the filing/dedup loop.
      assert content =~ "Triage.file_tasks_from_canvas",
             "triage_dispatch must hand items to E's file_tasks_from_canvas/2 surface"

      # The skill slug the runtime pulls for parse/matching conventions.
      assert content =~ "meeting-triage-officer",
             "triage_dispatch must call out the meeting-triage-officer skill by slug"

      # The canvas-loading API the runtime uses at step (a).
      assert content =~ "canvas_get",
             "triage_dispatch must direct the runtime to canvas_get for the source canvas"

      # The canonical scribe-completion node kind the runtime iterates.
      assert content =~ "checklist_item",
             "triage_dispatch must reference the checklist_item children it walks"
    end

    test "delegates dedup to Tasks.similar_open_titles/3 (idempotency clause)" do
      content = PromptTemplates.default_content_for_slug("dispatch.triage_dispatch")

      # E's dedup surface — the runtime must NOT re-implement dedup;
      # the template's idempotency clause explicitly says so.
      assert content =~ "similar_open_titles",
             "triage_dispatch must delegate dedup to Tasks.similar_open_titles/3 (E's surface)"
    end

    test "emits both triage_dispatch entry + tasks_created_from_meeting completion telemetry" do
      content = PromptTemplates.default_content_for_slug("dispatch.triage_dispatch")

      # Entry-side telemetry ref — the [:platform, :meetings, :triage_dispatch]
      # event name is quoted in the template so `Platform.Meetings.TelemetryHandler`
      # (from stack member E) can attach without a separate handler wired here.
      assert content =~ "triage_dispatch",
             "triage_dispatch must reference the entry telemetry event name"

      # Completion-side telemetry ref — the `tasks_created_from_meeting`
      # event with measurements %{filed_count, skipped_count, fallback_project_count}.
      assert content =~ "tasks_created_from_meeting",
             "triage_dispatch must reference the tasks_created_from_meeting completion telemetry event"
    end

    test "declares all seven variables in the descriptor" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.triage_dispatch"))

      assert descriptor,
             "dispatch.triage_dispatch descriptor must be registered in default_templates/0"

      # Locked against the plan's declared surface — reorderings + accidental
      # drops both fail this. Matching Enum.sort/1 on both sides so the
      # test isn't order-sensitive but IS content-sensitive.
      expected_vars =
        Enum.sort([
          "federation_preamble",
          "space_id",
          "room_id",
          "transcript_id",
          "canvas_id",
          "execution_space_id",
          "skills_reference"
        ])

      assert Enum.sort(descriptor.variables) == expected_vars,
             "dispatch.triage_dispatch must declare exactly the seven planned variables"
    end
  end

  describe "default_content_for_slug/1 — dispatch.intent_attention" do
    # Task 019f70b8 stage 5. The prompt a per-meeting intent queue's target
    # runtime receives. Two things in this body are load-bearing beyond
    # prose quality:
    #
    #   * AC15's ack preamble is asserted CHARACTER-FOR-CHARACTER. It is the
    #     mechanism that makes "acked but never spawned" structurally
    #     impossible for intents the way it already is for tasks, and a
    #     helpful paraphrase would quietly relax it.
    #   * The `## Cancellation` wire shape. Stage 4 shipped the cancel as
    #     `Endpoint.broadcast(topic, "intent_cancelled", %{...})` — a named
    #     channel event with a MAP payload — because `runtime:<runtime_id>`
    #     is a Phoenix Channel topic whose subscribers serialise to a
    #     websocket and a bare Elixir tuple cannot cross it. The task
    #     description still writes the tuple form. A runtime told to expect
    #     `{:intent_cancelled, ...}` waits for a message that never arrives
    #     and every cancel silently becomes a timeout, so the tuple form is
    #     asserted ABSENT here, not merely unmentioned.

    # AC15, verbatim. The trailing newline is part of the match: in the
    # template body the second line is followed by a blank line, so the
    # heredoc's own "\n" is present in the content too.
    @intent_ack_preamble """
    **Your first tool call after spawning the subagent must be `intent_ack(intent_id="<...>", subagent_id="<the id returned when you spawned the subagent>", status: :working)`.**
    Spawn the subagent FIRST, then include its returned agent id in the ack. Empty or missing subagent_id will fail validation.
    """

    test "exists as a registered default template slug" do
      content = PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      assert is_binary(content),
             "dispatch.intent_attention must be registered in default_templates/0"
    end

    test "carries AC15's spawn-before-ack preamble character-for-character" do
      content = PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      assert String.contains?(content, @intent_ack_preamble),
             """
             dispatch.intent_attention must carry AC15's ack preamble VERBATIM.

             Expected to find:
             #{@intent_ack_preamble}
             """
    end

    test "expresses the subagent_id provenance split once, in prose" do
      content = PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      # `IntentRuntimeAdapter` deliberately does NOT branch on runtime type
      # — one payload shape for every runtime. The Claude-Code-vs-openclaw
      # difference is expressed HERE and nowhere else, so if this prose
      # disappears the distinction has no home in the codebase at all.
      assert content =~ "agentId",
             "intent_attention must name the Claude Code Agent-tool agentId as one subagent_id source"

      assert content =~ "afd767f1e0cc81633",
             "intent_attention must show a concrete Claude Code agentId example"

      assert content =~ "higgins.moon",
             "intent_attention must show a concrete openclaw runtime-slug example"
    end

    test "documents all four intent_ack statuses and the queue-advance split" do
      content = PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      for status <- ~w(working completed rejected cancel_honored) do
        assert content =~ status,
               "intent_attention must name the `#{status}` ack status"
      end

      # `working` is the ONLY status that does not advance the serial
      # cursor. A runtime that thinks `working` advances will sit on the
      # intent and starve the rest of the meeting's queue.
      assert content =~ "Does NOT advance the queue",
             "intent_attention must say that `working` does not advance the queue"

      # The stage-1 status semantics: `timed_out` (amber, we heard nothing)
      # stays distinct from `no_ack_spawn_failed` (red, the runtime tried
      # and could not spawn). The template is where the runtime learns not
      # to fabricate an id and collapse the two.
      assert content =~ "no_ack_spawn_failed",
             "intent_attention must name the no_ack_spawn_failed outcome"

      assert content =~ "timed_out",
             "intent_attention must name the timed_out outcome distinctly"
    end

    test "cancellation documents the shipped map payload, not the plan's tuple" do
      content = PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      assert content =~ "## Cancellation"

      # Assertions below are scoped to the `## Cancellation` SLICE, not to
      # the whole body. Every one of these tokens also occurs in the ack
      # contract, so a whole-body `=~` would stay green while the
      # cancellation section itself lost the key that names which subagent
      # to stop — which is the single most load-bearing field on the wire.
      section = intent_attention_section(content, "## Cancellation", "## Failure surfacing")

      # The event NAME as broadcast by
      # `IntentRuntimeAdapter.cancel_event/0`.
      assert section =~ "intent_cancelled",
             "the cancellation section must name the intent_cancelled channel event"

      # Every key `IntentRuntimeAdapter.cancel_payload/4` actually puts on
      # the wire.
      for key <-
            ~w(intent_id meeting_id subagent_id reason corrected_intent corrected_target_agent_id status) do
        assert section =~ key,
               "the cancellation section must document the `#{key}` payload key"
      end

      # Regression guard against re-adopting the task description's tuple
      # notation. See this describe block's header comment.
      refute content =~ "{:intent_cancelled",
             "intent_attention must NOT describe the cancel as an Elixir tuple — " <>
               "stage 4 ships it as a channel event with a map payload"

      # The termination contract, which is the difference between a clean
      # stop and a half-written file.
      assert section =~ "next tool-call boundary",
             "the cancellation section must require termination at the next tool-call boundary"

      assert section =~ "force-abort",
             "the cancellation section must forbid force-aborting mid-tool-call"

      assert section =~ "cancelled_late",
             "the cancellation section must say an already-completed cancel lands cancelled_late"

      # The reply that actually releases the row. Without a `subagent_id`
      # in this call the queue cannot honour the cancel at all.
      assert section =~ ~s(subagent_id="<the same id>"),
             "the cancellation section must show the cancel_honored ack carrying the same subagent_id"
    end

    # Slice the body between two section markers so a section-scoped
    # assertion can't be satisfied by a token that lives in a different
    # section.
    defp intent_attention_section(content, from_marker, to_marker) do
      {from, _} = :binary.match(content, from_marker)
      {to, _} = :binary.match(content, to_marker)

      assert to > from,
             "expected #{inspect(from_marker)} to precede #{inspect(to_marker)}"

      binary_part(content, from, to - from)
    end

    test "lays the sections out in the planned order" do
      content = PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      markers = [
        "{{federation_preamble}}",
        "## Signal context",
        "## Ack contract",
        "## Deliverable steps",
        "## Cancellation",
        "## Failure surfacing",
        "{{skills_reference}}"
      ]

      positions =
        Enum.map(markers, fn marker ->
          index = :binary.match(content, marker)

          assert index != :nomatch,
                 "dispatch.intent_attention must contain the `#{marker}` section marker"

          {marker, elem(index, 0)}
        end)

      sorted = positions |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

      assert sorted == markers,
             "dispatch.intent_attention sections are out of order: got #{inspect(sorted)}"
    end

    test "declares exactly the eight planned variables" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.intent_attention"))

      assert descriptor,
             "dispatch.intent_attention descriptor must be registered in default_templates/0"

      expected_vars =
        Enum.sort([
          "federation_preamble",
          "intent_id",
          "meeting_id",
          "transcript_chunk_excerpt",
          "classified_intent",
          "target_rationale",
          "execution_space_id",
          "skills_reference"
        ])

      assert Enum.sort(descriptor.variables) == expected_vars,
             "dispatch.intent_attention must declare exactly the eight planned variables"
    end

    test "every declared variable is actually interpolated into the body" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.intent_attention"))

      # A declared-but-unused variable is a lie the render path can't
      # catch: `interpolate/2` silently ignores assigns with no
      # placeholder, so the operator sees a variable in the editor that
      # changes nothing.
      for var <- descriptor.variables do
        assert descriptor.content =~ "{{#{var}}}",
               "dispatch.intent_attention declares `#{var}` but never interpolates it"
      end
    end

    test "render_template substitutes every declared variable and leaves no placeholder" do
      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        federation_preamble: "FEDERATION-PREAMBLE-FIXTURE",
        intent_id: "019f9b01-0000-7000-8000-00000000dead",
        meeting_id: "019f9b01-0000-7000-8000-00000000beef",
        transcript_chunk_excerpt: "make that button teal",
        classified_intent: "visual_adjust",
        target_rationale: "visual_adjust routes to the designer role",
        execution_space_id: "019f9afa-a6bd-7795-aa79-5372ef9585a1",
        skills_reference: "SKILLS-REFERENCE-FIXTURE"
      }

      assert {:ok, rendered} =
               PromptTemplates.render_template("dispatch.intent_attention", assigns)

      for {_key, value} <- assigns do
        assert rendered =~ value,
               "rendered intent_attention prompt is missing the interpolated value #{inspect(value)}"
      end

      refute rendered =~ "{{",
             "rendered intent_attention prompt still carries an un-substituted placeholder"

      # The ack preamble survives interpolation intact — it contains a
      # literal `"<...>"` that must NOT be mistaken for a placeholder.
      assert String.contains?(rendered, @intent_ack_preamble),
             "AC15's ack preamble must survive render_template unchanged"
    end
  end

  describe "default_content_for_slug/1 — stacks.dep_inference.v1" do
    test "registers the slug with the planner-spec'd variables list" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "stacks.dep_inference.v1"))

      assert descriptor,
             "stacks.dep_inference.v1 must appear in default_templates/0"

      for var <- ~w(stack_name stack_description members_json) do
        assert var in descriptor.variables,
               "stacks.dep_inference.v1 variables list must include #{var}"
      end
    end

    test "content carries the three interpolation placeholders and JSON-only contract" do
      content = PromptTemplates.default_content_for_slug("stacks.dep_inference.v1")
      assert is_binary(content)

      # Mustache placeholders the DepInference module will fill in.
      for placeholder <- ["{{stack_name}}", "{{stack_description}}", "{{members_json}}"] do
        assert content =~ placeholder,
               "expected stacks.dep_inference.v1 to carry #{placeholder}"
      end

      # Output-shape contract — the module's parser will Jason.decode this
      # and reach for the "edges" key. If the prompt stops naming that key,
      # the parser silently drops every edge and inference degrades to 0.
      assert content =~ ~s("edges")
      assert content =~ "from_task_id"
      assert content =~ "to_task_id"
      assert content =~ "reason"

      # The rules the parser depends on — the module strips self-edges and
      # orphan ids on its side, but the LLM shouldn't be emitting them in
      # the first place, so the prompt must forbid them explicitly.
      assert content =~ "self-edge" or content =~ "self_edge"

      assert content =~ "from_task_id is the member that WAITS" or
               content =~ "blocked by to_task_id"

      # Empty-edges convention — the parser treats `{"edges": []}` as a
      # legitimate "no dependencies inferable" response, not a failure.
      assert content =~ ~s({"edges": []})

      # JSON-only response contract — the adapter passes the raw body to
      # Jason.decode without stripping prose or fences.
      assert content =~ "JSON" or content =~ "json"
      assert content =~ "no prose" or content =~ "No prose"
    end

    test "render_template interpolates a fixture assigns map into all three placeholders" do
      :ok = PromptTemplates.seed_defaults()

      members_json =
        Jason.encode!([
          %{
            id: "00000000-0000-0000-0000-000000000001",
            title: "Add users table",
            description: "Create the users schema + migration."
          },
          %{
            id: "00000000-0000-0000-0000-000000000002",
            title: "Add auth context",
            description: "Register/login built on the users schema."
          }
        ])

      assigns = %{
        stack_name: "Auth foundation",
        stack_description: "Ship user accounts and session-based login.",
        members_json: members_json
      }

      assert {:ok, rendered} =
               PromptTemplates.render_template("stacks.dep_inference.v1", assigns)

      # Every placeholder is fully consumed.
      refute rendered =~ "{{stack_name}}"
      refute rendered =~ "{{stack_description}}"
      refute rendered =~ "{{members_json}}"

      # Interpolated values arrive intact.
      assert rendered =~ "Auth foundation"
      assert rendered =~ "Ship user accounts and session-based login."
      assert rendered =~ "00000000-0000-0000-0000-000000000001"
      assert rendered =~ "00000000-0000-0000-0000-000000000002"
      assert rendered =~ "Add users table"
      assert rendered =~ "Add auth context"
    end
  end

  describe "seed_defaults/0 + migration parity" do
    # Migration files live under `priv/repo/migrations/` and are not on the
    # compile path — walk four `dirname`s to climb from
    # `test/platform/orchestration/<this>.exs` up to the `apps/platform/`
    # app root, then descend into `priv/repo/migrations/`.
    @alarm_silence_migration_path Path.join([
                                    __ENV__.file
                                    |> Path.dirname()
                                    |> Path.dirname()
                                    |> Path.dirname()
                                    |> Path.dirname(),
                                    "priv/repo/migrations/20260715220000_refresh_dispatch_templates_alarm_silence_fallback.exs"
                                  ])

    @subagent_id_ack_migration_path Path.join([
                                      __ENV__.file
                                      |> Path.dirname()
                                      |> Path.dirname()
                                      |> Path.dirname()
                                      |> Path.dirname(),
                                      "priv/repo/migrations/20260716211312_refresh_dispatch_templates_subagent_id_ack.exs"
                                    ])

    @federation_preamble_migration_path Path.join([
                                          __ENV__.file
                                          |> Path.dirname()
                                          |> Path.dirname()
                                          |> Path.dirname()
                                          |> Path.dirname(),
                                          "priv/repo/migrations/20260717000000_retrofit_dispatch_templates_with_federation_preamble.exs"
                                        ])

    # Load the migration module once for this describe block so the tests
    # below can call `up/0` directly. `Code.compile_file/1` is idempotent —
    # subsequent test runs pick up any edits the developer made without a
    # stale binary lying around.
    @migration_slot_section_migration_path Path.join([
                                             __ENV__.file
                                             |> Path.dirname()
                                             |> Path.dirname()
                                             |> Path.dirname()
                                             |> Path.dirname(),
                                             "priv/repo/migrations/20260719120100_add_migration_slot_section_to_dispatch_in_progress.exs"
                                           ])

    # Task 019f70b8 stage 5. This one is a BOTH-HALVES migration — insert
    # when the slug is absent, force-update when it is present — because
    # the slug is new AND prod has already run the earlier seed
    # migrations. Insert-only would leave prod without the row;
    # force-update-only would no-op there. Both branches are exercised
    # below.
    @intent_attention_migration_path Path.join([
                                       __ENV__.file
                                       |> Path.dirname()
                                       |> Path.dirname()
                                       |> Path.dirname()
                                       |> Path.dirname(),
                                       "priv/repo/migrations/20260725120000_seed_and_force_update_intent_attention_template.exs"
                                     ])

    # Task 019f9b29-5ecd stage 6 (ADR-0046 member 7). Force-update only —
    # the slug has existed since the original seed, so the insert branch is
    # unreachable for it; the row it has to move is a deployed one.
    @design_preplan_migration_path Path.join([
                                     __ENV__.file
                                     |> Path.dirname()
                                     |> Path.dirname()
                                     |> Path.dirname()
                                     |> Path.dirname(),
                                     "priv/repo/migrations/20260726051347_force_update_dispatch_planning_design_preplan.exs"
                                   ])

    # Task 019fa504 stage 3 (ADR-0046 member 7). Force-update only, for the
    # same reason as the one above: `20260726051346_seed_design_task_direction`
    # claimed `design.task_direction.v1` on every migrated environment, so the
    # insert branch is dead for it and the row it has to move is a deployed
    # one. The two tests below are the pair that makes it load-bearing rather
    # than ceremony — the seed-only control, and the missing-row skip.
    @design_decline_migration_path Path.join([
                                     __ENV__.file
                                     |> Path.dirname()
                                     |> Path.dirname()
                                     |> Path.dirname()
                                     |> Path.dirname(),
                                     "priv/repo/migrations/20260727210000_force_update_design_task_direction_decline.exs"
                                   ])

    Code.compile_file(@alarm_silence_migration_path)
    Code.compile_file(@subagent_id_ack_migration_path)
    Code.compile_file(@federation_preamble_migration_path)
    Code.compile_file(@migration_slot_section_migration_path)
    Code.compile_file(@intent_attention_migration_path)
    Code.compile_file(@design_preplan_migration_path)
    Code.compile_file(@design_decline_migration_path)

    test "seed_defaults seeds dispatch.planning with current default content" do
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      assert template

      expected = PromptTemplates.default_content_for_slug("dispatch.planning")
      assert template.content == expected
    end

    # Task 019f9b29-5ecd stage 6. Until this stage the design-involvement
    # migrations had no behavioural coverage at all — 20260711010000 and
    # 20260713000010 appear only in the T4 allow-list, which asserts the
    # FILE exists, not that it moves a row. These three exercise the
    # branches: force-update, the insert-only control that proves the
    # migration is load-bearing, and the missing-row skip.
    @stale_design_markers """

    1. **Resolve brand context** before planning design-dependent stages, in this order:
       a. Project-level brand settings.
    2. **Add an early advisory design stage** — "Design direction (Saru)":
       - **Route this stage to Saru automatically**: set `responsibility: "designer"` on the stage payload. The engine resolves the current designer via `Platform.Roles.agent_id_for_role/1`.
    """

    defp stale_dispatch_planning_row do
      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      assert template, "precondition: the dispatch.planning row exists"

      stale =
        template.content
        |> String.replace("canvas_get", "REDACTED_STALE_TOKEN")
        |> Kernel.<>(@stale_design_markers)

      {:ok, updated} = PromptTemplates.update_template(template, %{content: stale})
      updated
    end

    test "20260726051347 design-preplan migration FORCE-UPDATES a row still carrying the Saru stage" do
      # The deployed case: every environment that ran 20260713000010 has a
      # dispatch.planning row telling planners to author a
      # `responsibility: "designer"` design stage. ADR-0046 runs design
      # before planning, so leaving that row alone means every UI task gets
      # design twice.
      migration = Platform.Repo.Migrations.ForceUpdateDispatchPlanningDesignPreplan

      stale = stale_dispatch_planning_row()
      assert stale.content =~ ~s(responsibility: "designer")
      refute stale.content =~ "canvas_get"

      :ok = migration.up()

      refreshed = PromptTemplates.get_template_by_slug("dispatch.planning")

      assert refreshed.content ==
               PromptTemplates.default_content_for_slug("dispatch.planning")

      assert refreshed.content =~ "canvas_get"
      refute refreshed.content =~ ~s(responsibility: "designer")
      refute refreshed.content =~ "Design direction (Saru)"
      refute refreshed.content =~ "REDACTED_STALE_TOKEN"

      # Idempotent, and it does not duplicate the row.
      :ok = migration.up()

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content ==
               refreshed.content

      assert Platform.Repo.aggregate(
               Ecto.Query.from(t in Platform.Orchestration.PromptTemplate,
                 where: t.slug == "dispatch.planning"
               ),
               :count
             ) == 1
    end

    test "seed_defaults/0 does NOT undo a stale dispatch.planning row — the migration is load-bearing" do
      # The control for the test above. If `seed_defaults/0` repaired stale
      # rows, 20260726051347 would be ceremony. It is INSERT-only, so a
      # deployment that already has the row keeps serving the old body
      # forever and only the force-update reaches it.
      stale = stale_dispatch_planning_row()

      :ok = PromptTemplates.seed_defaults()

      after_seed = PromptTemplates.get_template_by_slug("dispatch.planning")

      assert after_seed.content == stale.content,
             "seed_defaults/0 must leave an existing row untouched (insert-only)"

      refute after_seed.content =~ "canvas_get"

      # And the migration does what seeding cannot.
      :ok = Platform.Repo.Migrations.ForceUpdateDispatchPlanningDesignPreplan.up()

      assert PromptTemplates.get_template_by_slug("dispatch.planning").content =~ "canvas_get"
    end

    test "20260726051347 design-preplan migration SKIPS a database with no dispatch.planning row" do
      # Fresh boots pick the slug up from `seed_defaults/0`; the migration
      # must not insert it a second time or crash on the nil.
      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      {:ok, _} = PromptTemplates.delete_template(template)

      refute PromptTemplates.get_template_by_slug("dispatch.planning")

      assert :ok = Platform.Repo.Migrations.ForceUpdateDispatchPlanningDesignPreplan.up()

      refute PromptTemplates.get_template_by_slug("dispatch.planning"),
             "the migration must skip a missing row, not insert one"
    end

    # ── task 019fa504 stage 3: the design decline exit ──────────────────────
    #
    # `design.task_direction.v1`'s `## Delivery` section named exactly one
    # exit — attach a canvas — because until this task that was the only exit
    # there was. Stages 1 and 2 built the second one (`PreplanStep.decline/3`,
    # exposed as the `task_design_decline` tool in the `task` bundle). A tool a
    # designer is never told about is not reachable in practice, so the prompt
    # has to name it. The row is what the designer actually reads, and the row
    # is only reachable by a force-update.
    @design_decline_marker "task_design_decline"
    @design_delivery_marker "task_attach_canvas"

    defp stale_design_task_direction_row do
      template = PromptTemplates.get_template_by_slug("design.task_direction.v1")
      assert template, "precondition: the design.task_direction.v1 row exists"

      stale = String.replace(template.content, @design_decline_marker, "REDACTED_STALE_TOKEN")

      refute stale =~ @design_decline_marker

      assert stale =~ @design_delivery_marker,
             "the stale body must still carry the delivery instruction — otherwise " <>
               "the force-update assertion below cannot tell 'the decline was added' " <>
               "from 'the whole Delivery section was replaced'"

      {:ok, updated} = PromptTemplates.update_template(template, %{content: stale})
      updated
    end

    test "20260727210000 design-decline migration FORCE-UPDATES a row that names only the canvas exit" do
      migration = Platform.Repo.Migrations.ForceUpdateDesignTaskDirectionDecline

      stale = stale_design_task_direction_row()
      refute stale.content =~ @design_decline_marker

      :ok = migration.up()

      refreshed = PromptTemplates.get_template_by_slug("design.task_direction.v1")

      assert refreshed.content ==
               PromptTemplates.default_content_for_slug("design.task_direction.v1")

      assert refreshed.content =~ @design_decline_marker
      refute refreshed.content =~ "REDACTED_STALE_TOKEN"

      # PAIRED, and the whole point of the pairing: the decline is added
      # ALONGSIDE the delivery instruction, never in place of it. A body that
      # lost `task_attach_canvas` would pass the assertion above and be
      # strictly worse than the bug being fixed.
      assert refreshed.content =~ @design_delivery_marker
      assert refreshed.content =~ "completion signal"

      # `variables` are deliberately not rewritten — this stage adds no slot.
      assert Enum.sort(refreshed.variables) ==
               ["attached_canvases", "brand_context", "task_summary"]

      # Idempotent, and it does not duplicate the row.
      :ok = migration.up()

      assert PromptTemplates.get_template_by_slug("design.task_direction.v1").content ==
               refreshed.content

      assert Platform.Repo.aggregate(
               Ecto.Query.from(t in Platform.Orchestration.PromptTemplate,
                 where: t.slug == "design.task_direction.v1"
               ),
               :count
             ) == 1
    end

    test "seed_defaults/0 does NOT undo a stale design.task_direction.v1 row — the migration is load-bearing" do
      # The control for the test above, and the reason the code edit to
      # `do_default_templates/0` is not the deliverable on its own.
      # `seed_defaults/0` is INSERT-only, so every environment that has ever
      # booted keeps serving the one-exit body forever and only the
      # force-update reaches it. Task 019fa469 proved this in production on
      # 2026-07-27: a green CI run and a published image left the defective
      # row untouched.
      stale = stale_design_task_direction_row()

      :ok = PromptTemplates.seed_defaults()

      after_seed = PromptTemplates.get_template_by_slug("design.task_direction.v1")

      assert after_seed.content == stale.content,
             "seed_defaults/0 must leave an existing row untouched (insert-only)"

      refute after_seed.content =~ @design_decline_marker

      # And the migration does what seeding cannot.
      :ok = Platform.Repo.Migrations.ForceUpdateDesignTaskDirectionDecline.up()

      assert PromptTemplates.get_template_by_slug("design.task_direction.v1").content =~
               @design_decline_marker
    end

    test "20260727210000 design-decline migration SKIPS a database with no design.task_direction.v1 row" do
      # Fresh boots pick the slug up from `seed_defaults/0`; the migration
      # must not insert it a second time or crash on the nil.
      template = PromptTemplates.get_template_by_slug("design.task_direction.v1")
      {:ok, _} = PromptTemplates.delete_template(template)

      refute PromptTemplates.get_template_by_slug("design.task_direction.v1")

      assert :ok = Platform.Repo.Migrations.ForceUpdateDesignTaskDirectionDecline.up()

      refute PromptTemplates.get_template_by_slug("design.task_direction.v1"),
             "the migration must skip a missing row, not insert one"
    end

    # This stage's migration runs on the TEST database like any other, so
    # by the time ExUnit boots the `dispatch.intent_attention` row already
    # exists — committed outside the sandbox. Both branch tests below need
    # to establish their own precondition rather than assume a blank slate.
    # The delete is rolled back with the test's transaction.
    defp drop_intent_attention_row do
      case PromptTemplates.get_template_by_slug("dispatch.intent_attention") do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end

      :ok
    end

    test "seed_defaults seeds dispatch.intent_attention with current default content" do
      :ok = drop_intent_attention_row()
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("dispatch.intent_attention")

      assert template,
             "seed_defaults/0 must insert the dispatch.intent_attention row on a fresh boot"

      assert template.content ==
               PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.intent_attention"))

      assert Enum.sort(template.variables) == Enum.sort(descriptor.variables)
    end

    test "20260725120000 intent_attention migration INSERTS when the slug is absent" do
      # The prod case. `suite.example.com` has already run the
      # earlier seed migrations, so `seed_defaults/0` never re-runs there
      # and a force-update-only migration would leave the new slug missing
      # forever. Assert the insert branch actually inserts.
      migration = Platform.Repo.Migrations.SeedAndForceUpdateIntentAttentionTemplate

      :ok = drop_intent_attention_row()

      refute PromptTemplates.get_template_by_slug("dispatch.intent_attention"),
             "precondition: no dispatch.intent_attention row before the migration runs"

      :ok = migration.up()

      template = PromptTemplates.get_template_by_slug("dispatch.intent_attention")
      assert template, "the migration must INSERT dispatch.intent_attention when absent"

      assert template.content ==
               PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      assert String.contains?(template.content, @intent_ack_preamble),
             "the inserted row must carry AC15's ack preamble"
    end

    test "20260725120000 intent_attention migration FORCE-UPDATES a stale existing row" do
      # The upgrade case, and the reason this migration is not
      # insert-if-missing like 20260707120000: a deployment that picked the
      # row up from `seed_defaults/0` at an earlier body revision must be
      # dragged forward to the current one.
      migration = Platform.Repo.Migrations.SeedAndForceUpdateIntentAttentionTemplate

      :ok = PromptTemplates.seed_defaults()
      seeded = PromptTemplates.get_template_by_slug("dispatch.intent_attention")
      assert seeded

      stale_content =
        seeded.content
        |> String.replace("intent_ack", "REDACTED_STALE_TOKEN")
        |> Kernel.<>("\n\n<!-- stale marker -->")

      {:ok, _} =
        PromptTemplates.update_template(seeded, %{
          content: stale_content,
          variables: ["federation_preamble"]
        })

      :ok = migration.up()

      refreshed = PromptTemplates.get_template_by_slug("dispatch.intent_attention")

      assert refreshed.content ==
               PromptTemplates.default_content_for_slug("dispatch.intent_attention")

      refute refreshed.content =~ "REDACTED_STALE_TOKEN"
      refute refreshed.content =~ "<!-- stale marker -->"

      # The variables list is refreshed too — a stale list means the
      # template editor shows the wrong knobs even when the body is right.
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "dispatch.intent_attention"))

      assert Enum.sort(refreshed.variables) == Enum.sort(descriptor.variables)

      # Idempotent: running it again leaves the same final state and does
      # not duplicate the row.
      :ok = migration.up()

      assert PromptTemplates.get_template_by_slug("dispatch.intent_attention").content ==
               refreshed.content

      assert Platform.Repo.aggregate(
               Ecto.Query.from(t in Platform.Orchestration.PromptTemplate,
                 where: t.slug == "dispatch.intent_attention"
               ),
               :count
             ) == 1
    end

    test "20260715220000 alarm_silence-fallback migration refreshes all four dispatch templates idempotently" do
      # Simulates the production upgrade sequence: a prior force-update
      # migration seeded the row with the OLD preamble body (task_ack only,
      # no alarm_silence fallback); the new migration runs and refreshes
      # every dispatch row to the current default. Running it twice
      # produces the same final state — idempotency.
      migration = Platform.Repo.Migrations.RefreshDispatchTemplatesAlarmSilenceFallback
      slugs = ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

      # Seed baseline rows (matches what a prior force-update migration
      # would have left in a production DB — descriptor variables + old
      # content body).
      :ok = PromptTemplates.seed_defaults()

      # Mutate each seeded row to simulate the pre-refresh state (an older
      # preamble body without the alarm_silence fallback). The migration
      # must overwrite this regardless of what it finds.
      for slug <- slugs do
        template = PromptTemplates.get_template_by_slug(slug)
        stale = String.replace(template.content, "alarm_silence", "REDACTED_STALE_TOKEN")

        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: stale <> "\n\n<!-- stale marker -->"
          })
      end

      # First run — refreshes everything.
      :ok = migration.up()

      for slug <- slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected,
               "#{slug} must be refreshed to current default content by the migration"

        refute row.content =~ "REDACTED_STALE_TOKEN",
               "#{slug} must have the pre-refresh marker overwritten"

        refute row.content =~ "<!-- stale marker -->",
               "#{slug} must have the stale suffix overwritten (not appended)"

        assert row.content =~ "alarm_silence",
               "#{slug} must carry the alarm_silence fallback after migration up/0"
      end

      # Second run — same final state (idempotent).
      :ok = migration.up()

      for slug <- slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected,
               "#{slug} must remain at current default content after a second migration run"
      end
    end

    test "20260719120100 migration patches the dispatch.in_progress row with the slot placeholder" do
      # Task 019f7b7e stage 3. Simulates the production upgrade: the live row
      # predates the placeholder, the migration runs, the row gains it.
      migration = Platform.Repo.Migrations.AddMigrationSlotSectionToDispatchInProgress

      :ok = PromptTemplates.seed_defaults()

      # Force the pre-upgrade state — strip the placeholder from the row and
      # drop it from the registered variables, exactly what a DB seeded
      # before this stage looks like.
      template = PromptTemplates.get_template_by_slug("dispatch.in_progress")
      stale_content = String.replace(template.content, "{{migration_slot_section}}\n", "")

      {:ok, _} =
        PromptTemplates.update_template(template, %{
          content: stale_content,
          variables: Enum.reject(template.variables, &(&1 == "migration_slot_section"))
        })

      refute PromptTemplates.get_template_by_slug("dispatch.in_progress").content =~
               "{{migration_slot_section}}"

      :ok = migration.up()

      row = PromptTemplates.get_template_by_slug("dispatch.in_progress")

      assert row.content =~ "{{migration_slot_section}}",
             "the seeded dispatch.in_progress row must carry the placeholder after the migration"

      assert row.content == PromptTemplates.default_content_for_slug("dispatch.in_progress")
      assert "migration_slot_section" in row.variables

      # Idempotent — a second run leaves the same state.
      :ok = migration.up()
      assert PromptTemplates.get_template_by_slug("dispatch.in_progress").content == row.content
    end

    test "20260719120100 migration leaves the other dispatch templates untouched" do
      migration = Platform.Repo.Migrations.AddMigrationSlotSectionToDispatchInProgress

      :ok = PromptTemplates.seed_defaults()

      before =
        for slug <- ~w(dispatch.planning dispatch.in_review dispatch.deploying),
            into: %{},
            do: {slug, PromptTemplates.get_template_by_slug(slug).content}

      :ok = migration.up()

      for {slug, content} <- before do
        assert PromptTemplates.get_template_by_slug(slug).content == content,
               "#{slug} must not be rewritten by the in_progress-only migration"
      end
    end

    test "20260719120100 migration is a safe no-op when the dispatch.in_progress row is missing" do
      # Fresh DB — the migration is refresh-only, not seed. `seed_defaults/0`
      # creates the row with the placeholder already present on first boot.
      # Purge the row the test DB's own migrations left behind so we actually
      # exercise the nil branch (same convention as the 20260715220000 test).
      case PromptTemplates.get_template_by_slug("dispatch.in_progress") do
        nil -> :ok
        template -> {:ok, _} = PromptTemplates.delete_template(template)
      end

      migration = Platform.Repo.Migrations.AddMigrationSlotSectionToDispatchInProgress

      assert :ok = migration.up()

      assert PromptTemplates.get_template_by_slug("dispatch.in_progress") == nil,
             "dispatch.in_progress must remain absent — migration is refresh-only, not seed"
    end

    test "20260715220000 alarm_silence-fallback migration is a safe no-op when the target rows are missing" do
      # Simulates a fresh DB (or a DB where the dispatch rows were purged) —
      # migration must not raise. New environments boot by calling
      # seed_defaults/0 later; the migration only refreshes rows that
      # already exist.
      slugs = ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

      # Purge any seeded dispatch rows so we exercise the nil-row branch.
      for slug <- slugs do
        case PromptTemplates.get_template_by_slug(slug) do
          nil -> :ok
          template -> {:ok, _} = PromptTemplates.delete_template(template)
        end
      end

      migration = Platform.Repo.Migrations.RefreshDispatchTemplatesAlarmSilenceFallback

      assert :ok = migration.up()

      # Still no rows — migration didn't insert.
      for slug <- slugs do
        assert PromptTemplates.get_template_by_slug(slug) == nil,
               "#{slug} must remain absent — migration is refresh-only, not seed"
      end
    end

    test "20260716211312 subagent-id-ack migration refreshes all four dispatch templates idempotently" do
      # Simulates the production upgrade sequence for task 019f6c73 stage 4:
      # a prior force-update migration seeded the row with a body that lacked
      # the subagent_id-required ack copy; this migration force-refreshes
      # every dispatch row to the current default. Running it twice produces
      # the same final state — idempotency.
      migration = Platform.Repo.Migrations.RefreshDispatchTemplatesSubagentIdAck
      slugs = ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

      # Seed baseline rows (matches what a prior force-update migration would
      # have left in a production DB — descriptor variables + old content
      # body without the subagent_id-required ack copy).
      :ok = PromptTemplates.seed_defaults()

      # Mutate each seeded row to simulate the pre-refresh state (an older
      # preamble body without subagent_id in the copy-pasteable ack). The
      # migration must overwrite this regardless of what it finds.
      for slug <- slugs do
        template = PromptTemplates.get_template_by_slug(slug)
        stale = String.replace(template.content, "subagent_id=", "REDACTED_STALE_TOKEN=")

        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: stale <> "\n\n<!-- stale marker -->"
          })
      end

      # First run — refreshes everything.
      :ok = migration.up()

      for slug <- slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected,
               "#{slug} must be refreshed to current default content by the migration"

        refute row.content =~ "REDACTED_STALE_TOKEN",
               "#{slug} must have the pre-refresh marker overwritten"

        refute row.content =~ "<!-- stale marker -->",
               "#{slug} must have the stale suffix overwritten (not appended)"

        # The ack-copy assertions are STAGE-SCOPED-ONLY as of task 019fa469
        # stage 5. This migration still rewrites `dispatch.planning` — it
        # writes whatever `default_content_for_slug/1` currently returns — but
        # what that returns for the planning slug no longer contains an ack
        # instruction, because a planning dispatch has no running stage to ack
        # and arms no timer that would miss one. The two migrations converge:
        # on a fresh DB this one writes the ack-free planning body and
        # 20260727183000 writes the same bytes; on a deployed DB this one ran
        # long ago and 20260727183000 is what moves the row.
        if slug != "dispatch.planning" do
          assert row.content =~ "subagent_id=",
                 "#{slug} must carry the subagent_id-required ack copy after migration up/0"

          assert row.content =~ "Spawn the subagent FIRST",
                 "#{slug} must carry the spawn-first ordering instruction after migration up/0"
        else
          refute row.content =~ "task_ack(",
                 "dispatch.planning must NOT carry an ack call after migration up/0 (task 019fa469 stage 5)"

          assert row.content =~ "You have been assigned a task that requires a plan",
                 "dispatch.planning must still have rendered its actual body"
        end
      end

      # Second run — same final state (idempotent).
      :ok = migration.up()

      for slug <- slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected,
               "#{slug} must remain at current default content after a second migration run"
      end
    end

    test "20260716211312 subagent-id-ack migration is a safe no-op when the target rows are missing" do
      # Simulates a fresh DB (or a DB where the dispatch rows were purged) —
      # migration must not raise. New environments boot by calling
      # seed_defaults/0 later; the migration only refreshes rows that
      # already exist.
      slugs = ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.deploying)

      # Purge any seeded dispatch rows so we exercise the nil-row branch.
      for slug <- slugs do
        case PromptTemplates.get_template_by_slug(slug) do
          nil -> :ok
          template -> {:ok, _} = PromptTemplates.delete_template(template)
        end
      end

      migration = Platform.Repo.Migrations.RefreshDispatchTemplatesSubagentIdAck

      assert :ok = migration.up()

      # Still no rows — migration didn't insert.
      for slug <- slugs do
        assert PromptTemplates.get_template_by_slug(slug) == nil,
               "#{slug} must remain absent — migration is refresh-only, not seed"
      end
    end

    test "20260717000000 federation-preamble migration refreshes all six dispatch templates idempotently" do
      # Simulates the production upgrade sequence for task 019f5e2a stage 3:
      # a prior force-update migration seeded the row with a body that
      # inlined the Organization Context / Writing to Org Memory / skills /
      # evidence blocks and referenced {{skills_reference}} /
      # {{evidence_workflow_reference}} placeholders. This migration
      # force-refreshes every dispatch row to the current default —
      # {{federation_preamble}} placeholder + trimmed variables list.
      migration = Platform.Repo.Migrations.RetrofitDispatchTemplatesWithFederationPreamble

      slugs = ~w(
        dispatch.planning
        dispatch.in_progress
        dispatch.in_review
        dispatch.review_e2e
        dispatch.deploying
        dispatch.fallback
      )

      # Seed baseline rows (matches what a prior force-update migration
      # would have left in a production DB — descriptor variables + old
      # content body).
      :ok = PromptTemplates.seed_defaults()

      # Mutate each seeded row to simulate the pre-refresh state (an older
      # body without the federation_preamble placeholder). The migration
      # must overwrite this regardless of what it finds.
      for slug <- slugs do
        template = PromptTemplates.get_template_by_slug(slug)

        stale =
          template.content
          |> String.replace("{{federation_preamble}}", "REDACTED_STALE_TOKEN")

        {:ok, _} =
          PromptTemplates.update_template(template, %{
            content: stale <> "\n\n<!-- stale marker -->",
            variables: ["skills_reference", "evidence_workflow_reference"]
          })
      end

      # First run — refreshes everything.
      :ok = migration.up()

      for slug <- slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected,
               "#{slug} must be refreshed to current default content by the migration"

        refute row.content =~ "REDACTED_STALE_TOKEN",
               "#{slug} must have the pre-refresh marker overwritten"

        refute row.content =~ "<!-- stale marker -->",
               "#{slug} must have the stale suffix overwritten (not appended)"

        assert row.content =~ "{{federation_preamble}}",
               "#{slug} must carry the federation_preamble placeholder after migration up/0"

        assert "federation_preamble" in row.variables,
               "#{slug} must carry the federation_preamble variable declaration after migration up/0"
      end

      # Second run — same final state (idempotent).
      :ok = migration.up()

      for slug <- slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected,
               "#{slug} must remain at current default content after a second migration run"
      end
    end

    test "20260717000000 federation-preamble migration is a safe no-op when the target rows are missing" do
      # Same nil-row guard as the earlier refresh migrations — must not
      # raise, must not insert.
      slugs = ~w(
        dispatch.planning
        dispatch.in_progress
        dispatch.in_review
        dispatch.review_e2e
        dispatch.deploying
        dispatch.fallback
      )

      # Purge any seeded dispatch rows so we exercise the nil-row branch.
      for slug <- slugs do
        case PromptTemplates.get_template_by_slug(slug) do
          nil -> :ok
          template -> {:ok, _} = PromptTemplates.delete_template(template)
        end
      end

      migration = Platform.Repo.Migrations.RetrofitDispatchTemplatesWithFederationPreamble

      assert :ok = migration.up()

      for slug <- slugs do
        assert PromptTemplates.get_template_by_slug(slug) == nil,
               "#{slug} must remain absent — migration is refresh-only, not seed"
      end
    end
  end

  describe "nudge slug (task 019f640d stage 4)" do
    test "nudge is registered in default_templates with the four expected variables" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "nudge"))

      assert descriptor,
             "expected `nudge` slug to appear in default_templates/0 " <>
               "(task 019f640d stage 4 — short-form safety-net / no-ack payload)"

      for var <- ~w(task_id stage_id elapsed_minutes pending_validation_ids) do
        assert var in descriptor.variables, "nudge must declare `#{var}` as a variable"
      end
    end

    test "nudge content is short and does NOT carry full-context markers" do
      content = PromptTemplates.default_content_for_slug("nudge")
      assert is_binary(content)

      # The seeded body is very small — the render-time interpolation only
      # substitutes 4 short strings, so this bounds real output too.
      assert String.length(content) < 800,
             "nudge slug body was #{String.length(content)} chars — payload discipline requires <800 (target <500 tokens rendered)"

      # Fat markers stay OUT.
      refute content =~ "{{skills_reference}}"
      refute content =~ "{{evidence_workflow_reference}}"
      refute content =~ "{{git_workflow_block}}"
      refute content =~ "## Skill discovery"
      refute content =~ "## Submitting evidence"
      refute content =~ "## Git Workflow"

      # Skeleton bits must be there.
      assert content =~ "## Completion Reminder"
      assert content =~ "{{task_id}}"
      assert content =~ "{{stage_id}}"
      assert content =~ "{{pending_validation_ids}}"
      assert content =~ "ack, push validation"
    end

    test "heartbeat slug is retained but description flags it as DEPRECATED" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "heartbeat"))

      assert descriptor, "heartbeat slug must still be registered (removed in stage 6 cleanup)"

      assert descriptor.description =~ "DEPRECATED",
             "heartbeat slug description must flag it as DEPRECATED so admin-UI readers see the notice"
    end
  end

  describe "skill-discovery step in dispatch templates" do
    # After task 019f5e2a stage 3 the skill-discovery guidance ships to every
    # Claude Code dispatch template via the consolidated `{{federation_preamble}}`
    # placeholder rather than a slug-specific `{{skills_reference}}` variable.
    # These tests exercise both the descriptor contract (every dispatch slug
    # embeds the placeholder + declares the variable) and the render-time
    # interpolation (the resolved output actually carries the discovery text).
    @all_dispatch_slugs ~w(
      dispatch.planning
      dispatch.in_progress
      dispatch.in_review
      dispatch.review_e2e
      dispatch.deploying
      dispatch.fallback
      dispatch.triage_dispatch
    )

    test "every dispatch slug embeds the {{federation_preamble}} placeholder" do
      for slug <- @all_dispatch_slugs do
        content = PromptTemplates.default_content_for_slug(slug)
        assert is_binary(content), "expected #{slug} to be a registered template"

        assert content =~ "{{federation_preamble}}",
               "expected #{slug} to embed the federation_preamble placeholder (Stage 3 retrofit)"
      end
    end

    test "every dispatch slug declares federation_preamble as a template variable" do
      for slug <- @all_dispatch_slugs do
        descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))
        assert descriptor, "expected #{slug} to be a registered default template"

        assert "federation_preamble" in descriptor.variables,
               "expected #{slug} to declare federation_preamble as a variable"
      end
    end

    test "render_template interpolates the skill-discovery step into every dispatch slug" do
      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        task_title: "Wire up the task-stack detail panel",
        task_description: "Add a panel showing stack members",
        task_priority: "medium",
        task_status: "in_progress",
        task_id: "abcd1234",
        task_slug: "abcd1234",
        stage_id: "stage-1",
        stage_info: "Plan: v1 (stage 1/1 — coding)",
        git_workflow_block: "",
        provider_specific_guidance: "",
        previous_rejection_reason: "",
        upstream_plans_section: "",
        pending_e2e_validations_json: "[]",
        execution_space_id: "11111111-1111-1111-1111-111111111111",
        repo_url: "git@github.com:acme/widgets.git",
        default_branch: "main",
        deploy_strategy_type: "manual",
        deploy_strategy_config: "%{}",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      for slug <- @all_dispatch_slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, assigns)

        assert rendered =~ "skill_list",
               "expected rendered #{slug} to carry skill_list after {{federation_preamble}} interpolation"

        assert rendered =~ "skill_get",
               "expected rendered #{slug} to carry skill_get after {{federation_preamble}} interpolation"

        assert rendered =~ "Derive this task's domain",
               "expected rendered #{slug} to carry the discovery-instruction fragment"

        # The placeholder must be fully consumed — no literal {{federation_preamble}}
        # left in the rendered output.
        refute rendered =~ "{{federation_preamble}}",
               "expected #{slug} to fully interpolate the federation_preamble placeholder"
      end
    end

    test "render_template skill-discovery is phrased as active tool calls, NOT a skills-key read" do
      # Regression guard: a future edit must not revert the discovery step to
      # the passive 'check the skills key' / 'read the attached skills object'
      # phrasing — the agent receives rendered text, not an introspectable
      # object, so 'the skills key' is not an actionable discovery mechanism.
      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        task_title: "Regression guard",
        task_description: "Guard the phrasing",
        task_priority: "medium",
        task_status: "in_progress",
        task_id: "abcd1234",
        task_slug: "abcd1234",
        stage_id: "stage-1",
        stage_info: "Plan: v1 (stage 1/1 — coding)",
        git_workflow_block: "",
        provider_specific_guidance: "",
        previous_rejection_reason: "",
        upstream_plans_section: "",
        pending_e2e_validations_json: "[]",
        execution_space_id: "11111111-1111-1111-1111-111111111111",
        repo_url: "git@github.com:acme/widgets.git",
        default_branch: "main",
        deploy_strategy_type: "manual",
        deploy_strategy_config: "%{}",
        federation_preamble: PromptTemplates.federation_preamble()
      }

      for slug <- @all_dispatch_slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, assigns)

        refute rendered =~ "check the `skills` key",
               "#{slug}: discovery must not say 'check the skills key'"

        refute rendered =~ "check the skills key",
               "#{slug}: discovery must not say 'check the skills key'"

        refute rendered =~ "read the attached skills object",
               "#{slug}: discovery must not say 'read the attached skills object'"

        assert rendered =~ "calling `skill_list` / `skill_get` yourself",
               "#{slug}: discovery must direct the agent to call the tools itself"
      end
    end
  end

  describe "historian.* dispatch templates (T6 — wiki-first writing)" do
    # ADR-0041 T6 ships three new historian-scoped dispatch templates plus
    # the journal-by-default rule on `dispatch.planning` /
    # `dispatch.in_progress`. The slugs are:
    #
    #   * historian.scheduled       — every-6h staggered anchor fires
    #   * historian.meeting_ended   — `:meeting_ended` PubSub fires
    #   * historian.threshold       — 100k-token pending-content sweep
    #
    # SystemEventScheduler + MeetingHistorianHandler + HistorianDispatcher
    # all call `PromptTemplates.render_template/2` for these slugs, with a
    # literal fallback in `HistorianDispatcher.post_instruction/5` for
    # empty-DB boot. Tests here lock in the DB-backed copy + the
    # `default_templates/0` descriptors.

    @historian_slugs ~w(historian.scheduled historian.meeting_ended historian.threshold)

    test "every new historian.* slug appears in default_templates/0" do
      defaults = PromptTemplates.default_templates()
      slugs = Enum.map(defaults, & &1.slug)

      for slug <- @historian_slugs do
        assert slug in slugs,
               "expected #{slug} to be a registered default template"
      end
    end

    test "historian.scheduled declares wiki-first variables and renders them" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "historian.scheduled"))

      assert descriptor, "historian.scheduled should appear in default_templates/0"

      for var <- ~w(workspace_id pending_tokens activity_digest date) do
        assert var in descriptor.variables,
               "historian.scheduled must declare #{var} as a variable"
      end

      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        workspace_id: "ws-test-001",
        pending_tokens: 12_345,
        activity_digest: "[digest] 3 journal entries, 7 chat messages today.",
        date: "2026-05-21"
      }

      assert {:ok, rendered} = PromptTemplates.render_template("historian.scheduled", assigns)

      assert rendered =~ "ws-test-001"
      assert rendered =~ "12345"
      assert rendered =~ "[digest] 3 journal entries, 7 chat messages today."
      assert rendered =~ "2026-05-21"
      assert rendered =~ "You are the Historian"
      assert rendered =~ "org/page/"
      assert rendered =~ "project/<id>/page/"
      assert rendered =~ "space/<id>/page/"
    end

    test "historian.meeting_ended declares scope variables and renders them" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "historian.meeting_ended"))

      assert descriptor, "historian.meeting_ended should appear in default_templates/0"

      for var <- ~w(meeting_id project_id chat_space_id meeting_summary) do
        assert var in descriptor.variables,
               "historian.meeting_ended must declare #{var} as a variable"
      end

      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        meeting_id: "00000000-0000-0000-0000-meetingaaaaaa",
        project_id: "00000000-0000-0000-0000-projectaaaaaa",
        chat_space_id: "00000000-0000-0000-0000-spaceaaaaaaa",
        meeting_summary: "Decision: ship the historian on the every-6h cadence."
      }

      assert {:ok, rendered} = PromptTemplates.render_template("historian.meeting_ended", assigns)

      assert rendered =~ "00000000-0000-0000-0000-meetingaaaaaa"
      assert rendered =~ "00000000-0000-0000-0000-projectaaaaaa"
      assert rendered =~ "00000000-0000-0000-0000-spaceaaaaaaa"
      assert rendered =~ "Decision: ship the historian on the every-6h cadence."
      # Wiki-first contract: explicit instruction to update page paths, not
      # to write durable content to journal paths.
      assert rendered =~ "memory_search"

      assert rendered =~ "project/{{project_id}}/page/decisions.md" or
               rendered =~ "/page/decisions.md"

      assert rendered =~ "/page/notes.md"
    end

    test "historian.threshold declares workspace + token variables and renders them" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "historian.threshold"))

      assert descriptor, "historian.threshold should appear in default_templates/0"

      for var <- ~w(workspace_id pending_tokens) do
        assert var in descriptor.variables,
               "historian.threshold must declare #{var} as a variable"
      end

      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        workspace_id: "ws-test-002",
        pending_tokens: 105_432
      }

      assert {:ok, rendered} = PromptTemplates.render_template("historian.threshold", assigns)

      assert rendered =~ "ws-test-002"
      assert rendered =~ "105432"
      assert rendered =~ "threshold"
      # The cursor-advance acknowledgement is part of the contract.
      assert rendered =~ "memory_create"
      assert rendered =~ "cursor"
    end

    test "every historian.* default forbids writing durable knowledge to journal paths" do
      # Wiki-first contract: pages are the curated long-term store; journal
      # is append-only and short-lived. Every historian dispatch slug must
      # carry the prohibition so a future edit can't quietly invert it.
      for slug <- @historian_slugs do
        content = PromptTemplates.default_content_for_slug(slug)

        assert is_binary(content), "#{slug} should have default content"

        assert content =~ "Wiki-first writing contract",
               "#{slug} must carry the 'Wiki-first writing contract' section header"

        assert content =~ "append-only" or content =~ "Journal is append-only",
               "#{slug} must call out that the journal is append-only"

        # Markdown bold (`**NEVER**`) breaks naive substring matching, so we
        # normalise asterisks before checking. The prohibition itself must
        # be authoritative copy, not paraphrasable.
        normalised = String.replace(content, "*", "")

        assert normalised =~ "never write durable knowledge to journal paths" or
                 normalised =~ "NEVER write durable knowledge to journal paths",
               "#{slug} must forbid writing durable knowledge to journal paths"
      end
    end

    test "every historian.* default names the wiki-page namespaces and memory_* edit tools" do
      # historian.scheduled covers all three page namespaces; .meeting_ended
      # and .threshold scope to project/space + workspace respectively. The
      # common contract is that every historian dispatch slug names AT LEAST
      # one page namespace and the memory_search read tool.
      for slug <- @historian_slugs do
        content = PromptTemplates.default_content_for_slug(slug)

        assert content =~ "memory_search",
               "expected #{slug} to mention memory_search"

        assert content =~ "/page/",
               "expected #{slug} to name at least one wiki-page namespace (e.g. project/<id>/page/)"
      end
    end

    test "seed_defaults inserts historian.* rows when missing" do
      :ok = PromptTemplates.seed_defaults()

      for slug <- @historian_slugs do
        template = PromptTemplates.get_template_by_slug(slug)

        assert template, "seed_defaults must insert #{slug}"

        expected = PromptTemplates.default_content_for_slug(slug)
        assert template.content == expected
      end
    end

    test "no historian.* default still instructs an empty acknowledgement journal write (task 019f5e7d)" do
      # Task 019f5e7d root cause: the pre-fix `historian.threshold` step 4
      # told the agent to `memory_create` an empty entry against today's
      # journal when the backlog drained — every such write became fresh
      # unindexed content that re-crossed the threshold on the next tick,
      # producing ~80 no-op entries in `org/journal/2026-07-13.md`. The
      # code default has been rewritten to REMOVE that instruction; this
      # guard pins the regression shut across all three historian slugs.
      for slug <- @historian_slugs do
        content = PromptTemplates.default_content_for_slug(slug)

        assert is_binary(content), "#{slug} should have default content"

        # Every historian dispatch slug must now explicitly forbid
        # writing a no-op / acknowledgement entry.
        assert content =~ "Do NOT write",
               "#{slug} must carry an explicit 'Do NOT write' no-op suppression directive"

        # The specific pre-fix instruction must NOT survive anywhere in
        # the template body.
        refute content =~ "call `memory_create` with an empty entry",
               "#{slug} must NOT instruct the agent to call memory_create with an empty entry"

        refute content =~ "call memory_create with an empty entry",
               "#{slug} must NOT instruct the agent to call memory_create with an empty entry (unbacktick form)"

        # And the specific per-pass "when the backlog is drained ...
        # acknowledge" recipe must not be present in any form.
        refute content =~ "backlog is drained, call",
               "#{slug} must NOT tell the agent to call memory_create when the backlog is drained"
      end
    end

    test "historian.threshold explicitly instructs silent return on empty backlog (task 019f5e7d)" do
      # The replacement for the old step 4 must be authoritative copy —
      # naming the loop symptom ('backlog drained' / 'no new entries')
      # and instructing the agent to RETURN SILENTLY rather than write
      # an acknowledgement.
      content = PromptTemplates.default_content_for_slug("historian.threshold")

      assert content =~ "RETURN SILENTLY",
             "historian.threshold must instruct RETURN SILENTLY when there's nothing to curate"

      assert content =~ "backlog drained",
             "historian.threshold must name the 'backlog drained' anti-pattern so an edit can't paraphrase it away"

      assert content =~ "no new entries",
             "historian.threshold must name the 'no new entries' anti-pattern"

      # The agent needs to be told that the cursor still advances so
      # 'silent return' doesn't feel like a broken contract.
      assert content =~ "Historian.mark_run_started/1",
             "historian.threshold must reassure the agent that the cursor advances via Historian.mark_run_started/1"
    end
  end

  describe "dreaming dispatch templates (historian.dreaming + memory.dreaming.v1)" do
    # Task 019f70e9 stage 5 extracted the Historian's dreaming-mode prompt
    # out of the legacy SystemEventScheduler fallback and registered it
    # under two slugs sharing a single source of truth:
    #
    #   * historian.dreaming — canonical (router-owned dispatch path)
    #   * memory.dreaming.v1 — legacy (Handlers.Dreaming default_prompt_template)
    #
    # Byte-identity between the two slugs is load-bearing: the same body
    # must render on either code path so an edit can't silently diverge
    # what Historian sees when dispatched via the router vs the
    # responsibility scheduler.

    @dreaming_slugs ~w(historian.dreaming memory.dreaming.v1)

    @dreaming_migration_path Path.join([
                               __ENV__.file
                               |> Path.dirname()
                               |> Path.dirname()
                               |> Path.dirname()
                               |> Path.dirname(),
                               "priv/repo/migrations/20260718230000_seed_dreaming_prompt_dual_slug.exs"
                             ])

    Code.compile_file(@dreaming_migration_path)

    test "both dreaming slugs appear in default_templates/0" do
      defaults = PromptTemplates.default_templates()
      slugs = Enum.map(defaults, & &1.slug)

      for slug <- @dreaming_slugs do
        assert slug in slugs,
               "expected #{slug} to be a registered default template"
      end
    end

    test "both dreaming slugs return byte-identical content — single source of truth" do
      canonical = PromptTemplates.default_content_for_slug("historian.dreaming")
      legacy = PromptTemplates.default_content_for_slug("memory.dreaming.v1")

      assert is_binary(canonical)
      assert is_binary(legacy)

      assert canonical == legacy,
             "historian.dreaming and memory.dreaming.v1 must share byte-identical content — " <>
               "any drift breaks the single-source-of-truth guarantee that the migration " <>
               "and both dispatch paths depend on"
    end

    test "both dreaming slugs declare the same variables list" do
      canonical =
        PromptTemplates.default_templates() |> Enum.find(&(&1.slug == "historian.dreaming"))

      legacy =
        PromptTemplates.default_templates() |> Enum.find(&(&1.slug == "memory.dreaming.v1"))

      assert canonical.variables == legacy.variables,
             "both dreaming slugs must declare the same variables list"

      for var <-
            ~w(federation_preamble date workspace_id activity_digest rejected_exemplars skills_reference) do
        assert var in canonical.variables,
               "dreaming template must declare #{var} as a variable"
      end
    end

    test "both dreaming slugs render without unresolved {{...}} placeholders when supplied full assigns" do
      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        federation_preamble: "You are Historian, running under the Fabrikam federation preamble.",
        date: "2026-07-18",
        workspace_id: "ws-dreaming-001",
        activity_digest: "[digest] 12 journal entries, 4 chat threads today.",
        rejected_exemplars:
          "- [recurring-theme] Rowan asked about avatar rings twice this month\n  - Rowan's feedback: this is not a durable insight, avoid re-surfacing",
        skills_reference: "## Skill discovery\n\nDiscover skills via skill_list."
      }

      for slug <- @dreaming_slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, assigns)
        assert is_binary(rendered)

        # No unresolved `{{key}}` placeholder should survive the render —
        # every variable in the template body must be present in assigns.
        refute rendered =~ ~r/\{\{\w+\}\}/,
               "#{slug} rendered content contains an unresolved {{...}} placeholder"

        # Sanity: each supplied assign shows up in the rendered body.
        assert rendered =~ "ws-dreaming-001", "#{slug} must interpolate workspace_id"
        assert rendered =~ "2026-07-18", "#{slug} must interpolate date"
        assert rendered =~ "12 journal entries", "#{slug} must interpolate activity_digest"

        assert rendered =~ "recurring-theme",
               "#{slug} must interpolate rejected_exemplars"

        assert rendered =~ "federation preamble",
               "#{slug} must interpolate federation_preamble"

        assert rendered =~ "Skill discovery",
               "#{slug} must interpolate skills_reference"
      end
    end

    test "dreaming template body specifies the six synthesis-proposal categories" do
      content = PromptTemplates.default_content_for_slug("historian.dreaming")

      for category <-
            ~w(recurring-theme cross-project-pattern emerging-risk stale-fact-candidate-retirement strategic-insight unresolved-question) do
        assert content =~ category,
               "historian.dreaming must document the '#{category}' category"
      end

      # The block grammar itself must be reproduced verbatim so the
      # model emits parseable proposals.
      assert content =~ "<synthesis-proposal"
      assert content =~ "</synthesis-proposal>"
      assert content =~ "confidence"
      assert content =~ "evidence"
    end

    test "dreaming template body specifies the three MaintenanceSubagent spawn functions" do
      content = PromptTemplates.default_content_for_slug("historian.dreaming")

      assert content =~ "Platform.Memory.Integrity.scan/1",
             "dreaming template must name the Integrity.scan/1 entry point"

      for spawn_fun <- ~w(spawn_link_repair spawn_format_normalize spawn_retired_cleanup) do
        assert content =~ spawn_fun,
               "dreaming template must name MaintenanceSubagent.#{spawn_fun}/1"
      end

      # Subagent-per-op discipline is load-bearing — it must be explicit
      # copy so a future edit can't paraphrase it into "batch the ops in
      # the parent Historian context".
      assert content =~ "subagent-per-op" or content =~ "Subagent-per-op",
             "dreaming template must state the subagent-per-op discipline"
    end

    test "dreaming template body forbids direct page writes and routes approvals through /memory/proposals" do
      content = PromptTemplates.default_content_for_slug("historian.dreaming")

      # The whole point of the pipeline: no direct page writes from
      # dreaming. Rowan approves at /memory/proposals or the change
      # doesn't land.
      assert content =~ "/memory/proposals",
             "dreaming template must reference the /memory/proposals approval surface"

      assert content =~ "NEVER write directly to page" or
               content =~ "never write directly to page" or
               content =~ "NEVER write directly to pages" or
               content =~ "never write directly to pages",
             "dreaming template must forbid direct page writes"
    end

    test "dreaming template body specifies the absolute-wikilink format with an explicit example" do
      content = PromptTemplates.default_content_for_slug("historian.dreaming")

      # The bare-basename anti-pattern is what makes format_dirty entries
      # in Integrity.scan/1. The template must call it out concretely.
      assert content =~ "[[org/page/foo/bar.md]]",
             "dreaming template must give the absolute-link format example"

      assert content =~ "[[bar]]",
             "dreaming template must give the bare-basename anti-pattern example"
    end

    test "dreaming template carries the {{rejected_exemplars}} placeholder" do
      content = PromptTemplates.default_content_for_slug("historian.dreaming")

      assert content =~ "{{rejected_exemplars}}",
             "dreaming template must carry the {{rejected_exemplars}} placeholder"

      # The section header contextualises the exemplars so the model
      # knows how to interpret them.
      assert content =~ "Rejected proposals" or content =~ "rejected proposals",
             "dreaming template must caption the rejected-exemplars section"
    end

    test "seed_defaults inserts both dreaming rows on a clean DB" do
      :ok = PromptTemplates.seed_defaults()

      for slug <- @dreaming_slugs do
        template = PromptTemplates.get_template_by_slug(slug)

        assert template, "seed_defaults must insert #{slug}"

        expected = PromptTemplates.default_content_for_slug(slug)
        assert template.content == expected
      end
    end

    test "list_templates/0 after seed_defaults/0 includes both dreaming slugs" do
      :ok = PromptTemplates.seed_defaults()

      slugs = PromptTemplates.list_templates() |> Enum.map(& &1.slug)

      for slug <- @dreaming_slugs do
        assert slug in slugs,
               "list_templates/0 must surface #{slug} after seed_defaults/0"
      end
    end

    test "20260718230000 dual-slug migration force-updates a stale row to the current default" do
      # Simulates production upgrade: an older revision of one dreaming
      # slug exists in the DB with a stale body. Migration must overwrite
      # it with the current default while leaving the other slug alone
      # (or seeding it fresh if absent).
      migration = Platform.Repo.Migrations.SeedDreamingPromptDualSlug

      :ok = PromptTemplates.seed_defaults()

      # Mutate `historian.dreaming` to simulate the pre-refresh state.
      template = PromptTemplates.get_template_by_slug("historian.dreaming")

      {:ok, _} =
        PromptTemplates.update_template(template, %{
          content: "STALE DREAMING BODY — should be overwritten"
        })

      assert :ok = migration.up()

      for slug <- @dreaming_slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row, "#{slug} must exist after migration"

        assert row.content == expected,
               "#{slug} must be refreshed to current default content by the migration"

        refute row.content =~ "STALE DREAMING BODY",
               "#{slug} must have the pre-refresh marker overwritten"
      end
    end

    test "20260718230000 dual-slug migration inserts both rows on a DB where neither exists" do
      # Simulates a fresh env where seed_defaults/0 has never run — the
      # migration must land both rows so `memory.dreaming.v1` lookup by
      # `Handlers.Dreaming` never falls through to an empty template
      # render.
      migration = Platform.Repo.Migrations.SeedDreamingPromptDualSlug

      # Purge any seeded dreaming rows so we exercise the insert branch.
      for slug <- @dreaming_slugs do
        case PromptTemplates.get_template_by_slug(slug) do
          nil -> :ok
          template -> {:ok, _} = PromptTemplates.delete_template(template)
        end
      end

      assert :ok = migration.up()

      for slug <- @dreaming_slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row, "#{slug} must be inserted by the migration when absent"
        assert row.content == expected
      end
    end

    test "20260718230000 dual-slug migration is idempotent" do
      # Second run leaves the DB in the same state — no exception, no
      # duplicate insertion (unique index on slug protects the DB, but
      # the migration must also not raise).
      migration = Platform.Repo.Migrations.SeedDreamingPromptDualSlug

      assert :ok = migration.up()
      assert :ok = migration.up()

      for slug <- @dreaming_slugs do
        row = PromptTemplates.get_template_by_slug(slug)
        expected = PromptTemplates.default_content_for_slug(slug)

        assert row.content == expected
      end
    end
  end

  describe "architecture.review_plan.v1 (ADR-0044 stage 3)" do
    # The architect plan-review template is seeded by `do_default_templates/0`
    # and rendered by `Handlers.ArchitectureReviewPlan.render_instruction/1`.
    # These tests lock the variable list + core content anchors so a future
    # edit can't silently drop the plan-summary / sibling / ADR blocks.

    test "appears in default_templates/0 with the expected variables" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "architecture.review_plan.v1"))

      assert descriptor, "architecture.review_plan.v1 must appear in default_templates/0"

      for var <- ~w(plan_summary sibling_tasks open_prs adr_index) do
        assert var in descriptor.variables,
               "architecture.review_plan.v1 must declare #{var} as a variable"
      end
    end

    test "default content wires the four {{variable}} placeholders" do
      content = PromptTemplates.default_content_for_slug("architecture.review_plan.v1")

      assert is_binary(content)

      for placeholder <- ~w({{plan_summary}} {{sibling_tasks}} {{open_prs}} {{adr_index}}) do
        assert content =~ placeholder,
               "architecture.review_plan.v1 must interpolate the #{placeholder} placeholder"
      end
    end

    # ADR-0046 member 5 stage 4 INVERTED the second half of this test.
    # `Tasks.approve_plan/3` now refuses a non-human approval behind an
    # open architecture gate, so "additive, not a blocker" and "the plan
    # advances regardless of what you find" became false claims — and a
    # prompt that tells the architect its verdict does not matter trains
    # it out of using the gate. The three concern kinds SURVIVE, demoted:
    # they are reported in `summary` and only escalate to a reject when
    # one crosses a constraint.
    test "content carries the three concern-kind anchors + the GATE contract" do
      content = PromptTemplates.default_content_for_slug("architecture.review_plan.v1")

      # The three concern kinds the architect reports.
      assert content =~ "collision"
      assert content =~ "adr_drift"
      assert content =~ "dup_abstraction"

      # The gate contract, and the closed constraint vocabulary the
      # verdict tool enforces. Prompt and validator speak one vocabulary.
      assert content =~ "plan_architecture_verdict"

      for constraint <- Platform.Tasks.Plan.architecture_constraints() do
        assert content =~ constraint
      end

      # The two sentences that are now false.
      refute content =~ "additive, not a blocker"
      refute content =~ "regardless of what you find"
      refute content =~ "does NOT block plan approval"
    end

    test "seed_defaults seeds architecture.review_plan.v1 into the DB" do
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("architecture.review_plan.v1")

      assert template

      assert template.content ==
               PromptTemplates.default_content_for_slug("architecture.review_plan.v1")
    end
  end

  describe "architecture.audit_diff.v1 (ADR-0044 stage 4)" do
    # The architect drift-audit template is seeded by `do_default_templates/0`
    # and rendered by `Handlers.ArchitectureAuditDiff.render_instruction/1`.
    # These tests lock the variable list + core content anchors so a future
    # edit can't silently drop the planned-shape / stage-diff / ORG_MEMORY
    # blocks.

    test "appears in default_templates/0 with the expected variables" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "architecture.audit_diff.v1"))

      assert descriptor, "architecture.audit_diff.v1 must appear in default_templates/0"

      for var <- ~w(stage_diff planned_shape org_memory_entries) do
        assert var in descriptor.variables,
               "architecture.audit_diff.v1 must declare #{var} as a variable"
      end
    end

    test "default content wires the three {{variable}} placeholders" do
      content = PromptTemplates.default_content_for_slug("architecture.audit_diff.v1")

      assert is_binary(content)

      for placeholder <- ~w({{stage_diff}} {{planned_shape}} {{org_memory_entries}}) do
        assert content =~ placeholder,
               "architecture.audit_diff.v1 must interpolate the #{placeholder} placeholder"
      end
    end

    test "content carries the four concern-kind anchors + additive contract" do
      content = PromptTemplates.default_content_for_slug("architecture.audit_diff.v1")

      # The four concern kinds the drift audit flags.
      assert content =~ "divergence"
      assert content =~ "new_dep"
      assert content =~ "migration"
      assert content =~ "memory_violation"

      # The additive-not-blocking contract.
      assert content =~ "additive" or content =~ "not a blocker"

      # Explicitly tell the agent the reviewer path fires regardless — the
      # architect is an annotation-only surface, not a gate. Multiple
      # phrasings accepted so incidental line-wrapping doesn't fail the
      # assertion (the paragraph text may split "reviewer's" and
      # "dispatch fires" across a newline).
      assert content =~ "reviewer" and
               (content =~ "dispatch fires" or content =~ "does NOT block")
    end

    test "seed_defaults seeds architecture.audit_diff.v1 into the DB" do
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("architecture.audit_diff.v1")

      assert template

      assert template.content ==
               PromptTemplates.default_content_for_slug("architecture.audit_diff.v1")
    end
  end

  describe "architecture.cron_sweep.v1 (ADR-0044 stage 5)" do
    # Locks the shape of the weekly Monday 04:00 UTC sweep template. The
    # template is the copy the Architect sees when the sweep fires; the
    # variables must round-trip through
    # `Handlers.ArchitectureCronSweep.render_instruction/1` so a later
    # rename of a placeholder here can't silently break the handler.

    test "appears in default_templates/0 with the expected variables" do
      descriptor =
        PromptTemplates.default_templates()
        |> Enum.find(&(&1.slug == "architecture.cron_sweep.v1"))

      assert descriptor, "architecture.cron_sweep.v1 must appear in default_templates/0"

      for var <- ~w(open_prs recent_closed_tasks adr_index) do
        assert var in descriptor.variables,
               "architecture.cron_sweep.v1 must declare #{var} as a variable"
      end
    end

    test "default content wires the three {{variable}} placeholders" do
      content = PromptTemplates.default_content_for_slug("architecture.cron_sweep.v1")

      assert is_binary(content)

      for placeholder <- ~w({{open_prs}} {{recent_closed_tasks}} {{adr_index}}) do
        assert content =~ placeholder,
               "architecture.cron_sweep.v1 must interpolate the #{placeholder} placeholder"
      end
    end

    test "content carries the four concern-kind anchors + additive contract" do
      content = PromptTemplates.default_content_for_slug("architecture.cron_sweep.v1")

      # The four category buckets the sweep evaluates.
      assert content =~ "ADR gap"
      assert content =~ "Doc drift"
      assert content =~ "tech debt" or content =~ "Latent tech debt"
      assert content =~ "Open PR"

      # The additive-not-blocking contract.
      assert content =~ "additive" or content =~ "not a blocker"

      # Follow-up cap so the model can't flood the backlog. The handler
      # also enforces `@max_followups` at the code level; both surfaces
      # must agree on 3.
      assert content =~ "3 follow-up" or content =~ "3 items" or
               content =~ "at most 3"

      # The filed-by metadata marker every follow-up carries — used by
      # the follow-up-count query in the handler's tests.
      assert content =~ "architect_cron_sweep" or content =~ "filed_by"

      # The output-shape anchor — the handler parses `followups` from
      # the model's JSON reply.
      assert content =~ "followups"
    end

    test "seed_defaults seeds architecture.cron_sweep.v1 into the DB" do
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("architecture.cron_sweep.v1")

      assert template

      assert template.content ==
               PromptTemplates.default_content_for_slug("architecture.cron_sweep.v1")
    end
  end

  describe "task_ack preamble on every STAGE-SCOPED dispatch template (task 019f640d stage 5)" do
    # The ack-first preamble tells the runtime that its FIRST tool call
    # must be `task_ack(task_id, stage_id)` — which the TaskRouter
    # consumes via `execution.acked` to extend the safety-net timer and
    # suppress the 5-minute no-ack alert (stage 3 wiring). Every
    # stage-scoped dispatch template MUST carry the preamble; each of those
    # templates' variables lists MUST declare `task_id` + `stage_id` so
    # mustache actually interpolates them at render time.
    #
    # `dispatch.planning` was in this list until task 019fa469 stage 5 and
    # that membership is what kept the defect green: a planning dispatch has
    # no plan, so `ToolSurface.resolve_ack_stage_id/2` answers
    # `{:error, :no_running_stage}` and the instruction cannot be followed —
    # while `TaskRouter.arm_liveness_timers/3` arms nothing for a stage-less
    # dispatch, so there was no alarm to satisfy either. Its replacement
    # coverage (the ack is ABSENT, and absent for a stated reason) lives in
    # `dispatch_planning_ack_test.exs`, which also carries the counterfactual
    # that these three slugs keep the ack.

    @dispatch_slugs ~w(dispatch.in_progress dispatch.in_review dispatch.deploying)

    test "every dispatch template body starts with the ack-first preamble" do
      for slug <- @dispatch_slugs do
        content = PromptTemplates.default_content_for_slug(slug)
        assert is_binary(content), "#{slug} should have default content"

        assert content =~ "Your first tool call must be `task_ack",
               "#{slug} must carry the task_ack preamble"

        assert content =~ "no-ack alert in 5 minutes",
               "#{slug} must explain the consequence of skipping the ack"

        assert content =~ "task_ack(task_id=\"{{task_id}}\", stage_id=\"{{stage_id}}\"",
               "#{slug} must interpolate task_id + stage_id into the copy-pasteable ack call"

        assert content =~ "subagent_id=",
               "#{slug} must include subagent_id in the copy-pasteable ack call (task 019f6c73 stage 3)"

        assert content =~ "Spawn the subagent FIRST",
               "#{slug} must instruct spawn-first ordering (task 019f6c73 stage 3)"
      end
    end

    test "every dispatch template body carries the alarm_silence fallback sentence (task 019f6791 stage 4)" do
      # Stage 3 shipped `alarm_silence` as the durable replacement for the
      # `report_blocker(needs_human: false)` ack-proxy anti-pattern. The
      # preamble must expose it as the operator escape hatch for cases where
      # `task_ack` is missing from the caller's MCP tool cache, and it must
      # explicitly forbid the old anti-pattern so muscle memory doesn't drift
      # back.
      for slug <- @dispatch_slugs do
        content = PromptTemplates.default_content_for_slug(slug)
        assert is_binary(content), "#{slug} should have default content"

        assert content =~ "If `task_ack` is missing from your MCP tool cache",
               "#{slug} must carry the alarm_silence fallback sentence"

        assert content =~
                 "alarm_silence(task_id=\"{{task_id}}\", stage_id=\"{{stage_id}}\", until_seconds=1800",
               "#{slug} must show a copy-pasteable alarm_silence call with interpolated task_id/stage_id and until_seconds=1800"

        assert content =~ "operator escape hatch",
               "#{slug} must frame alarm_silence as an operator escape hatch, not a routine tool"

        assert content =~ "Do NOT use `report_blocker(needs_human: false)`",
               "#{slug} must explicitly forbid the report_blocker(needs_human:false) ack-proxy anti-pattern"

        assert content =~ "leaks across stage boundaries",
               "#{slug} must explain WHY the anti-pattern is dangerous (leak across stage boundaries)"
      end
    end

    test "task_ack_preamble/0 exposes the alarm_silence fallback body" do
      # Callers that reuse task_ack_preamble/0 in their own rendered payloads
      # (see HeartbeatScheduler render path) must see the same alarm_silence
      # fallback the seeded templates carry, so no dispatch surface loses the
      # escape-hatch instruction.
      preamble = PromptTemplates.task_ack_preamble()

      assert is_binary(preamble)
      assert preamble =~ "If `task_ack` is missing from your MCP tool cache"
      assert preamble =~ "alarm_silence(task_id=\"{{task_id}}\""
      assert preamble =~ "until_seconds=1800"
      assert preamble =~ "Do NOT use `report_blocker(needs_human: false)`"
      assert preamble =~ "subagent_id="
      assert preamble =~ "Spawn the subagent FIRST"
    end

    test "alarm_silence fallback sentence is preserved (task 019f6c73 stage 3)" do
      # Belt-and-braces regression guard: the alarm_silence escape-hatch
      # sentence (originally shipped by task 019f6791 stage 4) must survive
      # every future preamble refactor. Mirrors the four sub-assertions
      # exercised on each dispatch template body, but pinned directly to
      # task_ack_preamble/0 so a preamble edit that silently drops the
      # escape hatch fails LOUDLY here instead of only manifesting as an
      # audit-trail regression later.
      preamble = PromptTemplates.task_ack_preamble()

      assert preamble =~ "If `task_ack` is missing from your MCP tool cache",
             "task_ack_preamble/0 must carry the alarm_silence fallback sentence"

      assert preamble =~
               "alarm_silence(task_id=\"{{task_id}}\", stage_id=\"{{stage_id}}\", until_seconds=1800",
             "task_ack_preamble/0 must show a copy-pasteable alarm_silence call with interpolated task_id/stage_id and until_seconds=1800"

      assert preamble =~ "operator escape hatch",
             "task_ack_preamble/0 must frame alarm_silence as an operator escape hatch"

      assert preamble =~ "Do NOT use `report_blocker(needs_human: false)`",
             "task_ack_preamble/0 must explicitly forbid the report_blocker(needs_human:false) ack-proxy anti-pattern"

      assert preamble =~ "leaks across stage boundaries",
             "task_ack_preamble/0 must explain WHY the anti-pattern is dangerous"
    end

    test "every dispatch template registers task_id + stage_id as variables" do
      for slug <- @dispatch_slugs do
        descriptor =
          PromptTemplates.default_templates()
          |> Enum.find(&(&1.slug == slug))

        assert descriptor, "#{slug} should appear in default_templates/0"

        assert "task_id" in descriptor.variables,
               "#{slug} must declare task_id so the ack preamble can interpolate it"

        assert "stage_id" in descriptor.variables,
               "#{slug} must declare stage_id so the ack preamble can interpolate it"
      end
    end

    test "render_template fully interpolates the preamble task_id + stage_id placeholders" do
      :ok = PromptTemplates.seed_defaults()

      task_id = "task-abcd1234-0000-0000-0000-000000000001"
      stage_id = "stage-fedc2345-0000-0000-0000-000000000002"

      base_assigns = %{
        task_id: task_id,
        stage_id: stage_id,
        task_title: "Ack preamble render test",
        task_description: "Bodyless",
        task_priority: "medium",
        stage_info: "Plan: v1 (stage 1/1 — coding)",
        git_workflow_block: "",
        provider_specific_guidance: "",
        previous_rejection_reason: "",
        upstream_plans_section: "",
        federation_preamble: "",
        repo_url: "",
        default_branch: "main",
        task_slug: "ack",
        deploy_strategy_type: "manual",
        deploy_strategy_config: "%{}"
      }

      for slug <- @dispatch_slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, base_assigns)

        assert rendered =~
                 ~s|task_ack(task_id="#{task_id}", stage_id="#{stage_id}", subagent_id=|,
               "#{slug} must interpolate both task_id and stage_id into the preamble at render time and carry the subagent_id placeholder"

        refute rendered =~ "{{task_id}}",
               "#{slug} must fully consume the {{task_id}} placeholder"

        refute rendered =~ "{{stage_id}}",
               "#{slug} must fully consume the {{stage_id}} placeholder"
      end
    end

    test "task_ack_preamble/0 exposes the shared preamble body for other renderers" do
      preamble = PromptTemplates.task_ack_preamble()

      assert is_binary(preamble)
      assert preamble =~ "Your first tool call must be `task_ack"
      assert preamble =~ "{{task_id}}"
      assert preamble =~ "{{stage_id}}"
      assert preamble =~ "no-ack alert in 5 minutes"
    end
  end

  describe "journal-by-default rule on dispatch.planning + dispatch.in_progress (T6)" do
    # T6 adds a "Journal-by-default for non-Historian agents" rule to the
    # two dispatch slugs used by non-Historian agents, making the
    # `<correction target="<page-path>" line="<N>">…</correction>`
    # convention authoritative copy. After task 019f5e2a stage 3 this rule
    # ships via the consolidated `federation_preamble` rather than being
    # inlined into each dispatch template's content — the tests below
    # verify the rendered dispatch output carries the rule end-to-end.

    @non_historian_dispatch_slugs ~w(dispatch.planning dispatch.in_progress)

    @non_historian_render_assigns %{
      task_id: "task-t6",
      stage_id: "stage-t6",
      task_title: "T6 render probe",
      task_description: "T6",
      task_priority: "medium",
      stage_info: "Plan: v1 (stage 1/1)",
      git_workflow_block: "",
      provider_specific_guidance: "",
      previous_rejection_reason: "",
      upstream_plans_section: ""
    }

    test "dispatch.planning + dispatch.in_progress render the journal-by-default rule" do
      :ok = PromptTemplates.seed_defaults()

      assigns =
        Map.put(
          @non_historian_render_assigns,
          :federation_preamble,
          PromptTemplates.federation_preamble()
        )

      for slug <- @non_historian_dispatch_slugs do
        {:ok, rendered} = PromptTemplates.render_template(slug, assigns)

        assert rendered =~ "Journal-by-default for non-Historian agents",
               "#{slug} render must carry the 'Journal-by-default' section header (via federation_preamble)"

        assert rendered =~ "<correction target=",
               "#{slug} render must document the <correction target=...> block convention"

        assert rendered =~ ":historian_only",
               "#{slug} render must name the :historian_only error code agents will see"

        # Direct page writes by non-Historian agents are explicitly
        # forbidden — the prohibition must be present, not implied.
        assert rendered =~ "never call `memory_str_replace`" or
                 rendered =~ "never call memory_str_replace",
               "#{slug} render must explicitly forbid calling memory_str_replace against page paths"
      end
    end

    test "dispatch.planning + dispatch.in_progress render the memory_* path routing block" do
      # Guard against an over-eager edit that removes the path-routing
      # block (the cross-task contract with T5's tool surface) while
      # keeping the journal-by-default rule. Post-Stage-3 both blocks
      # ship via `federation_preamble`.
      :ok = PromptTemplates.seed_defaults()

      assigns =
        Map.put(
          @non_historian_render_assigns,
          :federation_preamble,
          PromptTemplates.federation_preamble()
        )

      for slug <- @non_historian_dispatch_slugs do
        {:ok, rendered} = PromptTemplates.render_template(slug, assigns)

        assert rendered =~ "memory_* tool family"
        assert rendered =~ "Historian-only writes"
        assert rendered =~ "org/journal/<YYYY-MM-DD>.md"
        assert rendered =~ "private/<your-agent-id>"
      end
    end
  end

  describe "federation_preamble/0 (task 019f5e2a stage 1)" do
    test "returns a non-empty string" do
      preamble = PromptTemplates.federation_preamble()

      assert is_binary(preamble)
      assert byte_size(preamble) > 0
    end

    test "contains every canonical section header exactly once" do
      preamble = PromptTemplates.federation_preamble()

      headers = [
        "## Subagent-spawn discipline",
        "## Organization Context",
        "## Writing to Org Memory",
        "## Skill discovery — do this BEFORE you start executing",
        "## Submitting evidence for a manual_approval validation",
        "## Tool-name conventions (dot vs underscore)"
      ]

      for header <- headers do
        occurrences = preamble |> String.split(header) |> length() |> Kernel.-(1)

        assert occurrences == 1,
               "expected federation_preamble to contain #{inspect(header)} exactly once, got #{occurrences}"
      end
    end

    test "carries key phrases guarding against silent regressions" do
      preamble = PromptTemplates.federation_preamble()

      # Subagent-spawn discipline anchor
      assert preamble =~ "run_in_background: true",
             "subagent-spawn discipline must instruct spawning with run_in_background: true"

      # Org memory anchor
      assert preamble =~ "memory_search",
             "federation preamble must reference the memory_search tool"

      # Skill discovery anchor
      assert preamble =~ "skill_list",
             "skill-discovery section must reference the skill_list MCP tool"

      # Evidence workflow anchors
      assert preamble =~ "attachment.upload_start",
             "evidence workflow must reference the attachment.upload_start tool (dot form)"

      assert preamble =~ "review_request_create",
             "evidence workflow must reference the review_request_create tool"

      # Tool-name gotcha anchor
      assert preamble =~ "not in allowed bundles",
             "tool-name conventions must document the 'not in allowed bundles' gotcha"
    end

    test "is idempotent — two calls return byte-equal strings" do
      first = PromptTemplates.federation_preamble()
      second = PromptTemplates.federation_preamble()

      assert first == second,
             "federation_preamble/0 must be a compile-time-frozen string, not re-computed per call"
    end
  end

  describe "federation_preamble template contract (task 019f5e2a stage 4)" do
    # Cross-slug drift guards downstream stack members (B: scribe_completion,
    # D: triage_dispatch) reference in their own plans. Any new dispatch
    # template that opts into the federation preamble must declare it in
    # `variables:` AND embed the `{{federation_preamble}}` placeholder in
    # `content:` — either half alone is a silent regression.

    @stage3_retrofitted_dispatch_slugs ~w(
      dispatch.planning
      dispatch.in_progress
      dispatch.in_review
      dispatch.review_e2e
      dispatch.deploying
      dispatch.fallback
    )

    test "every descriptor declaring federation_preamble in variables must also embed {{federation_preamble}} in content" do
      offenders =
        PromptTemplates.default_templates()
        |> Enum.filter(fn descriptor ->
          "federation_preamble" in (descriptor.variables || [])
        end)
        |> Enum.reject(fn descriptor ->
          (descriptor.content || "") =~ "{{federation_preamble}}"
        end)
        |> Enum.map(& &1.slug)

      assert offenders == [],
             "Descriptor(s) declare federation_preamble in variables but do not embed " <>
               "{{federation_preamble}} in content: #{inspect(offenders)}. Either add the " <>
               "placeholder to content or drop the variable declaration."
    end

    test "the six retrofitted dispatch.* slugs all declare federation_preamble in variables" do
      missing =
        for slug <- @stage3_retrofitted_dispatch_slugs,
            descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug)),
            not is_nil(descriptor),
            "federation_preamble" not in (descriptor.variables || []),
            do: slug

      assert missing == [],
             "Dispatch slug(s) missing federation_preamble from variables list: #{inspect(missing)}. " <>
               "A refactor dropped the variable declaration; add it back or the drift guard is a lie."

      # Also assert every slug is actually a registered descriptor (guards
      # against a slug being renamed / removed silently).
      for slug <- @stage3_retrofitted_dispatch_slugs do
        assert Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug)),
               "expected #{slug} to be a registered default template"
      end
    end
  end

  describe "federation_preamble render round-trip (task 019f5e2a stage 5)" do
    # Per-slug fixture-render regression tests. Each dispatch.* template is
    # rendered with a minimally-viable assigns map (including a real
    # federation_preamble value) and every canonical section header is
    # asserted in the output. Also refutes any un-consumed `{{federation_preamble}}`
    # remnant. These are the guarantee that Stage 3's retrofit didn't drop
    # a placeholder in one slug or accidentally break the mustache
    # interpolation flow.

    @stage5_render_assigns %{
      task_id: "task-render-1",
      stage_id: "stage-render-1",
      task_title: "Render probe",
      task_description: "Render probe body",
      task_priority: "medium",
      task_status: "in_progress",
      task_slug: "renderp",
      stage_info: "Plan: v1 (stage 1/1 — coding)",
      git_workflow_block: "",
      provider_specific_guidance: "",
      previous_rejection_reason: "",
      upstream_plans_section: "",
      pending_e2e_validations_json: "[]",
      execution_space_id: "11111111-1111-1111-1111-111111111111",
      repo_url: "git@github.com:acme/widgets.git",
      default_branch: "main",
      deploy_strategy_type: "manual",
      deploy_strategy_config: "%{}"
    }

    @stage5_expected_headers [
      "## Subagent-spawn discipline",
      "## Organization Context",
      "## Writing to Org Memory",
      "## Skill discovery — do this BEFORE you start executing",
      "## Submitting evidence for a manual_approval validation",
      "## Tool-name conventions (dot vs underscore)"
    ]

    for slug <-
          ~w(dispatch.planning dispatch.in_progress dispatch.in_review dispatch.review_e2e dispatch.deploying dispatch.fallback) do
      @tag slug: slug
      test "#{slug} render includes all six federation-preamble section headers", %{slug: slug} do
        :ok = PromptTemplates.seed_defaults()

        assigns =
          Map.put(
            @stage5_render_assigns,
            :federation_preamble,
            PromptTemplates.federation_preamble()
          )

        assert {:ok, rendered} = PromptTemplates.render_template(slug, assigns)

        for header <- @stage5_expected_headers do
          assert rendered =~ header,
                 "#{slug} render must include #{inspect(header)} (via federation_preamble)"
        end

        refute rendered =~ "{{federation_preamble}}",
               "#{slug} render must fully consume the {{federation_preamble}} placeholder"
      end
    end
  end

  describe "default_content_for_slug/1 — dispatch.scribe_completion" do
    # Task 019f5e2a-9db7 (M2 of the meeting-to-tasks-pipeline stack). Codifies
    # the 5-card scribe canvas structure proven on the SXI 2026-07-13 meeting
    # (canvas id 019f5e0c-e6fc-7721-b6de-944302dcfc67). The descriptor is a
    # `dispatch.*` template so stack member M1's federation_preamble guard
    # applies: `federation_preamble` MUST appear in the variables list AND
    # `{{federation_preamble}}` MUST appear in the content body.
    @scribe_slug "dispatch.scribe_completion"
    @scribe_expected_variables ~w(
      space_id
      room_id
      transcript_id
      meeting_name
      execution_space_id
      federation_preamble
      skills_reference
    )
    @scribe_action_item_note_keys ~w(owner project_hint priority due_hint source_transcript_id)

    test "descriptor exists in default_templates with the expected variable declarations" do
      content = PromptTemplates.default_content_for_slug(@scribe_slug)
      assert is_binary(content), "#{@scribe_slug} must be registered in default_templates/0"

      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == @scribe_slug))
      assert descriptor, "#{@scribe_slug} descriptor must appear in default_templates/0"

      for var <- @scribe_expected_variables do
        assert var in descriptor.variables,
               "#{@scribe_slug}.variables must include #{inspect(var)}"
      end
    end

    test "content carries the {{federation_preamble}} placeholder (stack member M1 drift guard)" do
      # If a future edit copy-pastes the preamble text inline instead of
      # referencing it as a mustache slot, the render pipeline breaks (the
      # placeholder resolves to "" and the shared block goes missing). This
      # test is the descriptor-scoped guard promised in the task's
      # acceptance criterion #4.
      content = PromptTemplates.default_content_for_slug(@scribe_slug)

      assert content =~ "{{federation_preamble}}",
             "#{@scribe_slug} must embed the federation_preamble placeholder"
    end

    test "content ships the 5-card canvas structure with all five card headers and labels" do
      content = PromptTemplates.default_content_for_slug(@scribe_slug)

      for card_number <- ["Card 1", "Card 2", "Card 3", "Card 4", "Card 5"] do
        assert content =~ card_number,
               "#{@scribe_slug} must include #{card_number} header"
      end

      for card_label <- ["Summary", "Decisions", "Action items", "Open questions", "Provenance"] do
        assert content =~ card_label,
               "#{@scribe_slug} must include the '#{card_label}' card label"
      end
    end

    test "Card 3 documents the JSON note convention with every required key" do
      content = PromptTemplates.default_content_for_slug(@scribe_slug)

      # All five keys named in prose so the scribe knows the full schema.
      for key <- @scribe_action_item_note_keys do
        assert content =~ key,
               "#{@scribe_slug} Card 3 must document the '#{key}' JSON note key"
      end

      # A worked example fenced in a ```json block so the scribe has a
      # copy-paste template.
      assert content =~ "```json",
             "#{@scribe_slug} Card 3 must include a fenced ```json code block"
    end

    test "Card 3 JSON example parses via Jason.decode with all 5 required keys" do
      # Regression guard: the worked example must be valid JSON. A malformed
      # example teaches the scribe to emit malformed notes, and the triage
      # agent's downstream Jason.decode/1 pass will trip on every action item.
      content = PromptTemplates.default_content_for_slug(@scribe_slug)

      [_, json_block] = Regex.run(~r/```json\n(.*?)\n```/s, content)

      assert {:ok, parsed} = Jason.decode(json_block),
             "#{@scribe_slug} Card 3 fenced ```json block must parse via Jason.decode/1"

      parsed_keys = Map.keys(parsed) |> Enum.sort()
      expected_keys = Enum.sort(@scribe_action_item_note_keys)

      assert parsed_keys == expected_keys,
             "#{@scribe_slug} Card 3 JSON example keys #{inspect(parsed_keys)} must match #{inspect(expected_keys)}"
    end

    test "content names the dispatch_triage_attention post-canvas hook" do
      # The canvas alone is not the whole product — the triage hand-off is
      # what turns action items into tasks. If a future edit strips this
      # instruction, action items sit stranded on the canvas.
      content = PromptTemplates.default_content_for_slug(@scribe_slug)

      assert content =~ "dispatch_triage_attention",
             "#{@scribe_slug} must instruct the scribe to call dispatch_triage_attention/2 after canvas_create"
    end

    test "render_template fully interpolates every declared placeholder with sample assigns" do
      :ok = PromptTemplates.seed_defaults()

      federation_preamble_sample =
        "### Federation preamble\nYou are a Suite agent — read org memory, call skill_list yourself, use CDP at 127.0.0.1:9222 for evidence."

      skills_reference_sample = "## Skill discovery\nCall skill_list yourself."

      assigns = %{
        federation_preamble: federation_preamble_sample,
        space_id: "space-abc",
        room_id: "room-def",
        transcript_id: "txp-123",
        meeting_name: "SXI weekly",
        execution_space_id: "exec-999",
        skills_reference: skills_reference_sample
      }

      assert {:ok, rendered} = PromptTemplates.render_template(@scribe_slug, assigns)

      # Injected preamble + skills text made it through.
      assert rendered =~ "Federation preamble",
             "rendered #{@scribe_slug} must carry the interpolated federation_preamble text"

      assert rendered =~ "Call skill_list yourself.",
             "rendered #{@scribe_slug} must carry the interpolated skills_reference text"

      # Signal-payload values interpolated verbatim.
      assert rendered =~ "space-abc"
      assert rendered =~ "room-def"
      assert rendered =~ "txp-123"
      assert rendered =~ "SXI weekly"

      # No literal placeholders left in the rendered output.
      for placeholder <-
            ~w(federation_preamble skills_reference space_id room_id transcript_id meeting_name execution_space_id) do
        refute rendered =~ "{{#{placeholder}}}",
               "rendered #{@scribe_slug} must not carry a literal {{#{placeholder}}} placeholder"
      end
    end

    test "every dispatch.* slug that declares federation_preamble embeds the placeholder (cross-slug guard)" do
      # Parametric guard — walks every registered dispatch.* descriptor whose
      # variables list includes "federation_preamble" and asserts the content
      # embeds {{federation_preamble}}. Future dispatch templates that opt
      # into the shared preamble by declaring the variable can silently drop
      # the placeholder without this test; this catches that regression at
      # descriptor-registration time.
      for descriptor <- PromptTemplates.default_templates(),
          String.starts_with?(descriptor.slug, "dispatch."),
          "federation_preamble" in descriptor.variables do
        assert descriptor.content =~ "{{federation_preamble}}",
               "#{descriptor.slug} declares federation_preamble in .variables but does not embed {{federation_preamble}} in .content"
      end
    end
  end

  describe "meetings.intent_classify.v1 — correction exemplars (task 019f70b8 stage 6)" do
    # Unlike `dispatch.intent_attention`, this slug is NOT in
    # `default_templates/0` — its body has only ever lived in migrations
    # (20260707 seeded it, 20260709 added the context window, 20260726
    # adds the exemplar block). The DB ROW is therefore the production
    # artifact, and it is what these tests read: migrations have already
    # run by the time ExUnit boots.

    @intent_classify_slug "meetings.intent_classify.v1"
    @corrections_marker "# Prior producer corrections"
    @context_marker "# Prior conversation context"

    defp intent_classify_content do
      case PromptTemplates.get_template_by_slug(@intent_classify_slug) do
        nil -> flunk("#{@intent_classify_slug} must be seeded by migration before this test runs")
        template -> template.content
      end
    end

    # Slice the body between two section markers. Every assertion below
    # is scoped to the corrections SLICE rather than the whole body:
    # `correction`, `intent` and `producer` all occur elsewhere in this
    # prompt, so a whole-body `=~` would stay green even if the
    # exemplars section lost the `{{correction_exemplars}}` marker
    # entirely — which is the ONE thing in it that is load-bearing.
    defp intent_classify_section(content, from_marker, to_marker) do
      {from, _} = :binary.match(content, from_marker)
      {to, _} = :binary.match(content, to_marker)

      assert to > from,
             "expected #{inspect(from_marker)} to precede #{inspect(to_marker)}"

      binary_part(content, from, to - from)
    end

    test "the corrections section carries the {{correction_exemplars}} marker" do
      content = intent_classify_content()

      assert content =~ @corrections_marker,
             "the intent_classify prompt must carry a producer-corrections section"

      section = intent_classify_section(content, @corrections_marker, @context_marker)

      assert section =~ "{{correction_exemplars}}",
             "the corrections section must interpolate the exemplars variable"
    end

    test "the corrections section tells the model these outrank the generic guidance" do
      section =
        intent_classify_content()
        |> intent_classify_section(@corrections_marker, @context_marker)

      # Without this, exemplars are just more text competing with the
      # closed-enum guidance below them, and the tuning loop cannot move
      # the classifier off its defaults.
      assert section =~ "ground truth",
             "the corrections section must frame the exemplars as ground truth"

      assert section =~ "org",
             "the corrections section must say the corrections are org-scoped"
    end

    test "the corrections block precedes the prior-conversation window" do
      content = intent_classify_content()

      {corrections_at, _} = :binary.match(content, "{{correction_exemplars}}")
      {context_at, _} = :binary.match(content, "{{context_lines}}")
      {utterance_at, _} = :binary.match(content, "{{meeting_transcript_chunk}}")

      # Standing guidance first, then this conversation, then the thing
      # to classify. Reordering these silently changes what the model
      # weights most.
      assert corrections_at < context_at
      assert context_at < utterance_at
    end

    test "the prior-conversation window kept its do-not-classify framing" do
      # Regression guard: the stage-6 migration rewrites the WHOLE body,
      # so it is the obvious place to lose the 20260709 migration's work.
      content = intent_classify_content()

      assert content =~ "DO NOT classify these lines"
      assert content =~ "{{context_lines}}"
    end

    test "correction_exemplars is declared in the row's variables" do
      template = PromptTemplates.get_template_by_slug(@intent_classify_slug)

      assert "correction_exemplars" in template.variables

      # The pre-existing set must survive the rewrite too.
      for variable <- ~w(meeting_transcript_chunk context_lines context_present speaker room_id) do
        assert variable in template.variables,
               "the intent_classify template must keep declaring #{variable}"
      end
    end

    test "the migration is update-only — an absent row is skipped, not inserted" do
      # The seed migrations have already run by the time ExUnit boots, so
      # the row exists. Delete it inside this test's transaction (rolled
      # back on exit) to reach the branch that would otherwise never be
      # exercised.
      #
      # This migration deliberately does NOT insert: the 20260707 seed
      # created the row on every migrated environment, and a second
      # insert path would be a third copy of the body with no
      # environment that needs it.
      template = PromptTemplates.get_template_by_slug(@intent_classify_slug)
      {:ok, _} = PromptTemplates.delete_template(template)

      assert :ok = run_corrections_migration!()

      assert is_nil(PromptTemplates.get_template_by_slug(@intent_classify_slug)),
             "the migration must skip a missing row, not conjure one"
    end

    test "the migration is idempotent — re-running leaves the body byte-identical" do
      before_content = intent_classify_content()

      assert :ok = run_corrections_migration!()

      assert intent_classify_content() == before_content
    end

    # `apply/3` rather than a direct call: the migration module is loaded
    # at runtime by `setup_all`, so a compile-time reference produces an
    # "is undefined" warning on every build.
    defp run_corrections_migration! do
      apply(Platform.Repo.Migrations.UpdateIntentClassifyPromptWithCorrections, :up, [])
    end
  end

  # ── UUID boundary (task 019fa129 stage 4) ────────────────────────────────
  # The 16-character case is the load-bearing one: `Ecto.UUID.cast/1` accepts
  # any 16-byte binary, so a test built from "higgins" alone is green against
  # the bug these guards fix.
  describe "UUID boundary: get_template/1" do
    test "returns nil for a malformed id rather than raising" do
      assert PromptTemplates.get_template("higgins") == nil
      assert PromptTemplates.get_template("higginshigginsxx") == nil
    end
  end
end
