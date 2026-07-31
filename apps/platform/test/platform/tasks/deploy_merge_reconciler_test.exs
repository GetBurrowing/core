defmodule Platform.Tasks.DeployMergeReconcilerTest do
  @moduledoc """
  The sweeper must FIRE AND FIND, and it must not find things that are not
  there.

  ## The hazard this file is designed around

  A sweep that finds nothing is indistinguishable, from the outside, from a
  sweep that never ran. `assert sweep() == 0` is therefore worth almost
  nothing on its own — it passes against a `def sweep(_), do: 0` stub, and it
  passes against a query whose `where` clauses accidentally exclude every row
  in the database.

  Every zero-result assertion below is consequently paired with one of two
  things:

    * a stub that WOULD have reported a merge for the row under test, so the
      zero can only come from the row being excluded and not from the runner
      having nothing to say; or
    * an `assert_received {:merged_pr_called, …}` proving the sweep reached
      the runner at all, plus a `refute_received` for rows that must not have
      been asked about.

  The `gh`-unavailable case is the sharpest instance: its stub returns a
  merged PR for every query. If the availability guard were deleted, that
  test would pass a validation and fail loudly. A stub returning `{:ok, nil}`
  there would have proven nothing.

  ## Stub mechanics

  `sweep/1` is synchronous and runs in the calling process, so the stub reads
  its script from — and reports its calls into — the TEST process. No
  application-env mutation, no Agent, no global state: the file stays
  `async: true` and two tests cannot script each other's runner.
  """

  use Platform.DataCase, async: true

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployMergeReconciler
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Validation

  @core "Startup-Suite/core"
  # Zero webhooks installed, verified 2026-07-31. The whole reason this
  # module exists, and so the repository every pin below merges in.
  @bridge "Startup-Suite/claude-code-suite-channel"

  # ── Stub runners ─────────────────────────────────────────────────────────

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeployMergeReconciler.MergeRunner

    @impl true
    def available?, do: Process.get(:stub_available, :ok)

    @impl true
    def merged_pr(%{repo: repo, branch: branch} = query) do
      send(self(), {:merged_pr_called, query})

      :stub_results
      |> Process.get(%{})
      |> Enum.find_value({:ok, nil}, fn {key, result} ->
        if String.contains?(repo, key) or key == branch, do: result
      end)
    end
  end

  # Reports a merge for LITERALLY ANY query. Used only where the assertion is
  # that the sweeper never asked — so a zero result cannot be an artifact of
  # the stub having nothing to report.
  defmodule AlwaysMergedRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeployMergeReconciler.MergeRunner

    @impl true
    def available?, do: Process.get(:stub_available, :ok)

    @impl true
    def merged_pr(query) do
      send(self(), {:merged_pr_called, query})

      {:ok,
       %{
         number: 999,
         url: "https://github.com/anything/999",
         merged_at: "2026-07-31T17:00:00Z",
         merge_commit_sha: "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
       }}
    end
  end

  # ── Script helpers ───────────────────────────────────────────────────────

  defp script(repo_or_branch, result),
    do:
      Process.put(:stub_results, Map.put(Process.get(:stub_results, %{}), repo_or_branch, result))

  defp merged(number, opts \\ []) do
    {:ok,
     %{
       number: number,
       url: Keyword.get(opts, :url, "https://github.com/x/pull/#{number}"),
       merged_at: Keyword.get(opts, :merged_at, "2026-07-31T12:09:00Z"),
       merge_commit_sha:
         Keyword.get(opts, :merge_commit_sha, "326d2b08" <> String.duplicate("a", 32))
     }}
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  # Drives the REAL deploy-stage injection path, so the gates under test are
  # the rows production mints (one `pr_merged` per declared repo, payload
  # carrying `"repo"` + `"repo_url"` + `"ci"`) rather than hand-built ones
  # that could drift from the builder.
  defp deploying_task!(repos, opts) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Reconciler #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/#{@core}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Lands in more than one repository",
        status: "in_progress",
        deploy_target: "production",
        deploy_strategy: %{
          "type" => "pr_merge",
          "config" => %{"auto_merge" => false},
          "repos" => repos
        }
      })

    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        status: Keyword.get(opts, :plan_status, "approved"),
        version: Keyword.get(opts, :version, 1)
      })

    {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(s1.id)
    {:ok, plan} = PlanEngine.advance(plan.id)

    deploy_stage = Enum.find(plan.stages, &(&1.name == "Deploy: PR merge"))

    gates =
      deploy_stage.id
      |> gates_for_stage()
      |> Map.new(fn v -> {v.evaluation_payload["repo"], v} end)

    %{project: project, task: task, plan: plan, stage: deploy_stage, gates: gates}
  end

  defp two_repo_task!(opts \\ []) do
    deploying_task!(
      [
        %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
        %{"repo_url" => "https://github.com/#{@bridge}", "ci" => "none"}
      ],
      opts
    )
  end

  defp gates_for_stage(stage_id) do
    Repo.all(
      from(v in Validation,
        where: v.stage_id == ^stage_id and v.kind == "pr_merged",
        order_by: v.inserted_at
      )
    )
  end

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)
  defp reload_stage(%Stage{id: id}), do: Repo.get!(Stage, id)
  defp reload_stage(id) when is_binary(id), do: Repo.get!(Stage, id)

  defp short_branch(task), do: "task/" <> (task.id |> String.split("-") |> List.first())

  # ── The sweep fires and finds ────────────────────────────────────────────

  describe "sweep/1 — an observed merge" do
    test "passes the gate for the repository whose PR merged" do
      %{task: task, gates: gates} = two_repo_task!()
      script(@bridge, merged(41))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1

      bridge = reload(gates[@bridge])
      assert bridge.status == "passed"
      assert bridge.evaluated_by == "deploy_merge_reconciler"
      assert bridge.evidence["repo"] == @bridge
      assert bridge.evidence["pr_number"] == 41
      assert bridge.evidence["merged_at"] == "2026-07-31T12:09:00Z"

      # The provenance key. A polled observation and a webhook delivery are
      # different facts; evidence that read identically would erase that.
      assert bridge.evidence["observed_by"] == "reconciler"

      # NEGATIVE CONTROL, and the load-bearing half of this test: core's PR
      # is genuinely unmerged, so core's gate must still be pending. The
      # stub WAS asked about core and answered "no" — proving the sweep
      # reached it and declined, not that it skipped it.
      assert reload(gates[@core]).status == "pending"
      assert reload(gates[@core]).evidence == %{}

      branch = short_branch(task)
      assert_received {:merged_pr_called, %{repo: repo_a, branch: ^branch}}
      assert_received {:merged_pr_called, %{repo: repo_b, branch: ^branch}}

      assert Enum.sort([repo_a, repo_b]) == [
               "https://github.com/#{@bridge}",
               "https://github.com/#{@core}"
             ]
    end

    test "asks about the branch the dispatch tells the executor to push" do
      %{task: task} = two_repo_task!()

      DeployMergeReconciler.sweep(runner: StubRunner)

      # `HeartbeatScheduler.member_slug/1`'s answer for a non-stack task is
      # the 8-char id prefix. A second derivation here would poll a branch
      # nobody pushed and report "not merged" forever — the silent-hang
      # failure mode in a new place.
      expected = short_branch(task)
      assert_received {:merged_pr_called, %{branch: ^expected}}
    end

    test "hands `gh -R` the declared repo_url, and records the canonical slug" do
      %{gates: gates} = two_repo_task!()
      script(@bridge, merged(7))

      DeployMergeReconciler.sweep(runner: StubRunner)

      assert_received {:merged_pr_called, %{repo: "https://github.com/" <> @bridge}}
      assert reload(gates[@bridge]).evidence["repo"] == @bridge
    end

    test "records a null mergeCommit as nil rather than inventing a SHA" do
      %{gates: gates} = two_repo_task!()
      script(@bridge, merged(8, merge_commit_sha: nil))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1
      assert reload(gates[@bridge]).evidence["merge_commit_sha"] == nil
    end
  end

  # ── The sweep does not find things that are not there ────────────────────

  describe "sweep/1 — no merged PR" do
    test "leaves the gate pending, writes no evidence, and returns 0" do
      %{gates: gates} = two_repo_task!()

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 0

      for slug <- [@core, @bridge] do
        gate = reload(gates[slug])
        assert gate.status == "pending"
        assert gate.evidence == %{}
        assert gate.evaluated_by == nil
        assert gate.evaluated_at == nil
      end

      # Non-vacuity: the zero above is "asked and told no", not "never ran".
      assert_received {:merged_pr_called, _}
      assert_received {:merged_pr_called, _}
    end

    test "a lookup ERROR leaves the gate pending — a failed question is not a no" do
      %{gates: gates} = two_repo_task!()
      script(@bridge, {:error, {:gh_error, "HTTP 404: Not Found"}})

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 0
      assert reload(gates[@bridge]).status == "pending"
      assert reload(gates[@bridge]).evidence == %{}
    end
  end

  # ── The load-bearing negative: a missing tool is never a merge ───────────

  describe "sweep/1 — `gh` unavailable" do
    test "returns 0, passes nothing, and never asks the runner a question" do
      %{gates: gates} = two_repo_task!()
      Process.put(:stub_available, {:error, :gh_unavailable, "`gh` not found on PATH"})

      # AlwaysMergedRunner reports a merge for EVERY query. If the guard
      # were removed, both gates would pass and this test would fail loudly
      # rather than passing by coincidence of an empty script.
      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0

      assert reload(gates[@core]).status == "pending"
      assert reload(gates[@bridge]).status == "pending"
      refute_received {:merged_pr_called, _}
    end

    test "the same runner passes both gates when it IS available" do
      # The other half of the pair. Without this, "0 and nothing passed"
      # above would be satisfied by a runner that simply cannot pass
      # anything, and the guard would be untested.
      %{gates: gates} = two_repo_task!()

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 2
      assert reload(gates[@core]).status == "passed"
      assert reload(gates[@bridge]).status == "passed"
    end
  end

  # ── Scoping: which gates are this sweeper's business ─────────────────────

  describe "sweep/1 — scoping" do
    test "a gate on a stage that is not running is not swept" do
      %{stage: stage, gates: gates} = two_repo_task!()

      {:ok, _} = stage |> Ecto.Changeset.change(%{status: "passed"}) |> Repo.update()

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0
      assert reload(gates[@bridge]).status == "pending"
      refute_received {:merged_pr_called, _}
    end

    test "a gate on a SUPERSEDED plan version is not swept" do
      %{task: task, stage: stage, gates: gates} = two_repo_task!()

      # v1 stays `approved` with a running deploy stage. A v2 lands and is
      # approved — `current_plan/1` now answers v2, so v1's gates are
      # history. A hand-rolled `p.status == "approved"` join would still
      # match v1 here and poll a plan nobody is executing.
      {:ok, v2} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 2})
      assert Tasks.current_plan(task.id).id == v2.id
      assert reload_stage(stage).status == "running"

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0
      assert reload(gates[@bridge]).status == "pending"
      refute_received {:merged_pr_called, _}
    end

    test "a COMPLETED plan is still current — approved-only filtering would hang it" do
      # The pin for routing through `current_plan/1` rather than an
      # `approved`-only predicate. `current_plan/1` selects
      # `status in ["approved", "completed"]`; a plan whose row has drifted
      # to `completed` while its deploy stage is still running is exactly
      # the state that blocked `StackDeployer.review_readiness/1`
      # indefinitely. Its gates must still be swept.
      %{plan: plan, stage: stage, gates: gates} = two_repo_task!()
      {:ok, _} = plan |> Ecto.Changeset.change(%{status: "completed"}) |> Repo.update()
      assert reload_stage(stage).status == "running"

      script(@bridge, merged(12))
      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1
      assert reload(gates[@bridge]).status == "passed"
    end

    test "a plan that is not approved or completed is not swept" do
      %{stage: stage, gates: gates} = two_repo_task!(plan_status: "pending_review")

      assert reload_stage(stage).status == "running"
      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0
      assert reload(gates[@bridge]).status == "pending"
      refute_received {:merged_pr_called, _}
    end

    test "a gate with a nil evaluation_payload is skipped" do
      # The legacy unscoped single-repo row. It names no repository, so
      # there is nothing to poll; `GithubWebhookController` owns the rules
      # for when such a gate may pass.
      %{stage: stage} = two_repo_task!()

      {:ok, legacy} =
        Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

      assert legacy.evaluation_payload == nil
      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 2
      assert reload(legacy).status == "pending"

      # Two queries, for the two SCOPED gates — the legacy row was never
      # asked about, which is what "skipped" has to mean here.
      assert_received {:merged_pr_called, _}
      assert_received {:merged_pr_called, _}
      refute_received {:merged_pr_called, _}
    end

    test "a scoped gate whose repo would not normalize is skipped, not guessed at" do
      # `Tasks.resolve_deploy_repos/1` KEEPS a declared repo whose URL will
      # not normalize, with `slug: nil`, so its gate can never be matched by
      # accident. That guard has to hold on the polled path too, or it leaks
      # on one side of the pair.
      %{stage: stage} = two_repo_task!()

      {:ok, unnormalizable} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "pr_merged",
          evaluation_payload: %{"repo" => nil, "repo_url" => "not a repository", "ci" => "none"}
        })

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 2
      assert reload(unnormalizable).status == "pending"
    end

    test "only `pr_merged` is swept — a ci_passed gate is left alone" do
      %{stage: stage} = two_repo_task!()

      {:ok, ci} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "ci_passed",
          evaluation_payload: %{"repo" => @bridge}
        })

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 2
      assert reload(ci).status == "pending"
    end

    test "an ALREADY-PASSED gate is not re-swept" do
      %{gates: gates} = two_repo_task!()

      {:ok, _} =
        PlanEngine.evaluate_validation(gates[@core].id, %{
          status: "passed",
          evidence: %{"pr_url" => "https://github.com/#{@core}/pull/640"},
          evaluated_by: "github_webhook"
        })

      # BOTH repositories are scripted as merged, and core's is scripted
      # DELIBERATELY. The stage is still running (one of two gates open), so
      # the running-stage filter does not exclude core's row — only the
      # `status == "pending"` filter does. Script core as unmerged instead
      # and this test passes with that filter deleted, which is exactly the
      # vacuous shape it was written to avoid: the pending filter and the
      # running-stage filter would be two mechanisms masking each other, and
      # either could be dropped with the suite still green.
      script(@core, merged(640))
      script(@bridge, merged(3))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1
      assert reload(gates[@bridge]).evidence["pr_number"] == 3

      # The webhook's evidence survives untouched — a re-sweep would stamp
      # `observed_by: reconciler` over a fact the webhook actually delivered,
      # rewriting a push as a poll.
      core = reload(gates[@core])
      assert core.evaluated_by == "github_webhook"
      assert core.evidence["pr_url"] == "https://github.com/#{@core}/pull/640"
      refute Map.has_key?(core.evidence, "observed_by")

      # And it was never even asked about.
      refute_received {:merged_pr_called, %{repo: "https://github.com/" <> @core}}
    end
  end

  # ── End to end: the polled path and the webhook path compose ────────────

  describe "sweep/1 — two repositories, two mechanisms" do
    test "webhook passes core, the sweep passes the bridge, and the stage advances" do
      %{stage: stage, gates: gates} = two_repo_task!()

      # 1. core has a webhook installed. Its gate passes on delivery.
      {:ok, _} =
        PlanEngine.evaluate_validation(gates[@core].id, %{
          status: "passed",
          evidence: %{
            "pr_url" => "https://github.com/#{@core}/pull/640",
            "merge_commit_sha" => "326d2b08"
          },
          evaluated_by: "github_webhook"
        })

      # The stage must NOT have advanced on one of two gates. This is the
      # conflation stages 2-3 removed; if it regressed, the assertion below
      # about the sweep being what completes the stage would be vacuous.
      assert reload_stage(stage).status == "running"

      # 2. the bridge has ZERO webhooks. A human merged its PR by hand and
      # nothing told us. The poll is the only way we find out.
      script(@bridge, merged(21, url: "https://github.com/#{@bridge}/pull/21"))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1

      bridge = reload(gates[@bridge])
      assert bridge.status == "passed"
      assert bridge.evidence["observed_by"] == "reconciler"
      assert bridge.evidence["pr_url"] == "https://github.com/#{@bridge}/pull/21"

      # 3. both repositories accounted for, each by its own mechanism, each
      # naming its own repository — and only NOW does the stage complete.
      assert reload_stage(stage).status == "passed"
    end

    test "a second sweep after both gates are passed is a no-op" do
      %{gates: gates} = two_repo_task!()
      script(@core, merged(1))
      script(@bridge, merged(2))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 2
      assert reload(gates[@core]).status == "passed"
      assert reload(gates[@bridge]).status == "passed"

      # Drain the first sweep's two calls, so the `refute_received` below
      # is a claim about the SECOND sweep and not a re-read of the first.
      assert_received {:merged_pr_called, _}
      assert_received {:merged_pr_called, _}
      refute_received {:merged_pr_called, _}

      # Idempotence. The ticker fires every five minutes; a sweep that
      # re-passed settled gates would rewrite evidence and re-emit
      # telemetry forever.
      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0
      refute_received {:merged_pr_called, _}
    end
  end

  # ── Wiring ───────────────────────────────────────────────────────────────

  describe "configuration" do
    test "the production default runner is the `gh` shell implementation" do
      assert DeployMergeReconciler.merge_runner() ==
               Platform.Tasks.DeployMergeReconciler.GhMergeRunner
    end

    test "the reconciler is NOT started in the test supervision tree" do
      # Its five-minute tick would shell out to `gh` from a process with no
      # Ecto sandbox ownership. Tests drive `sweep/1` directly instead.
      refute Application.get_env(:platform, :start_deploy_merge_reconciler, true)
      assert Process.whereis(DeployMergeReconciler) == nil
    end
  end

  # ── The behaviour has no merge callback, and that is the guard ───────────

  describe "MergeRunner behaviour" do
    test "declares only `available?/0` and `merged_pr/1`" do
      # The ticket's hard constraint is that a second PR is never
      # machine-merged without that repository's own CI gating it, and the
      # bridge repos have no CI at all. A poller running every five minutes
      # against exactly those repositories must not have a merge callback
      # within reach. Pinned structurally, not by convention.
      callbacks =
        Platform.Tasks.DeployMergeReconciler.MergeRunner.behaviour_info(:callbacks)
        |> Enum.sort()

      assert callbacks == [available?: 0, merged_pr: 1]
    end
  end
end
