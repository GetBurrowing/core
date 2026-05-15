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

    test "evidence-capture step routes through hive-local CDP, not rock-node-screenshot" do
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
end
