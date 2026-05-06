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
end
