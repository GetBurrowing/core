defmodule Platform.Orchestration.DispatchPhaseRoutingTest do
  @moduledoc """
  Stage 2 of task `019fa469` — `HeartbeatScheduler.dispatch_prompt/4` selects
  its template from the STAGE's contract via `DispatchPhase`, not from the
  stale `task.status`.

  ## What is being pinned

  DEFECT 1 and its unrecorded deploy-stage variant:

    * A stage that is `running` with only `test_pass` / `lint_pass` pending got
      the `dispatch.in_review` body because `task.status` still read
      `"in_review"` from the previous stage's approved `manual_approval` gate.
      Observed 3x on task `019f9b29-9c47-7b66-b863-641b50d09eff` stages 3 / 4.
    * A DEPLOY stage whose sole validation was `pr_merged` also got the review
      body (task `019fa230`) — which is why the fix classifies on the stage
      contract rather than patching the `in_review` head.

  ## Anti-vacuity

  Every `refute ... =~` here is paired with a positive `assert ... =~` on a
  string unique to the template we DO expect, plus a `String.length/1` floor.
  An errored or empty render therefore fails the positive assertion instead of
  passing the negative one by absence. This is mandated for this task because
  every assertion in the file is a substring match on rendered output.

  ## Template rows are forced to shipped content

  `PromptTemplates.seed_defaults/0` is skip-if-exists, so a stale seeded row
  would silently make these assertions test yesterday's copy. Setup rewrites
  each dispatch slug's `content` from `default_content_for_slug/1` — mirroring
  `heartbeat_scheduler_federation_preamble_test.exs:38-55`.
  """
  use Platform.DataCase, async: false

  alias Platform.Orchestration.DispatchPhase
  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Orchestration.PromptTemplates

  @forced_slugs ~w(dispatch.in_progress dispatch.in_review dispatch.review_e2e dispatch.deploying)

  # Anchors unique to one template body each.
  @in_progress_anchor "Plan approved — execute the current stage."
  @in_review_anchor "Task is in review — produce a human-judgment review request"
  @deploying_anchor "Task is deploying — execute the deploy stage based on the resolved strategy."

  setup do
    :ok = PromptTemplates.seed_defaults()

    for slug <- @forced_slugs do
      template = PromptTemplates.get_template_by_slug(slug)
      refute is_nil(template), "expected #{slug} to be seeded"

      {:ok, _} =
        PromptTemplates.update_template(template, %{
          content: PromptTemplates.default_content_for_slug(slug)
        })
    end

    :ok
  end

  defp project, do: %{repo_url: "https://github.com/test/router", default_branch: "main"}

  defp plan, do: %{version: 1, stages: [%{}, %{}]}

  describe "stale task.status no longer selects the template" do
    test "a running stage with pending test_pass + lint_pass gets the EXECUTION dispatch even though task.status is in_review" do
      task = %{
        id: "019fa469-0000-7000-8000-00000000da01",
        title: "Stale-status execution stage",
        description: "The previous stage's manual_approval gate was just approved.",
        status: "in_review",
        priority: "high",
        project: project()
      }

      stage = %{
        id: "019fa469-0000-7000-8000-00000000da02",
        position: 2,
        name: "Implement the resolver cutover",
        status: "running",
        validations: [
          %{id: "val-test", kind: "test_pass", status: "pending"},
          %{id: "val-lint", kind: "lint_pass", status: "pending"}
        ]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), stage)

      refute output =~ @in_review_anchor,
             "an executor stage must not receive the reviewer preamble"

      assert output =~ @in_progress_anchor,
             "an executor stage must receive the execution dispatch"

      assert String.length(output) > 200,
             "render collapsed to #{String.length(output)} chars — the refute above would pass vacuously"
    end

    test "a mixed manual_approval + test_pass stage still routes to execution — the work lands before the gate" do
      task = %{
        id: "019fa469-0000-7000-8000-00000000da03",
        title: "Mixed-contract stage",
        description: "Gate and implementation pending together.",
        status: "in_review",
        priority: "medium",
        project: project()
      }

      stage = %{
        id: "019fa469-0000-7000-8000-00000000da04",
        position: 1,
        name: "Build the panel",
        status: "running",
        validations: [
          %{id: "val-manual", kind: "manual_approval", status: "pending"},
          %{id: "val-test", kind: "test_pass", status: "pending"}
        ]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), stage)

      refute output =~ @in_review_anchor
      assert output =~ @in_progress_anchor
      assert String.length(output) > 200
    end

    test "a manual_approval-ONLY stage still routes to the reviewer" do
      task = %{
        id: "019fa469-0000-7000-8000-00000000da05",
        title: "Genuine review stage",
        description: "Only a human gate remains.",
        status: "in_progress",
        priority: "medium",
        project: project()
      }

      stage = %{
        id: "019fa469-0000-7000-8000-00000000da06",
        position: 3,
        name: "Review the panel",
        status: "running",
        validations: [
          %{id: "val-test", kind: "test_pass", status: "passed"},
          %{id: "val-manual", kind: "manual_approval", status: "pending"}
        ]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), stage)

      refute output =~ @in_progress_anchor,
             "a gate-only stage must not receive the execution dispatch"

      assert output =~ @in_review_anchor
      assert String.length(output) > 200
    end
  end

  describe "deploy stages are selected from the stage contract" do
    test "a pr_merged-only deploy stage gets the DEPLOY dispatch even though task.status is in_review" do
      task = %{
        id: "019fa469-0000-7000-8000-00000000db01",
        title: "Deploy after stale review status",
        description: "Ship it.",
        status: "in_review",
        priority: "high",
        deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}},
        project: project()
      }

      stage = %{
        id: "019fa469-0000-7000-8000-00000000db02",
        position: 2,
        name: "Deploy: PR merge",
        status: "running",
        validations: [%{id: "val-pr", kind: "pr_merged", status: "pending"}]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), stage)

      refute output =~ "produce a human-judgment review request",
             "a deploy stage must not receive the reviewer preamble"

      assert output =~ @deploying_anchor
      assert output =~ "pr_merge"
      assert String.length(output) > 200
    end

    # The kind table alone is NOT sufficient here: `DeployStageBuilder`
    # emits `manual_approval` for the `manual` and `skill_driven` strategies
    # and `test_pass` for `project_files`. Classifying purely on pending kinds
    # would route those to the reviewer / executor template — a regression the
    # old `task.status == "deploying"` head did not have. `DispatchPhase`
    # therefore also recognises a system-injected deploy stage by its
    # `DeployStageBuilder`-minted name prefix.
    for {strategy_type, stage_name, kind} <- [
          {"manual", "Deploy: Manual", "manual_approval"},
          {"skill_driven", "Deploy: Skill execution", "manual_approval"},
          {"project_files", "Deploy: Project files", "test_pass"}
        ] do
      test "a #{strategy_type} deploy stage (sole pending #{kind}) still gets the DEPLOY dispatch" do
        task = %{
          id: "019fa469-0000-7000-8000-00000000db03",
          title: "Deploy via #{unquote(strategy_type)}",
          description: "Ship it.",
          status: "in_review",
          priority: "medium",
          deploy_strategy: %{"type" => unquote(strategy_type), "config" => %{}},
          project: project()
        }

        stage = %{
          id: "019fa469-0000-7000-8000-00000000db04",
          position: 2,
          name: unquote(stage_name),
          status: "running",
          validations: [%{id: "val-1", kind: unquote(kind), status: "pending"}]
        }

        output = HeartbeatScheduler.dispatch_prompt(task, plan(), stage)

        refute output =~ @in_review_anchor
        refute output =~ @in_progress_anchor
        assert output =~ @deploying_anchor
        assert String.length(output) > 200
      end
    end

    # Negative control against re-introducing `TaskRouter.infer_stage_type/1`'s
    # case-insensitive SUBSTRING match on the stage name. A planner-authored
    # implementation stage whose name merely CONTAINS "deploy" must still be
    # routed by its contract.
    test "a planner-authored stage whose name contains 'deploy' is NOT treated as a deploy stage" do
      task = %{
        id: "019fa469-0000-7000-8000-00000000db05",
        title: "Refactor the deployer",
        description: "Implementation stage, not a deploy stage.",
        status: "in_review",
        priority: "medium",
        project: project()
      }

      stage = %{
        id: "019fa469-0000-7000-8000-00000000db06",
        position: 1,
        name: "Rework the deploy strategy resolver",
        status: "running",
        validations: [%{id: "val-test", kind: "test_pass", status: "pending"}]
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), stage)

      refute output =~ @deploying_anchor,
             "name-substring matching must not classify an implementation stage as a deploy stage"

      assert output =~ @in_progress_anchor
      assert String.length(output) > 200
    end
  end

  describe "a stage-less dispatch no longer fabricates a stage-scoped body" do
    # DELIBERATE BEHAVIOUR CHANGE, carried to stage 4. The old
    # `%{status: "in_progress"}` head rendered the full execution contract with
    # `stage_id: ""` when `current_running_stage/1` returned nil — half of
    # defect 4 (the other half being the `Stage 1/N` label). `DispatchPhase`
    # rule 3 routes that to `dispatch.fallback` instead, and sets
    # `requires_stage?: true` so stage 4's router guard declines to send it at
    # all. Both stages ship on the same branch, so no dispatch is ever
    # observed in this intermediate shape.
    test "in_progress with no running stage renders the generic fallback, not the execution contract" do
      task = %{
        id: "019fa469-0000-7000-8000-00000000dc01",
        title: "No running stage",
        description: "current_running_stage/1 returned nil.",
        status: "in_progress",
        priority: "medium",
        project: project()
      }

      output = HeartbeatScheduler.dispatch_prompt(task, plan(), nil)

      refute output =~ @in_progress_anchor,
             "a stage-less dispatch must not render a stage-scoped execution contract"

      assert output =~ "No running stage"
      assert String.length(output) > 200

      phase = DispatchPhase.resolve(task, plan(), nil)
      assert phase.slug == "dispatch.fallback"
      assert phase.ack_mode == :none

      assert phase.requires_stage?,
             "stage 4's guard reads this flag to decline the dispatch — see the DispatchPhase moduledoc"
    end
  end

  describe "select_review_template/2 delegates its classification to DispatchPhase" do
    test "the e2e-vs-manual decision agrees with DispatchPhase.phase_for_pending/1 on every shape" do
      shapes = [
        [%{id: "v1", kind: "manual_approval", status: "pending"}],
        [%{id: "v1", kind: "e2e_behavior", status: "pending", evaluation_payload: %{}}],
        [
          %{id: "v1", kind: "manual_approval", status: "pending"},
          %{id: "v2", kind: "e2e_behavior", status: "pending", evaluation_payload: %{}}
        ]
      ]

      for pending <- shapes do
        {slug, _assigns} = HeartbeatScheduler.select_review_template(pending, nil)

        expected =
          case DispatchPhase.phase_for_pending(pending) do
            :review_e2e -> "dispatch.review_e2e"
            _ -> "dispatch.in_review"
          end

        assert slug == expected,
               "select_review_template/2 disagreed with DispatchPhase on #{inspect(pending)}"
      end
    end

    test "the empty-pending direct-call return is preserved as dispatch.in_review" do
      # Documented divergence: DispatchPhase falls through to `task.status` for
      # an empty pending list, but the direct-call contract of
      # `select_review_template/2` predates the resolver and is unit-tested.
      assert {"dispatch.in_review", %{}} = HeartbeatScheduler.select_review_template([])
      assert DispatchPhase.phase_for_pending([]) == nil
    end
  end
end
