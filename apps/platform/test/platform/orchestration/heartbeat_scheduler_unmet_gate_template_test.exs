defmodule Platform.Orchestration.HeartbeatSchedulerUnmetGateTemplateTest do
  @moduledoc """
  Task `01a01b00` stage 1 — the RENDERED half of the unmet-gate branch defect.

  `dispatch_phase_unmet_gate_test.exs` pins the resolver's answer. This file
  pins what an agent actually RECEIVES, because the slug is only interesting
  insofar as it changes the body of the prompt.

  WHICH PATH THIS FILE EXERCISES: the seeded `dispatch.in_review` and
  `dispatch.review_e2e` DB rows. `PromptTemplates.render_template/2` is tried
  FIRST and the row wins in every migrated environment, so a body asserted
  only against the hardcoded fallback proves nothing about production. The
  setup rewrites both rows from the shipped descriptors before rendering, for
  determinism — the row in this database may predate the branch.

  ## The vacuity trap this file is written around — do not undo it

  The obvious assertion, "the prompt names the failed e2e validation's id", is
  WORTHLESS here. `review_contract/2` appends a "Review Validation Contract"
  block that enumerates EVERY validation on the stage regardless of status, so
  every validation id appears in the prompt on BOTH branches. Misreading that
  block is what produced this ticket's original, wrong root cause.

  The assertions below therefore key on a sentinel planted inside the
  validation's `evaluation_payload`. That payload reaches the prompt through
  exactly one route — `e2e_review_assigns/3` -> `pending_e2e_validations_json`
  -> the `dispatch.review_e2e` body — and through no other. `review_contract/2`
  prints ids and kinds, never payloads.

  Writes shared `prompt_templates` rows, so `async: false`.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplate
  alias Platform.Orchestration.PromptTemplates
  alias Platform.Repo

  # Both rows are reseeded: review_e2e is the subject, in_review is the
  # discrimination control and must render from a known body too.
  @slugs ["dispatch.in_review", "dispatch.review_e2e"]

  # LITERALS, lifted verbatim from `prompt_templates.ex`. Never recomputed by
  # calling the code under test — an expectation derived from the function
  # under test cannot fail for any value that function returns.
  @ui_judgment_opening "Task is in review — produce a human-judgment review request for the UI / manual_approval gate."
  @behavioural_opening "Task is in behavioral review — execute each planner-authored e2e_behavior test case"
  @pending_e2e_heading "## Pending e2e_behavior validations (pre-rendered as JSON)"

  # Reachable ONLY through pending_e2e_validations_json. See the moduledoc.
  @payload_sentinel "PAYLOAD-SENTINEL the renamed resources report only address moves"

  @execution_space_id "01a01b00-2256-7222-97c9-a6542794a1e2"

  setup do
    for slug <- @slugs do
      descriptor = Enum.find(PromptTemplates.default_templates(), &(&1.slug == slug))
      refute is_nil(descriptor), "the #{slug} descriptor must exist to be seeded"

      case Repo.get_by(PromptTemplate, slug: slug) do
        nil ->
          {:ok, _} = PromptTemplates.create_template(descriptor)

        existing ->
          {:ok, _} =
            PromptTemplates.update_template(existing, %{
              content: descriptor.content,
              variables: descriptor.variables
            })
      end
    end

    :ok
  end

  defp task_fixture do
    %{
      id: "01a01b00-184e-74bb-a970-0c93cacd98c0",
      title: "Migrate the staging stack into named modules",
      description: "Ticket body — planner-only material.",
      status: "in_review",
      priority: "medium",
      deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
      project: %{repo_url: "https://github.com/test/router", default_branch: "main"}
    }
  end

  # The live repro shape: lint and test gates already passed, the behavioural
  # gate came back FAILED and the stage was re-opened to `running`. Nothing is
  # at literal status "pending", which is the whole defect.
  defp failed_e2e_plan_and_stage(
         actions \\ "Run the plan in the staging root and read the summary line."
       ) do
    stage = %{
      id: "01a0180b-0625-74a2-b79d-9157457d4341",
      position: 4,
      status: "running",
      name: "Migrate the staging resources with moved blocks",
      description: "Move the live resources into named modules with state moves.",
      validations: [
        %{id: "val-lint-1", kind: "lint_pass", status: "passed"},
        %{id: "val-test-1", kind: "test_pass", status: "passed"},
        %{
          id: "val-e2e-1",
          kind: "e2e_behavior",
          status: "failed",
          evaluation_payload: %{
            "setup" => "Check out the task branch in a worktree.",
            "actions" => actions,
            "expected" => @payload_sentinel
          }
        }
      ]
    }

    {%{version: 2, stages: [%{}, %{}, %{}, stage]}, stage}
  end

  # The working case: a genuine UI gate at literal "pending". Must keep
  # rendering the UI-judgment body both before and after the fix.
  defp manual_approval_plan_and_stage do
    stage = %{
      id: "01a0180b-0625-74a2-b79d-9157457d4342",
      position: 4,
      status: "running",
      name: "Human gate",
      description: "A person judges the captured evidence.",
      validations: [
        %{id: "val-test-2", kind: "test_pass", status: "passed"},
        %{id: "val-manual-2", kind: "manual_approval", status: "pending"}
      ]
    }

    {%{version: 2, stages: [%{}, %{}, %{}, stage]}, stage}
  end

  describe "a stage whose only unmet gate is a FAILED e2e_behavior" do
    test "renders the behavioural body, not the UI-judgment one" do
      {plan, stage} = failed_e2e_plan_and_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage,
          execution_space_id: @execution_space_id
        )

      # PRESENT: the pending-e2e payload reached the agent.
      assert prompt =~ @pending_e2e_heading,
             "the seeded dispatch.review_e2e body must render its pending-e2e section"

      assert prompt =~ @payload_sentinel,
             "the failed e2e validation's evaluation_payload must reach the agent through " <>
               "pending_e2e_validations_json — the ONLY route that carries a payload"

      refute prompt =~ "{{pending_e2e_validations_json}}",
             "the placeholder must resolve, not render verbatim"

      # ABSENT: the reviewer was not sent to hunt for a UI gate that does not
      # exist on this stage. This stage's contract carries no manual_approval.
      refute prompt =~ @ui_judgment_opening,
             "the UI-judgment template must not be rendered for a stage with no " <>
               "manual_approval gate — this is the four-times-observed defect"

      assert prompt =~ @behavioural_opening
    end
  end

  describe "pending_e2e_validations_json is JSON and untruncated (task 01a0e25e)" do
    # The rendered-prompt half of the describe of the same name in
    # `heartbeat_scheduler_test.exs`. Before task 01a0e25e the block was
    # `inspect/1` output, which cut any string at 4096 bytes; the sentinel sits
    # at the tail of a 5,022-character actions string, so it only reaches the
    # prompt if neither the assign nor the seeded template's interpolation
    # truncates it.
    @tail_sentinel "TAIL-SENTINEL-01a0e25e"

    test "a >4096-byte actions string reaches the rendered prompt whole" do
      {plan, stage} = failed_e2e_plan_and_stage(String.duplicate("a", 5000) <> @tail_sentinel)

      prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage,
          execution_space_id: @execution_space_id
        )

      assert prompt =~ @pending_e2e_heading
      assert prompt =~ String.duplicate("a", 5000) <> @tail_sentinel
      assert prompt =~ @tail_sentinel
    end
  end

  describe "CONTROL — the discrimination the case above rests on" do
    test "a PENDING manual_approval stage does render the UI-judgment body" do
      # GREEN TODAY AND AFTER THE FIX, on purpose, and untagged so it runs in
      # the default suite. Two jobs:
      #
      #   1. It proves the @ui_judgment_opening literal is actually reachable.
      #      Without it, the `refute` above could pass because the sentinel is
      #      a typo that no prompt ever contains — a refutation of nothing.
      #   2. It is the regression guard: widening "unmet" must move the e2e
      #      case and leave this one exactly where it is.
      {plan, stage} = manual_approval_plan_and_stage()

      prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture(), plan, stage,
          execution_space_id: @execution_space_id
        )

      assert prompt =~ @ui_judgment_opening,
             "the literal the failed-e2e case refutes must be reachable, or that " <>
               "refutation proves nothing"

      refute prompt =~ @pending_e2e_heading
      refute prompt =~ @payload_sentinel
    end

    test "the Review Validation Contract names every validation id on BOTH branches" do
      # Pins the trap explicitly so nobody re-derives the wrong root cause
      # from it, and so nobody "strengthens" the case above by asserting on a
      # validation id. `review_contract/2` enumerates all validations
      # regardless of status; its output is NOT evidence about what is open.
      {e2e_plan, e2e_stage} = failed_e2e_plan_and_stage()
      {ui_plan, ui_stage} = manual_approval_plan_and_stage()

      e2e_prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture(), e2e_plan, e2e_stage,
          execution_space_id: @execution_space_id
        )

      ui_prompt =
        HeartbeatScheduler.dispatch_prompt(task_fixture(), ui_plan, ui_stage,
          execution_space_id: @execution_space_id
        )

      # The failed e2e validation's id appears even on today's mis-routed
      # in_review render — which is exactly why it cannot be the assertion.
      assert e2e_prompt =~ "val-e2e-1"
      assert e2e_prompt =~ "val-lint-1"
      assert ui_prompt =~ "val-manual-2"
    end
  end
end
