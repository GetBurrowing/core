defmodule PlatformWeb.GithubWebhookCiScopingTest do
  @moduledoc """
  A CI result belongs to the repository that ran it, and it authorizes a
  merge in that repository ONLY.

  The ticket's one hard constraint is "do not make the deploy stage merge a
  second PR without CI gating it independently — a green CI in repo A says
  nothing about repo B". Before stage 4 the code did exactly that and it was
  not subtle: `process_ci_event/6` never read `params["repository"]`,
  `find_pending_ci_validation/1` took the FIRST pending `ci_passed` on the
  running stage with `limit: 1`, and the auto-merge it triggered resolved its
  target as `task.project.repo_url`. Three separate places where "which
  repository?" was answered by position or by the project rather than by the
  delivery.

  ## Test-design note (a stage-3 lesson, applied)

  Stage 3 found four of its ten regression tests passing against the parent
  by coincidence of gate ordering: deliver repo A first and "the first
  pending row" happens to BE repo A's row, so a positional lookup looks
  correct. Every pin below therefore delivers from the repository declared
  SECOND, where the positional answer and the correct answer differ. The
  same-direction cases are kept and labelled as the weaker half of the pair
  rather than dropped — a control that cannot detonate is still worth
  keeping, but it must not be mistaken for the pin.

  ## Why the fixture carries `ci_passed` gates at all

  A `pr_merge` deploy stage mints only `pr_merged` gates, so
  `process_ci_event/7` finds nothing and the auto-merge trigger is
  unreachable. The gates that make it reachable are planner- or
  operator-authored `ci_passed` rows on the running stage — that is the only
  shape in which auto-merge fires today, and so it is the shape under test.
  """

  use PlatformWeb.ConnCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation

  @github_webhook_path "/api/webhooks/github"

  @core "Startup-Suite/core"
  @bridge "Startup-Suite/claude-code-suite-channel"
  @undeclared "Startup-Suite/openclaw-suite-channel"

  # ── Fixtures ─────────────────────────────────────────────────────────────

  # Drives the real deploy-stage injection path so the `pr_merged` gates under
  # test are the ones production mints, then adds one `ci_passed` gate per
  # repository to the same running stage.
  #
  # STRATEGY-LEVEL `auto_merge` IS FALSE and the per-entry `config` turns it
  # on. That is not incidental: `should_auto_merge?/1` — the only reader that
  # existed before this stage — reads the strategy-level value, so the parent
  # tree takes the "auto-merge is off" branch and never shells out to `gh`
  # during these tests. The per-repo decision is expressed exactly where this
  # stage says it lives, on the entry.
  defp two_repo_task!(repos) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "CI Scoping #{System.unique_integer([:positive])}",
        # The PROJECT repo is core, and core is declared FIRST. Any pin that
        # delivers from the bridge therefore distinguishes three answers at
        # once: the delivering repo, the first gate, and the project's repo.
        repo_url: "https://github.com/#{@core}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Lands in two repositories",
        status: "in_progress",
        deploy_target: "production",
        deploy_strategy: %{
          "type" => "pr_merge",
          "config" => %{"auto_merge" => false},
          "repos" => repos
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved"})
    {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(s1.id)
    {:ok, plan} = PlanEngine.advance(plan.id)

    deploy_stage = Enum.find(plan.stages, &(&1.name == "Deploy: PR merge"))

    ci_gates =
      Map.new([@core, @bridge], fn slug ->
        {:ok, validation} =
          Tasks.create_validation(%{
            stage_id: deploy_stage.id,
            kind: "ci_passed",
            evaluation_payload: %{"repo" => slug}
          })

        {slug, validation}
      end)

    %{project: project, task: task, plan: plan, deploy_stage: deploy_stage, ci_gates: ci_gates}
  end

  # core gates on CI; the bridge repo has none. This is the real shape:
  # verified 2026-07-31, `Startup-Suite/core` has two webhooks installed and
  # `Startup-Suite/claude-code-suite-channel` has zero, so no `check_suite`
  # can ever be delivered from the bridge.
  #
  # The bridge entry deliberately does NOT set `auto_merge: true`:
  # `DeployStageBuilder.validate_strategy/1` (stage 2) refuses that
  # combination at write time. `{:no, :no_ci_to_gate}` is reached anyway —
  # `should_auto_merge?/2` checks `ci` BEFORE `auto_merge`, so a repository
  # with no CI is never machine-merged whatever the flag says. The
  # both-flags-on form is pinned as a unit test in `AutoMergerTest`, which
  # can construct the state the changeset refuses to store.
  defp two_repo_task! do
    two_repo_task!([
      %{
        "repo_url" => "https://github.com/#{@core}",
        "ci" => "required",
        "config" => %{"auto_merge" => false}
      },
      %{"repo_url" => @bridge, "ci" => "none"}
    ])
  end

  defp check_suite_payload(task, repo_full_name, conclusion \\ "success") do
    %{
      "action" => "completed",
      "check_suite" => %{
        "head_branch" => "task/#{task.id}",
        "conclusion" => conclusion,
        "head_sha" => "sha-#{System.unique_integer([:positive])}",
        "url" => "https://api.github.com/repos/#{repo_full_name}/check-suites/1"
      },
      "repository" => %{
        "full_name" => repo_full_name,
        "html_url" => "https://github.com/#{repo_full_name}"
      }
    }
  end

  defp workflow_run_payload(task, repo_full_name) do
    %{
      "action" => "completed",
      "workflow_run" => %{
        "head_branch" => "task/#{task.id}",
        "conclusion" => "success",
        "head_sha" => "sha-#{System.unique_integer([:positive])}",
        "html_url" => "https://github.com/#{repo_full_name}/actions/runs/1"
      },
      "repository" => %{
        "full_name" => repo_full_name,
        "html_url" => "https://github.com/#{repo_full_name}"
      }
    }
  end

  defp gates(stage_id, kind) do
    stage_id |> Tasks.list_validations() |> Enum.filter(&(&1.kind == kind))
  end

  defp gate_for(stage_id, kind, repo) do
    Enum.find(gates(stage_id, kind), &(get_in(&1.evaluation_payload || %{}, ["repo"]) == repo))
  end

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)
  defp reload(%Stage{id: id}), do: Repo.get!(Stage, id)

  defp attach(event) do
    handler_id = "ci-scoping-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      event,
      fn _event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  # ── Which ci_passed gate does a CI run satisfy? ──────────────────────────

  describe "a check_suite delivered from one repository of a two-repo deploy" do
    # THE PIN. Delivering from the repository declared SECOND is what
    # separates "the gate for the repo that ran the CI" from "the first
    # pending gate on the stage". `find_pending_ci_validation/1` answered the
    # latter, so the bridge's green marked CORE as green.
    test "passes only that repository's ci_passed gate", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      # ANTI-VACUITY: this is a live deploy with real gates, not a task that
      # never reached one.
      assert deploy_stage.status == "running"
      assert Tasks.get_task_record(task.id).status == "deploying"
      assert length(gates(deploy_stage.id, "ci_passed")) == 2
      assert length(gates(deploy_stage.id, "pr_merged")) == 2

      conn = signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @bridge))

      assert %{"result" => "passed", "validation_id" => id} = json_response(conn, 201)
      assert id == gate_for(deploy_stage.id, "ci_passed", @bridge).id

      assert gate_for(deploy_stage.id, "ci_passed", @bridge).status == "passed"

      assert gate_for(deploy_stage.id, "ci_passed", @core).status == "pending",
             "a green in the bridge repo must not mark core's CI as green"

      assert reload(deploy_stage).status == "running"
    end

    # The same claim delivered from the FIRST repo. This one passes against
    # the parent by coincidence — the positional answer and the correct
    # answer agree here — and is kept as the both-directions half of the pair,
    # not as a pin.
    test "passes the first repository's gate when the first repository delivers", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      conn = signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @core))

      assert %{"result" => "passed"} = json_response(conn, 201)
      assert gate_for(deploy_stage.id, "ci_passed", @core).status == "passed"
      assert gate_for(deploy_stage.id, "ci_passed", @bridge).status == "pending"
    end

    test "records the delivering repository in the CI evidence", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @bridge))

      evidence = gate_for(deploy_stage.id, "ci_passed", @bridge).evidence

      assert evidence["repo"] == @bridge,
             "the repository a CI result came from is part of the result"
    end

    test "a FAILED run fails only the delivering repository's gate", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      conn =
        signed_github_post(
          conn,
          @github_webhook_path,
          check_suite_payload(task, @bridge, "failure")
        )

      assert %{"result" => "failed"} = json_response(conn, 201)
      assert gate_for(deploy_stage.id, "ci_passed", @bridge).status == "failed"

      assert gate_for(deploy_stage.id, "ci_passed", @core).status == "pending",
             "a red in one repository is not a red in another any more than a green is"
    end

    test "workflow_run is scoped identically to check_suite", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      conn = signed_github_post(conn, @github_webhook_path, workflow_run_payload(task, @bridge))

      assert %{"result" => "passed"} = json_response(conn, 201)
      assert gate_for(deploy_stage.id, "ci_passed", @bridge).status == "passed"
      assert gate_for(deploy_stage.id, "ci_passed", @core).status == "pending"
    end

    test "matches the delivering repo across spellings (URL vs bare owner/name)", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      conn =
        signed_github_post(
          conn,
          @github_webhook_path,
          check_suite_payload(task, "startup-suite/CORE")
        )

      assert %{"result" => "passed"} = json_response(conn, 201)
      assert gate_for(deploy_stage.id, "ci_passed", @core).status == "passed"
      assert gate_for(deploy_stage.id, "ci_passed", @bridge).status == "pending"
    end
  end

  # ── A CI run from a repository the task never declared ───────────────────

  describe "a check_suite delivered from an undeclared repository" do
    test "evaluates nothing and is recorded as an unmatched CI delivery", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      conn =
        signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @undeclared))

      assert %{"status" => "ignored", "reason" => reason} = json_response(conn, 200)
      assert reason =~ "another repository"

      # NOT passed — and, just as important, NOT failed. A green somewhere
      # else is not evidence about this repository in either direction.
      for repo <- [@core, @bridge] do
        assert gate_for(deploy_stage.id, "ci_passed", repo).status == "pending"
        assert gate_for(deploy_stage.id, "pr_merged", repo).status == "pending"
      end

      assert reload(deploy_stage).status == "running"

      [delivery] =
        gate_for(deploy_stage.id, "ci_passed", @core).evidence["unmatched_repo_ci_deliveries"]

      assert delivery["repo"] == @undeclared
      assert delivery["branch"] == "task/#{task.id}"
      assert {:ok, _, _} = DateTime.from_iso8601(delivery["last_seen_at"])
    end

    test "records one entry per repository, not one per push", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      for _ <- 1..3 do
        signed_github_post(
          build_conn(),
          @github_webhook_path,
          check_suite_payload(task, @undeclared)
        )
      end

      deliveries =
        gate_for(deploy_stage.id, "ci_passed", @core).evidence["unmatched_repo_ci_deliveries"]

      assert length(deliveries) == 1,
             "CI fires on every push; an append-always list would grow without bound"
    end

    test "emits :unmatched_repo telemetry naming the delivering and expected repos",
         %{conn: conn} do
      %{task: task} = two_repo_task!()
      attach([:platform, :tasks, :ci_passed, :unmatched_repo])

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @undeclared))

      assert_receive {:telemetry, %{count: 1}, metadata}
      assert metadata.task_id == task.id
      assert metadata.delivering_repo == @undeclared
      assert metadata.expected_repos == [@core, @bridge]
    end
  end

  # ── Per-repository auto-merge ────────────────────────────────────────────

  describe "auto-merge after a CI success" do
    # THE PIN for the auto-merge target. The bridge is declared SECOND and is
    # NOT the project's repo, so a refusal recorded on the bridge's own gate
    # — with core's gate untouched — rules out both wrong answers the parent
    # gave: the first pending `pr_merged` row, and `task.project.repo_url`.
    test "a ci: \"none\" repository records a refusal on ITS OWN gate and merges nothing",
         %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @bridge))

      bridge_gate = gate_for(deploy_stage.id, "pr_merged", @bridge)
      core_gate = gate_for(deploy_stage.id, "pr_merged", @core)

      assert bridge_gate.evidence["auto_merge"] == "refused"
      assert bridge_gate.evidence["reason"] == "no_ci_to_gate"
      assert bridge_gate.evidence["repo"] == @bridge

      # A repo with no CI is a deploy a PERSON has to look at, not a broken
      # one. `record_merge_result/2`'s error clause would have failed the
      # validation and closed the gate against the human merge that is the
      # whole point.
      assert bridge_gate.status == "pending"

      assert core_gate.evidence in [nil, %{}],
             "the bridge's CI must leave core's merge gate completely untouched"

      assert core_gate.status == "pending"
      assert reload(deploy_stage).status == "running"
    end

    test "the refusal is idempotent across repeated CI runs", %{conn: conn} do
      %{task: task, deploy_stage: deploy_stage} = two_repo_task!()

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @bridge))
      first = gate_for(deploy_stage.id, "pr_merged", @bridge).evidence["refused_at"]

      # WITHOUT THIS the test is a broken control, not a redundant one: on a
      # tree that records no refusal at all both reads are nil, nil == nil,
      # and "idempotent" passes vacuously.
      assert first != nil

      # Re-open the gate so a second delivery can be processed at all.
      deploy_stage.id
      |> gate_for("ci_passed", @bridge)
      |> Ecto.Changeset.change(%{status: "pending"})
      |> Repo.update!()

      signed_github_post(build_conn(), @github_webhook_path, check_suite_payload(task, @bridge))

      assert gate_for(deploy_stage.id, "pr_merged", @bridge).evidence["refused_at"] == first,
             "one refusal is a fact about the configuration, not about the push"
    end

    test "emits :no_ci_to_gate telemetry naming the repository", %{conn: conn} do
      %{task: task} = two_repo_task!()
      attach([:platform, :tasks, :auto_merge, :no_ci_to_gate])

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @bridge))

      assert_receive {:telemetry, %{count: 1}, metadata}
      assert metadata.task_id == task.id
      assert metadata.repo == @bridge
    end

    # THE ZERO-WEBHOOK CASE, NAMED. A repository that declares `ci: "required"`
    # but has no webhook installed can never deliver the CI its gate is
    # waiting on. Nothing in this stage can make that delivery happen — stage
    # 6's reconciler is what actually closes it — but the wait stops being
    # silent: every CI delivery on the task says out loud which repositories
    # it does NOT authorize, and which of them are waiting on a signal versus
    # waiting on a person.
    test "names the repositories a green does NOT authorize, and what each is waiting for",
         %{conn: conn} do
      %{task: task} =
        two_repo_task!([
          %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
          %{"repo_url" => @bridge, "ci" => "none"},
          %{"repo_url" => @undeclared, "ci" => "required"}
        ])

      attach([:platform, :tasks, :auto_merge, :not_authorized_for_siblings])

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @core))

      assert_receive {:telemetry, %{count: 2}, metadata}
      assert metadata.delivering_repo == @core

      assert metadata.awaiting_own_ci == [@undeclared],
             "a ci: \"required\" repo is waiting on a check_suite of its own — which never " <>
               "arrives if nobody installed the webhook"

      assert metadata.awaiting_manual_merge == [@bridge],
             "a ci: \"none\" repo is waiting on a person, and will be until one merges it"
    end

    # FORWARD GUARD, NOT A DEFECT PIN. This cannot detonate against the
    # stage-3 tree — that tree emits no such telemetry for any task, so
    # "emits none here" is trivially true there. It is kept because the
    # thing it protects is a future regression (log volume on the common
    # single-repo path), not a past one. Labelled so it is not mistaken for
    # one of the pins above.
    test "a single-repo deploy emits no sibling non-outcome", %{conn: conn} do
      # Volume control: this fires on every CI push, so it must stay silent
      # for the overwhelmingly common single-repo task.
      %{task: task} =
        two_repo_task!([%{"repo_url" => "https://github.com/#{@core}", "ci" => "required"}])

      attach([:platform, :tasks, :auto_merge, :not_authorized_for_siblings])

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @core))

      refute_receive {:telemetry, _, _}, 100
    end

    # FORWARD GUARD, NOT A DEFECT PIN — same caveat as above. The stage-3
    # tree writes no refusal evidence anywhere, so this passes there for the
    # wrong reason. Its value is that it holds the two refusals apart from
    # here on: it fails the moment `{:no, :disabled}` starts leaving the same
    # trace as `{:no, :no_ci_to_gate}`.
    test "auto_merge disabled writes no refusal — it is an ordinary human merge",
         %{conn: conn} do
      # The load-bearing negative for the never-collapse rule: "we turned it
      # off" must not leave the same trace as "it can never turn on".
      %{task: task, deploy_stage: deploy_stage} =
        two_repo_task!([
          %{
            "repo_url" => "https://github.com/#{@core}",
            "ci" => "required",
            "config" => %{"auto_merge" => false}
          },
          %{
            "repo_url" => @bridge,
            "ci" => "required",
            "config" => %{"auto_merge" => false}
          }
        ])

      signed_github_post(conn, @github_webhook_path, check_suite_payload(task, @bridge))

      bridge_gate = gate_for(deploy_stage.id, "pr_merged", @bridge)

      assert bridge_gate.status == "pending"
      assert bridge_gate.evidence in [nil, %{}]
    end
  end
end
