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

  import ExUnit.CaptureLog

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployMergeReconciler
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task, as: TaskRecord
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

    attrs = %{
      project_id: project.id,
      title: "Lands in more than one repository",
      status: "in_progress",
      deploy_target: "production",
      deploy_strategy: %{
        "type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => repos
      }
    }

    task = insert_task!(attrs, Keyword.get(opts, :id))

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

  # A pinned id is what lets a branch expectation be a hand-written STRING
  # LITERAL rather than a second call to the derivation. `Task.changeset/2`
  # does not cast `:id` — the schema autogenerates a UUIDv7 — so it has to go
  # on as a `put_change` before the insert. Same route as
  # `stack_deployer_test.exs:780-793` and `deploy_stage_builder_test.exs`.
  # `Tasks.create_task/1`'s extra work is advisory (reference upsert, async
  # memory ingest, sponsor notification), none of which any test here reads.
  defp insert_task!(attrs, nil) do
    {:ok, task} = Tasks.create_task(attrs)
    task
  end

  defp insert_task!(attrs, id) when is_binary(id) do
    %TaskRecord{}
    |> TaskRecord.changeset(attrs)
    |> Ecto.Changeset.put_change(:id, id)
    |> Repo.insert!()
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

  defp one_repo_task!(opts \\ []) do
    deploying_task!([%{"repo_url" => "https://github.com/#{@bridge}", "ci" => "none"}], opts)
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

  # THERE IS DELIBERATELY NO `dispatch_branch/1` HELPER IN THIS FILE, and the
  # absence is load-bearing enough to be worth a comment.
  #
  # Two forms have stood here and both were removed for the same underlying
  # reason. The first was `task.id |> String.split("-") |> List.first()` — a
  # REIMPLEMENTATION of the reconciler's truncation. It had genuine detection
  # power and went RED when `member_slug/1` changed, correctly reporting the
  # breakage this task exists to fix. Commit `4849cbd1` on
  # `origin/task/019fb949` (merged as PR #647) then replaced it with
  # `"task/" <> HeartbeatScheduler.member_slug(task)` and asserted
  # `expected = dispatch_branch(task)` — an expectation computed by the
  # function under test. Both sides moved together from that point on, so the
  # assertion could not fail for ANY value `member_slug/1` returned. A working
  # detector was swapped for a no-op, on the branch that caused the breakage
  # the detector was reporting.
  #
  # Every branch expectation below is therefore a STRING LITERAL, typed out by
  # hand from the fixture's pinned task id. A reimplementation that can
  # disagree is worth keeping; a derivation from the code under test is worth
  # nothing.
  defp put_payload!(%Validation{} = gate, payload) do
    gate |> Ecto.Changeset.change(%{evaluation_payload: payload}) |> Repo.update!()
  end

  # Rewrites the branch a MINTED gate records, so a test can pin a branch shape
  # no derivation produces. Goes through `Repo.update` deliberately:
  # `PlanEngine.evaluate_validation/2` dispositions a gate, it does not edit
  # the payload, and using it here would also pass the row under test.
  defp record_branch!(%Validation{} = gate, branch) do
    put_payload!(gate, Map.put(gate.evaluation_payload, "branch", branch))
  end

  # Reads the retirement query out of the module's OWN moduledoc, so the
  # thing under test is the text an operator copies rather than a
  # second copy living here. If the comment drifts, this breaks.
  defp documented_retirement_sql do
    {:docs_v1, _, :elixir, _, %{"en" => moduledoc}, _, _} =
      Code.fetch_docs(DeployMergeReconciler)

    [_, sql] = Regex.run(~r/```sql\n(.+?)\n\s*```/s, moduledoc)

    sql
  end

  # Removes the key entirely — NOT `%{"branch" => nil}`. This reproduces a gate
  # minted between `d63abdc0` reaching production (20:47Z 2026-07-31, scoped
  # payloads) and stage 1 of this task landing (the `"branch"` key), which is
  # the only population the refusal branch can ever see.
  defp drop_recorded_branch!(%Validation{} = gate) do
    put_payload!(gate, Map.delete(gate.evaluation_payload, "branch"))
  end

  # ── The sweep fires and finds ────────────────────────────────────────────

  describe "sweep/1 — an observed merge" do
    test "passes the gate for the repository whose PR merged" do
      %{gates: gates} = two_repo_task!(id: "019fb9c5-6196-7a42-8c30-1e2d3f4a5b6c")
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

      # Typed out by hand from the id pinned on the fixture above. One task
      # pushes ONE branch, so both repositories are polled on the same name.
      assert_received {:merged_pr_called,
                       %{repo: repo_a, branch: "task/019fb9c5-6196-7a42-8c30-1e2d3f4a5b6c"}}

      assert_received {:merged_pr_called,
                       %{repo: repo_b, branch: "task/019fb9c5-6196-7a42-8c30-1e2d3f4a5b6c"}}

      assert Enum.sort([repo_a, repo_b]) == [
               "https://github.com/#{@bridge}",
               "https://github.com/#{@core}"
             ]
    end

    test "polls the FULL-uuid branch the deploy stage recorded at mint time" do
      one_repo_task!(id: "019fb9c5-6196-7a42-8c30-1e2d3f4a5b6d")

      DeployMergeReconciler.sweep(runner: StubRunner)

      # The full task uuid, hand-copied from the line above. An 8-character
      # prefix is a ~65-second UUIDv7 time bucket rather than an identifier,
      # so if this ever shortens again the sweeper would poll a name shared
      # with every task minted in the same minute. Pinning the literal is what
      # makes that visible here; pinning `member_slug/1`'s current answer
      # would not, because the expectation would shorten with it.
      assert_received {:merged_pr_called, %{branch: "task/019fb9c5-6196-7a42-8c30-1e2d3f4a5b6d"}}
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

  # ── The recorded branch, and the refusal to invent one ───────────────────

  describe "sweep/1 — the recorded branch" do
    test "polls the branch RECORDED on the gate, including one no derivation produces" do
      %{gates: gates} = one_repo_task!(id: "019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37")

      # The shape task 019fa63a-02a0 actually pushed to origin, carrying
      # merged PR #644. No derivation in the tree produces this name — not
      # `member_slug/1` before PR #647 and not after it — and
      # `Changelog.extract_task_id_from_branch/1` cannot parse it either,
      # because `@branch_prefix` (`changelog.ex:169`) wants 8 hex characters
      # immediately after `task/` and `envelope-` is not hex. A sweeper that
      # derived its branch could never reach this gate at all.
      record_branch!(
        gates[@bridge],
        "task/envelope-records-019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37"
      )

      script("task/envelope-records-019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37", merged(644))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1

      gate = reload(gates[@bridge])
      assert gate.status == "passed"
      assert gate.evidence["pr_number"] == 644
      assert gate.evidence["observed_by"] == "reconciler"

      assert_received {:merged_pr_called,
                       %{branch: "task/envelope-records-019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37"}}

      # And never about the name it would have derived from the task id. This
      # is the half that fails if the derivation comes back.
      refute_received {:merged_pr_called, %{branch: "task/019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37"}}
    end

    # DISCRIMINATION CONTROL. What this proves is that RECORDING prevents
    # cross-attribution: each task is polled on the branch its own deploy
    # stage wrote down, so one merge cannot close another task's gate.
    #
    # Stated carefully, because the shape of the claim has already drifted
    # once. `task/019fb90f` is what these two tasks derived BEFORE PR #647
    # (`f2083747`) made `member_slug/1` unconditionally full-uuid; the
    # collision is not reachable through the derivation on main today. The
    # value of this test is not that it reproduces a live defect — it does
    # not — but that it fails if the branch name is ever re-truncated or
    # re-derived from anything shorter than the full id. The first eight hex
    # characters of a UUIDv7 are the high 32 bits of its 48-bit millisecond
    # timestamp, so any prefix scheme collides deterministically for tasks
    # filed in the same ~65-second window, and the pair below is a real one
    # (`task/019fb90f` carries merged PR #648).
    #
    # Nothing downstream can catch that: `gh pr list --head` answers about a
    # branch and GitHub returns one PR per branch, so the runner sees no
    # ambiguity to fail closed on. The ambiguity is Suite-side, which is why
    # it has to be caught here.
    test "one merge cannot close two tasks' gates — each is polled on its OWN branch" do
      a = one_repo_task!(id: "019fb90f-36e3-7fd6-a416-f128f4c0190f")
      b = one_repo_task!(id: "019fb90f-6226-7fd6-a416-f128f4c0190f")

      script("task/019fb90f", merged(648))

      assert DeployMergeReconciler.sweep(runner: StubRunner) == 0,
             "a merged PR on task/019fb90f closed a deploy gate for a task that never " <>
               "pushed that branch — one merge, two tasks marked shipped"

      assert reload(a.gates[@bridge]).status == "pending"
      assert reload(a.gates[@bridge]).evidence == %{}
      assert reload(b.gates[@bridge]).status == "pending"
      assert reload(b.gates[@bridge]).evidence == %{}

      refute_received {:merged_pr_called, %{branch: "task/019fb90f"}}

      # NON-VACUITY, and mandatory. Without the two assertions below the zero
      # above is indistinguishable from a sweep that never ran — the exact
      # hazard this file's moduledoc is built around. Both calls DID happen,
      # each carrying its own task's full id.
      assert_received {:merged_pr_called, %{branch: "task/019fb90f-36e3-7fd6-a416-f128f4c0190f"}}

      assert_received {:merged_pr_called, %{branch: "task/019fb90f-6226-7fd6-a416-f128f4c0190f"}}
    end

    test "a gate with NO recorded branch is refused rather than guessed at" do
      %{gates: gates} = one_repo_task!(id: "019fb9c5-6196-7a42-8c30-1e2d3f4a5b6e")
      drop_recorded_branch!(gates[@bridge])

      # `AlwaysMergedRunner`, and this is the whole test. It reports a merge
      # for LITERALLY ANY query, so the zero below can only come from the
      # sweeper declining to ask. Under `StubRunner` this test would pass
      # against a DELETED refusal branch, because an empty script answers
      # `{:ok, nil}` to whatever branch a restored derivation invented.
      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0

      gate = reload(gates[@bridge])
      assert gate.status == "pending"
      assert gate.evidence == %{}
      assert gate.evaluated_by == nil
      assert gate.evaluated_at == nil

      refute_received {:merged_pr_called, _}
    end

    test "the same fixture WITH a branch recorded passes under the same runner" do
      # The other half of the pair. Without it, "0 and never asked" above is
      # satisfied by a sweeper that cannot reach this fixture at all, and the
      # refusal would be untested.
      %{gates: gates} = one_repo_task!(id: "019fb9c5-6196-7a42-8c30-1e2d3f4a5b6f")

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 1
      assert reload(gates[@bridge]).status == "passed"

      assert_received {:merged_pr_called, %{branch: "task/019fb9c5-6196-7a42-8c30-1e2d3f4a5b6f"}}
    end

    test "a branch recorded as blank is refused too — `present?` is what decides" do
      # `Map.get/2` answers nil for an absent key AND for a key written as
      # nil, and a payload could carry `""` from a hand-repair. All three are
      # "not recorded", so the refusal is keyed on `present?/1` rather than on
      # key presence. Asserted because it is a line of production code that
      # would otherwise never run.
      %{gates: gates} = one_repo_task!()
      record_branch!(gates[@bridge], "   ")

      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0
      assert reload(gates[@bridge]).status == "pending"
      refute_received {:merged_pr_called, _}
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

  # ── The retirement counter for the refusal branch ────────────────────────

  describe "unrecorded_branch_gates/0" do
    # THE ZERO MUST BE A REAL ZERO. Every `count: 0` below is paired with a
    # fixture that actually CONTAINS the thing being excluded, and — where
    # the exclusion is a state change rather than an extra row — with the
    # non-zero count measured BEFORE that change. A refute whose fixture
    # never creates the excluded row asserts nothing, and a zero on an empty
    # fixture is satisfied by `def unrecorded_branch_gates, do: %{count: 0}`.

    test "is 0 for a freshly-minted plan — every gate records a branch" do
      %{gates: gates} = two_repo_task!()

      # Non-vacuity for the zero: the two gates exist, are live, and DO
      # carry the key. Without this the assertion below is also satisfied
      # by a query that matches no row in the database at all.
      assert map_size(gates) == 2
      assert gates[@core].evaluation_payload["branch"]
      assert gates[@bridge].evaluation_payload["branch"]

      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 0,
               validation_ids: []
             }
    end

    test "is 1, naming the id, for a gate whose payload lacks the key" do
      %{gates: gates} = two_repo_task!()
      drop_recorded_branch!(gates[@bridge])

      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 1,
               validation_ids: [gates[@bridge].id]
             }
    end

    # THE DELIBERATE DECISION, and it is a departure from a key-presence
    # count. `refuse/2` fires on `not present?/1`, so a blank recorded
    # branch is refused every five minutes — but it HAS the `"branch"` key
    # and a `NOT (payload ? 'branch')` count would report zero for it. That
    # zero would then license deleting the refusal branch, after which this
    # row's `""` would be handed to `gh pr list --head`. The counter is only
    # worth having if its zero means the branch is unreachable, so it shares
    # `present?/1` with the code it reports on.
    test "counts a BLANK recorded branch — key presence is not what decides" do
      %{gates: gates} = one_repo_task!()
      record_branch!(gates[@bridge], "   ")

      assert Repo.get!(Validation, gates[@bridge].id).evaluation_payload
             |> Map.has_key?("branch"),
             "the fixture must keep the key, or this is the absent-key case again"

      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 1,
               validation_ids: [gates[@bridge].id]
             }

      # And it is genuinely the row `refuse/2` declines to poll, measured
      # rather than assumed — the count and the refusal name one set.
      assert DeployMergeReconciler.sweep(runner: AlwaysMergedRunner) == 0
      refute_received {:merged_pr_called, _}
    end

    test "does not count a nil-payload row — the legacy unscoped gate" do
      %{stage: stage, gates: gates} = two_repo_task!()
      drop_recorded_branch!(gates[@bridge])

      {:ok, legacy} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})
      assert legacy.evaluation_payload == nil

      # The excluded row EXISTS, is pending, and sits on the same running
      # stage as the counted one. So the list below is a discrimination,
      # not an empty database.
      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 1,
               validation_ids: [gates[@bridge].id]
             }
    end

    test "does not count a PASSED payload-without-branch row" do
      %{gates: gates} = two_repo_task!()
      drop_recorded_branch!(gates[@core])
      drop_recorded_branch!(gates[@bridge])

      assert DeployMergeReconciler.unrecorded_branch_gates().count == 2

      {:ok, _} =
        PlanEngine.evaluate_validation(gates[@core].id, %{
          status: "passed",
          evidence: %{"pr_url" => "https://github.com/#{@core}/pull/640"},
          evaluated_by: "github_webhook"
        })

      assert reload(gates[@core]).status == "passed"

      # 2 -> 1, and the survivor is named. A settled gate cannot reach
      # `refuse/2`, so it must not hold the retirement count above zero.
      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 1,
               validation_ids: [gates[@bridge].id]
             }
    end

    test "does not count a payload-without-branch row on a NON-RUNNING stage" do
      %{stage: stage, gates: gates} = one_repo_task!()
      drop_recorded_branch!(gates[@bridge])

      # Measured before the state change, so the zero after it is
      # attributable to the stage status and to nothing else.
      assert DeployMergeReconciler.unrecorded_branch_gates().count == 1

      {:ok, _} = stage |> Ecto.Changeset.change(%{status: "passed"}) |> Repo.update()

      assert reload(gates[@bridge]).status == "pending"

      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 0,
               validation_ids: []
             }
    end

    test "does not count a row on a SUPERSEDED plan version" do
      %{task: task, stage: stage, gates: gates} = one_repo_task!()
      drop_recorded_branch!(gates[@bridge])

      assert DeployMergeReconciler.unrecorded_branch_gates().count == 1

      # v1's deploy stage stays running and its gate stays pending — only
      # `current_plan/1`'s answer moves. A counter that filtered on
      # `p.status == "approved"` instead would still match v1 here and
      # report a gate nobody is executing, holding retirement open forever.
      {:ok, v2} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 2})
      assert Tasks.current_plan(task.id).id == v2.id
      assert reload_stage(stage).status == "running"
      assert reload(gates[@bridge]).status == "pending"

      assert DeployMergeReconciler.unrecorded_branch_gates() == %{
               count: 0,
               validation_ids: []
             }
    end

    # The moduledoc's SQL is EXECUTED, against a fixture holding one of
    # every excluded shape plus both counted shapes. Extracting it from the
    # docs chunk rather than restating it here is the whole point: a copy in
    # this file could drift from the comment an operator actually reads, and
    # the comment is the artifact the stage asked for. A query nobody runs
    # is the documentation form of a guard nobody watched fire.
    test "the SQL documented in the moduledoc returns the same count" do
      # Counted: one absent-key, one blank.
      %{gates: counted} = two_repo_task!()
      drop_recorded_branch!(counted[@core])
      record_branch!(counted[@bridge], "  ")

      # Excluded: a recorded branch (this task's other rows), a nil payload,
      # a passed row, a non-running stage, and a superseded plan.
      %{stage: stage, gates: recorded} = two_repo_task!()
      assert recorded[@bridge].evaluation_payload["branch"]
      {:ok, _} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})

      %{gates: settled} = one_repo_task!()
      drop_recorded_branch!(settled[@bridge])

      {:ok, _} =
        PlanEngine.evaluate_validation(settled[@bridge].id, %{
          status: "passed",
          evidence: %{"pr_url" => "https://github.com/#{@bridge}/pull/1"},
          evaluated_by: "github_webhook"
        })

      %{stage: done_stage, gates: on_done} = one_repo_task!()
      drop_recorded_branch!(on_done[@bridge])
      {:ok, _} = done_stage |> Ecto.Changeset.change(%{status: "passed"}) |> Repo.update()

      %{task: old_task, gates: on_old} = one_repo_task!()
      drop_recorded_branch!(on_old[@bridge])
      {:ok, _} = Tasks.create_plan(%{task_id: old_task.id, status: "approved", version: 2})

      tally = DeployMergeReconciler.unrecorded_branch_gates()

      assert tally.count == 2,
             "the fixture must contain BOTH counted shapes, or the SQL agreeing " <>
               "with the function proves only that both answer zero"

      assert %Postgrex.Result{rows: [[sql_count]]} =
               Repo.query!(documented_retirement_sql())

      assert sql_count == tally.count
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

defmodule Platform.Tasks.DeployMergeReconcilerTickLogTest do
  @moduledoc """
  The announcement the tick makes about the retirement condition.

  Split out of `Platform.Tasks.DeployMergeReconcilerTest` and marked
  `async: false` for exactly one reason: `config/test.exs` sets the Logger
  level to `:warning`, which drops `info` at the source. Observing an
  `info` line therefore needs `Logger.configure/1`, which is global — the
  same shape as `runtime_supervision_owner_identity_test.exs:350-360`.
  Keeping it in its own module leaves the 37 tests above concurrent.

  The level is what makes these tests mean anything, and the point is worth
  stating because it is easy to get backwards. Under `:warning` the "silent
  at zero" assertion below passes against a function that logs
  UNCONDITIONALLY, because nothing is captured either way. It only
  discriminates at `:info`.

  The fixture here is hand-built rather than driven through
  `PlanEngine.advance/1`. That is deliberate: what is under test is the
  callback emitting a line for a row the counter returned, not the shape of
  a minted gate — the builder's output is pinned next door and in
  `deploy_stage_builder_test.exs`.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployMergeReconciler

  @bridge "Startup-Suite/claude-code-suite-channel"

  # Answers "not merged" to everything and never leaves the VM. The tick
  # calls `sweep/0`, which reads the runner from application env, so driving
  # the real callback needs a configured stub or it shells out to `gh`.
  defmodule NeverMergedRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeployMergeReconciler.MergeRunner

    @impl true
    def available?, do: :ok

    @impl true
    def merged_pr(query) do
      send(self(), {:merged_pr_called, query})
      {:ok, nil}
    end
  end

  setup do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)
    :ok
  end

  defp unrecorded_gate! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Tick #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/#{@bridge}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Minted before the branch was recorded",
        status: "in_progress",
        deploy_target: "production"
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    {:ok, stage} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Deploy: PR merge"})
    {:ok, stage} = stage |> Ecto.Changeset.change(%{status: "running"}) |> Repo.update()

    # A SCOPED payload with no `"branch"` key — the only population the
    # refusal branch, and therefore this counter, can ever see.
    {:ok, gate} =
      Tasks.create_validation(%{
        stage_id: stage.id,
        kind: "pr_merged",
        evaluation_payload: %{
          "repo" => @bridge,
          "repo_url" => "https://github.com/#{@bridge}",
          "ci" => "none"
        }
      })

    refute Map.has_key?(gate.evaluation_payload, "branch")

    assert DeployMergeReconciler.unrecorded_branch_gates() == %{
             count: 1,
             validation_ids: [gate.id]
           }

    gate
  end

  describe "report_unrecorded_branch_gates/1" do
    test "names the count, every id, and the remedy" do
      log =
        capture_log([level: :info], fn ->
          assert DeployMergeReconciler.report_unrecorded_branch_gates(%{
                   count: 2,
                   validation_ids: ["019f-aaa", "019f-bbb"]
                 }) == :ok
        end)

      assert log =~ "2 pending pr_merged gate(s) record no deploy branch"
      assert log =~ "019f-aaa, 019f-bbb"
      assert log =~ "mix suite.deploy.scope_gate"

      # ONE line, not one per gate. The tick fires every five minutes for
      # every open gate, which is why `poll/5`'s miss sits at `debug`.
      assert length(String.split(log, "record no deploy")) == 2
    end

    test "says nothing at all when the count is zero" do
      log =
        capture_log([level: :info], fn ->
          assert DeployMergeReconciler.report_unrecorded_branch_gates(%{
                   count: 0,
                   validation_ids: []
                 }) == :ok
        end)

      refute log =~ "record no deploy branch"
    end
  end

  describe "handle_info(:tick, …)" do
    setup do
      previous = Application.get_env(:platform, :deploy_merge_reconciler)
      Application.put_env(:platform, :deploy_merge_reconciler, merge_runner: NeverMergedRunner)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:platform, :deploy_merge_reconciler)
          value -> Application.put_env(:platform, :deploy_merge_reconciler, value)
        end
      end)

      :ok
    end

    # THE WIRING. Without this, `report_unrecorded_branch_gates/1` is a
    # function nothing calls and the stage's actual requirement — that the
    # SWEEP announces the condition — is unexercised.
    test "announces the retirement condition for a real unrecorded gate" do
      gate = unrecorded_gate!()

      log =
        capture_log([level: :info], fn ->
          assert {:noreply, %{}} = DeployMergeReconciler.handle_info(:tick, %{})
        end)

      assert log =~ "1 pending pr_merged gate(s) record no deploy branch"
      assert log =~ gate.id

      # The counter and the refusal name the SAME row: the sweep declined to
      # poll it, so the count is reporting on the gate that is actually
      # hung, not on a parallel set that happens to have the same size.
      refute_received {:merged_pr_called, _}
      assert Repo.reload!(gate).status == "pending"
    end

    test "and stays silent once every live gate records a branch" do
      gate = unrecorded_gate!()

      gate
      |> Ecto.Changeset.change(%{
        evaluation_payload: Map.put(gate.evaluation_payload, "branch", "task/019fba18-d074")
      })
      |> Repo.update!()

      assert DeployMergeReconciler.unrecorded_branch_gates().count == 0

      log =
        capture_log([level: :info], fn ->
          assert {:noreply, %{}} = DeployMergeReconciler.handle_info(:tick, %{})
        end)

      refute log =~ "record no deploy branch"

      # Non-vacuity for that silence: the tick DID sweep this gate — it was
      # polled and told no. So the quiet is "nothing to retire", not "the
      # tick never ran".
      assert_received {:merged_pr_called, %{branch: "task/019fba18-d074"}}
    end
  end
end
