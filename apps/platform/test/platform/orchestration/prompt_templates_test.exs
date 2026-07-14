defmodule Platform.Orchestration.PromptTemplatesTest do
  @moduledoc """
  Asserts that the seeded prompt templates carry the e2e_behavior + manual_approval
  guidance that downstream stages (planner output, dispatch routing) depend on.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.PromptTemplates

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

    test "carries the Design involvement section — detection, brand cascade, advisory Saru stage (task 019f4f1d)" do
      # First applied live via prompt_template_update on 2026-07-11 and
      # upstreamed here so force-update migrations preserve it. The section
      # must (a) detect UI/UX tasks beyond file tokens, (b) resolve brand
      # context project → org with a once-per-project three-way human ask,
      # and (c) add an advisory (never blocking) Saru design stage.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "Design involvement (UI/UX tasks)"
      assert content =~ "looks, feels, moves, or is interacted with"

      # Brand cascade + the three-way escalation, recorded once per project.
      assert content =~ "Resolve brand context"
      assert content =~ ~r/project-level overrides and extends org-level/i
      assert content =~ "ONCE per project"
      assert content =~ "exploring — no identity yet"
      assert content =~ "never blocks development"

      # Advisory design stage: explicitly advise-only, no manual_approval gate.
      assert content =~ "Design direction (Saru)"
      assert content =~ "advise-only"
      assert content =~ "Do NOT attach manual_approval to it"
    end

    test "teaches planners to route the Design-direction stage via responsibility (task 019f5d47)" do
      # Stage-level responsibility routing (stage 5): the code default
      # for dispatch.planning must instruct planners to set
      # responsibility: "designer" on the advisory Design-direction
      # stage so TaskRouter.do_dispatch/2 can resolve the current
      # designer via Platform.Roles.agent_id_for_role/1 and route that
      # single stage's prompt to Saru's runtime — with a soft fallback
      # to the phase assignee when the role is unassigned or the
      # runtime is offline.
      content = PromptTemplates.default_content_for_slug("dispatch.planning")

      assert content =~ "responsibility: \"designer\""
      assert content =~ "Platform.Roles.agent_id_for_role/1"
      assert content =~ "Route this stage to Saru automatically"
      assert content =~ "Do NOT hardcode an agent_id"
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

    test "evidence-capture step routes through hive-local CDP" do
      # The capture step is interpolated from HeartbeatScheduler's
      # @evidence_workflow_reference into dispatch.in_progress and
      # dispatch.in_review. Asserting on the rendered dispatch prompt is
      # done in heartbeat_scheduler_test; here we check the template
      # itself still names the placeholder so the evidence-workflow text
      # actually reaches the agent.
      content = PromptTemplates.default_content_for_slug("dispatch.in_review")

      assert content =~ "{{evidence_workflow_reference}}",
             "dispatch.in_review must keep the evidence_workflow_reference placeholder"
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
    test "carries the evidence_workflow_reference placeholder for the CDP capture step" do
      content = PromptTemplates.default_content_for_slug("dispatch.in_progress")
      assert is_binary(content)

      assert content =~ "{{evidence_workflow_reference}}",
             "dispatch.in_progress must keep the evidence_workflow_reference placeholder"
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
        skills_reference: "Use bundled skills.",
        evidence_workflow_reference: "CDP capture at 127.0.0.1:9222"
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
        skills_reference: "Use bundled skills.",
        evidence_workflow_reference: "CDP capture at 127.0.0.1:9222"
      }

      assert {:ok, rendered} = PromptTemplates.render_template("dispatch.in_progress", assigns)

      assert rendered =~
               "git worktree add ../worktrees/019e2474-11c1-7000-8000-000000000001 -b task/019e2474-11c1-7000-8000-000000000001"

      assert rendered =~ "## Task Stack Membership"
      assert rendered =~ "stack_id: `019e2782-09d6-7e2c-9502-c106290e5add`"
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
        skills_reference: "Use bundled skills."
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
    test "seed_defaults seeds dispatch.planning with current default content" do
      :ok = PromptTemplates.seed_defaults()

      template = PromptTemplates.get_template_by_slug("dispatch.planning")
      assert template

      expected = PromptTemplates.default_content_for_slug("dispatch.planning")
      assert template.content == expected
    end
  end

  describe "skill-discovery step in dispatch templates" do
    # Two groups of dispatch templates carry the skill guidance differently:
    #
    #  * `dispatch.fallback` bakes the prompt_templates.ex `skills_reference`
    #    local directly into its `content` via `#{...}` interpolation, so the
    #    discovery text is present in `default_content_for_slug/1` verbatim.
    #  * `dispatch.planning` / `.in_progress` / `.in_review` / `.review_e2e`
    #    carry a `{{skills_reference}}` placeholder; the discovery text is
    #    supplied at render time (HeartbeatScheduler passes `@skills_reference`).
    #    For those, `default_content_for_slug/1` shows the placeholder and
    #    `render_template/2` shows the interpolated text.
    #
    # heartbeat_scheduler_test.exs covers the end-to-end content on the
    # hardcoded fallback path.
    @placeholder_slugs ~w(
      dispatch.planning
      dispatch.in_progress
      dispatch.in_review
      dispatch.review_e2e
    )
    @all_dispatch_slugs ["dispatch.fallback" | @placeholder_slugs]

    # Mirrors the prompt_templates.ex `skills_reference` local, used as the
    # render-time assign so the test exercises the real interpolation path
    # for the placeholder slugs.
    @skills_reference_text "## Skill discovery — do this BEFORE you start executing\n\n" <>
                             "Derive this task's domain. Call the `skill_list` MCP tool yourself. " <>
                             "Call the `skill_get` MCP tool. " <>
                             "Discovery happens by calling `skill_list` / `skill_get` yourself."

    test "dispatch.fallback bakes the skill-discovery step directly into its content" do
      # dispatch.fallback interpolates the prompt_templates.ex `skills_reference`
      # local with `#{...}`, so the discovery text is present verbatim — this
      # directly asserts the Stage-1 edit to that local landed.
      content = PromptTemplates.default_content_for_slug("dispatch.fallback")
      assert is_binary(content)

      assert content =~ "skill_list",
             "expected dispatch.fallback to name the skill_list tool"

      assert content =~ "skill_get",
             "expected dispatch.fallback to name the skill_get tool"

      assert content =~ "Derive this task's domain",
             "expected dispatch.fallback to carry the discovery-instruction fragment"

      assert content =~ "Skill discovery",
             "expected dispatch.fallback to carry the skill-discovery section header"

      # Regression guard — discovery must be active tool calls, not a skills-key read.
      refute content =~ "check the `skills` key"
      refute content =~ "check the skills key"
      refute content =~ "read the attached skills object"

      assert content =~ "calling `skill_list` / `skill_get` yourself",
             "dispatch.fallback discovery must direct the agent to call the tools itself"
    end

    test "every placeholder dispatch slug wires the {{skills_reference}} placeholder" do
      for slug <- @placeholder_slugs do
        content = PromptTemplates.default_content_for_slug(slug)
        assert is_binary(content), "expected #{slug} to be a registered template"

        assert content =~ "{{skills_reference}}",
               "expected #{slug} to interpolate the skills_reference placeholder"
      end
    end

    test "every dispatch slug declares skills_reference as a template variable" do
      for slug <- @all_dispatch_slugs do
        descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))
        assert descriptor, "expected #{slug} to be a registered default template"

        assert "skills_reference" in descriptor.variables,
               "expected #{slug} to declare skills_reference as a variable"
      end
    end

    test "render_template interpolates the skill-discovery step into placeholder slugs" do
      :ok = PromptTemplates.seed_defaults()

      assigns = %{
        task_title: "Wire up the task-stack detail panel",
        task_description: "Add a panel showing stack members",
        task_priority: "medium",
        task_id: "abcd1234",
        task_slug: "abcd1234",
        execution_space_id: "11111111-1111-1111-1111-111111111111",
        repo_url: "git@github.com:acme/widgets.git",
        plan_version: 1,
        stage_name: "coding",
        stage_position: 1,
        validations_summary: "test_pass, lint_pass",
        skills_reference: @skills_reference_text
      }

      for slug <- @placeholder_slugs do
        assert {:ok, rendered} = PromptTemplates.render_template(slug, assigns)

        assert rendered =~ "skill_list",
               "expected rendered #{slug} to carry skill_list after {{skills_reference}} interpolation"

        assert rendered =~ "skill_get",
               "expected rendered #{slug} to carry skill_get after {{skills_reference}} interpolation"

        assert rendered =~ "Derive this task's domain",
               "expected rendered #{slug} to carry the discovery-instruction fragment"

        # The placeholder must be fully consumed — no literal {{skills_reference}}
        # left in the rendered output.
        refute rendered =~ "{{skills_reference}}",
               "expected #{slug} to fully interpolate the skills_reference placeholder"
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
        task_id: "abcd1234",
        task_slug: "abcd1234",
        execution_space_id: "11111111-1111-1111-1111-111111111111",
        repo_url: "git@github.com:acme/widgets.git",
        skills_reference: @skills_reference_text
      }

      for slug <- @placeholder_slugs do
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

    test "content carries the three concern-kind anchors + additive contract" do
      content = PromptTemplates.default_content_for_slug("architecture.review_plan.v1")

      # The three concern kinds the architect flags.
      assert content =~ "collision"
      assert content =~ "adr_drift"
      assert content =~ "dup_abstraction"

      # The additive-not-blocking contract.
      assert content =~ "additive" or content =~ "not a blocker"
      assert content =~ "do not block plan approval" or content =~ "does NOT block"
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

  describe "journal-by-default rule on dispatch.planning + dispatch.in_progress (T6)" do
    # T6 adds a "Journal-by-default for non-Historian agents" rule to the
    # two dispatch slugs used by non-Historian agents, making the
    # `<correction target="<page-path>" line="<N>">…</correction>`
    # convention authoritative copy. The 5/15 force-update migration
    # (20260520050000) refreshes these rows post-deploy so prod picks up
    # the new rule even when seed_defaults short-circuits.

    @non_historian_dispatch_slugs ~w(dispatch.planning dispatch.in_progress)

    test "dispatch.planning + dispatch.in_progress carry the journal-by-default rule" do
      for slug <- @non_historian_dispatch_slugs do
        content = PromptTemplates.default_content_for_slug(slug)

        assert is_binary(content), "#{slug} should have default content"

        assert content =~ "Journal-by-default for non-Historian agents",
               "#{slug} must carry the 'Journal-by-default' section header"

        assert content =~ "<correction target=",
               "#{slug} must document the <correction target=...> block convention"

        assert content =~ ":historian_only",
               "#{slug} must name the :historian_only error code agents will see"

        # Direct page writes by non-Historian agents are explicitly
        # forbidden — the prohibition must be present, not implied.
        assert content =~ "never call `memory_str_replace`" or
                 content =~ "never call memory_str_replace",
               "#{slug} must explicitly forbid calling memory_str_replace against page paths"
      end
    end

    test "dispatch.planning + dispatch.in_progress retain the existing memory_* path routing block" do
      # Guard against an over-eager edit that removes the path-routing
      # block (the cross-task contract with T5's tool surface) while
      # adding the journal-by-default rule on top.
      for slug <- @non_historian_dispatch_slugs do
        content = PromptTemplates.default_content_for_slug(slug)

        assert content =~ "memory_* tool family"
        assert content =~ "Historian-only writes"
        assert content =~ "org/journal/<YYYY-MM-DD>.md"
        assert content =~ "private/<your-agent-id>"
      end
    end
  end
end
