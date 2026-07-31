defmodule Mix.Tasks.Suite.Deploy.ScopeGateTest do
  @moduledoc """
  An operator supplies the facts a gate is missing; the RECONCILER still
  performs the observation.

  ## The load-bearing test is a pair, not a single assertion

  "After the command, a sweep passes the gate" is satisfied by a command
  that simply passes the gate itself — which is the one thing this command
  must never do, because `observed_by: "reconciler"` has to keep meaning
  that a poll actually happened. So the happy path measures the SAME sweep,
  with the SAME stub and the SAME script, on both sides of the command: 0
  before, 1 after. Only the pair localizes the change to the payload.

  ## Every refusal gets its own fixture

  A refusal test whose fixture is a valid gate proves only that valid gates
  work: the raise it observes could be coming from any condition, or from
  the command being broken outright. Each test below builds the ONE shape
  it is about, and asserts the gate is byte-identical afterwards — a
  refusal that raised after writing is not a refusal.

  ## `async: false`, and the database is real

  `Platform.DataCase` with the sandbox checked out. `run/1` drives
  `Mix.Task.run("app.start")` and `Mix.shell()`, both global, and the
  fixtures go through `PlanEngine.advance/1` — there is no in-memory path
  here to accidentally exercise instead.

  ## No log assertions, deliberately

  Everything this command says to an operator goes through `Mix.shell().info/1`
  and is read with `capture_io/1`. That matters because `config/test.exs`
  pins Logger to `:warning`: an assertion that captured `Logger.info` at
  that level would pass against a function that logs unconditionally, and
  would need the `Logger.configure/1` + `async: false` treatment
  `DeployMergeReconcilerTickLogTest` uses. Routing the output through the
  shell keeps that trap out of this file rather than working around it.
  """

  use Platform.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Suite.Deploy.ScopeGate
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployMergeReconciler
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Task, as: TaskRecord
  alias Platform.Tasks.Validation

  # Zero webhooks installed, verified 2026-07-31 — the repository class this
  # whole feature exists for.
  @bridge "Startup-Suite/claude-code-suite-channel"
  @bridge_url "https://github.com/Startup-Suite/claude-code-suite-channel"

  # The branch task 019fa63a-02a0 actually pushed, carrying merged PR #644.
  # No derivation in the tree produces this name and
  # `Changelog.extract_task_id_from_branch/1` cannot parse it either
  # (`@branch_prefix` wants eight hex characters after `task/`, and
  # `envelope-` is not hex). That row was closed BY HAND on 2026-07-31 at
  # ~22:08Z, before this command existed; it is kept here as a fixture SHAPE,
  # not as a claim about the live queue.
  @envelope_branch "task/envelope-records-019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37"

  # ── Stub runner ─────────────────────────────────────────────────────────
  #
  # Same mechanics as `deploy_merge_reconciler_test.exs`: `sweep/1` runs in
  # the calling process, so the script lives in — and the calls are reported
  # to — the TEST process. Defined here rather than reached for across files
  # so this file does not depend on another test module's compilation.

  defmodule StubRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeployMergeReconciler.MergeRunner

    @impl true
    def available?, do: :ok

    @impl true
    def merged_pr(%{branch: branch} = query) do
      send(self(), {:merged_pr_called, query})

      Process.get(:stub_results, %{})
      |> Map.get(branch, {:ok, nil})
    end
  end

  defp script(branch, result),
    do: Process.put(:stub_results, Map.put(Process.get(:stub_results, %{}), branch, result))

  defp merged(number) do
    {:ok,
     %{
       number: number,
       url: "https://github.com/#{@bridge}/pull/#{number}",
       merged_at: "2026-07-31T12:09:00Z",
       merge_commit_sha: "326d2b08" <> String.duplicate("a", 32)
     }}
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  # THE LEGACY UNSCOPED SHAPE, minted by the real path rather than hand-built.
  #
  # A project with no `repo_url` and a strategy declaring no `"repos"` makes
  # `Tasks.resolve_deploy_repos/1` answer `[]`, which
  # `resolve_deploy_strategy_with_repos/1` turns into an ABSENT `"repos"`
  # key, which is the clause of `DeployStageBuilder.build_stage/3` that mints
  # ONE gate with no payload at all. That is the row `gate_repo/1`'s nil
  # clause skips — reproduced through production code so it cannot drift from
  # what production actually mints.
  defp unscoped_task!(opts \\ []) do
    {:ok, project} =
      Tasks.create_project(%{name: "ScopeGate unscoped #{unique()}"})

    task =
      insert_task!(
        %{
          project_id: project.id,
          title: "Lands in a repository nobody declared",
          status: "in_progress",
          deploy_target: "production",
          deploy_strategy: %{"type" => "pr_merge", "config" => %{"auto_merge" => false}}
        },
        Keyword.get(opts, :id)
      )

    build(task, opts)
  end

  # The scoped shape stage 1 mints: one declared repo, payload carrying
  # `"repo"`, `"repo_url"`, `"ci"`, `"auto_merge"`, `"merge_method"` AND
  # `"branch"`.
  defp scoped_task!(opts \\ []) do
    {:ok, project} =
      Tasks.create_project(%{
        name: "ScopeGate scoped #{unique()}",
        repo_url: "https://github.com/Startup-Suite/core"
      })

    task =
      insert_task!(
        %{
          project_id: project.id,
          title: "Lands in one declared repository",
          status: "in_progress",
          deploy_target: "production",
          deploy_strategy: %{
            "type" => "pr_merge",
            "config" => %{"auto_merge" => false},
            "repos" => [%{"repo_url" => @bridge_url, "ci" => "none"}]
          }
        },
        Keyword.get(opts, :id)
      )

    build(task, opts)
  end

  defp build(task, opts) do
    {:ok, plan} =
      Tasks.create_plan(%{
        task_id: task.id,
        status: "approved",
        version: Keyword.get(opts, :version, 1)
      })

    {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(s1.id)
    {:ok, plan} = PlanEngine.advance(plan.id)

    stage = Enum.find(plan.stages, &(&1.name == "Deploy: PR merge"))

    [gate] =
      Repo.all(
        from(v in Validation,
          where: v.stage_id == ^stage.id and v.kind == "pr_merged",
          order_by: v.inserted_at
        )
      )

    %{task: task, plan: plan, stage: stage, gate: gate}
  end

  # `Task.changeset/2` does not cast `:id` — the schema autogenerates a
  # UUIDv7 — so a pinned id goes on as a `put_change` before the insert.
  # Same route as `deploy_merge_reconciler_test.exs` and
  # `stack_deployer_test.exs:780-793`.
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

  defp unique, do: System.unique_integer([:positive])

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)

  defp args(gate, opts \\ []) do
    [gate.id] ++
      ["--repo-url", Keyword.get(opts, :repo_url, @bridge_url)] ++
      ["--branch", Keyword.get(opts, :branch, @envelope_branch)]
  end

  # A refusal that raised AFTER writing is not a refusal. Every refusal test
  # runs the gate through this, so "unchanged" is one definition rather than
  # six partial ones.
  defp assert_unchanged(before) do
    now = reload(before)

    assert now.evaluation_payload == before.evaluation_payload
    assert now.status == before.status
    assert now.evidence == before.evidence
    assert now.evaluated_by == before.evaluated_by
    assert now.evaluated_at == before.evaluated_at
  end

  # ── The load-bearing pair ───────────────────────────────────────────────

  describe "run/1 — end to end, measured on both sides of the command" do
    test "the same sweep returns 0 before the command and 1 after it" do
      %{gate: gate} = unscoped_task!(id: "019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37")

      # The fixture really is the legacy shape, asserted rather than assumed.
      assert gate.evaluation_payload == nil

      # Scripted for the branch the operator is ABOUT to supply, so the zero
      # below cannot come from the stub having nothing to say.
      script(@envelope_branch, merged(644))

      # ── BEFORE ──────────────────────────────────────────────────────────
      assert DeployMergeReconciler.sweep(runner: StubRunner) == 0

      before = reload(gate)
      assert before.status == "pending"
      assert before.evidence == %{}

      # And the runner was never even asked: a nil payload is skipped before
      # any branch is considered, so there is nothing here for a recorded
      # branch to fix on its own.
      refute_received {:merged_pr_called, _}

      # ── THE COMMAND ─────────────────────────────────────────────────────
      output = capture_io(fn -> assert ScopeGate.run(args(gate)) == :ok end)

      scoped = reload(gate)

      assert scoped.evaluation_payload == %{
               "repo" => @bridge,
               "repo_url" => @bridge_url,
               "branch" => @envelope_branch
             }

      # IT DID NOT PASS THE GATE. If it had, the "after" sweep below would
      # be measuring nothing at all.
      assert scoped.status == "pending"
      assert scoped.evidence == %{}
      assert scoped.evaluated_by == nil
      assert scoped.evaluated_at == nil

      # It prints the payload and says the remaining step is a wait.
      assert output =~ @bridge
      assert output =~ @envelope_branch
      assert output =~ "the next reconciler sweep will poll this gate"

      # ── AFTER — same runner, same script, same sweep ────────────────────
      assert DeployMergeReconciler.sweep(runner: StubRunner) == 1

      passed = reload(gate)
      assert passed.status == "passed"
      assert passed.evaluated_by == "deploy_merge_reconciler"
      assert passed.evidence["pr_number"] == 644
      assert passed.evidence["repo"] == @bridge

      # The provenance key. The observation was made by the sweeper polling,
      # not by the command asserting.
      assert passed.evidence["observed_by"] == "reconciler"

      # Non-vacuity for the 1: the sweep asked about exactly the repository
      # and branch the operator supplied.
      assert_received {:merged_pr_called, %{repo: @bridge_url, branch: @envelope_branch}}
    end

    test "the scoped gate is polled on the supplied branch and no other" do
      %{gate: gate} = unscoped_task!(id: "019fa63a-02a0-7c9e-b3d1-5f2ae4d81c38")

      capture_io(fn -> ScopeGate.run(args(gate)) end)

      # Nothing merged for this branch. The point is WHICH question was
      # asked — a derivation coming back would ask about
      # `task/019fa63a-02a0-…` instead.
      assert DeployMergeReconciler.sweep(runner: StubRunner) == 0

      assert_received {:merged_pr_called, %{branch: @envelope_branch}}
      refute_received {:merged_pr_called, %{branch: "task/019fa63a-02a0-7c9e-b3d1-5f2ae4d81c38"}}
    end

    test "keys the gate already carries survive the repair" do
      # A scoped-but-branchless gate is the OTHER population this repairs:
      # minted between `d63abdc0` reaching production and the recording
      # change landing. Its payload carries `"ci"` and `"auto_merge"`, which
      # `AutoMerger.should_auto_merge?/2` and
      # `GithubWebhookController.gate_ci/1` read. Replacing the payload
      # wholesale — the literal three-key write — would drop an
      # `auto_merge: false` back to the strategy-wide answer and could
      # authorize a machine merge the deploy stage was gated against.
      %{gate: gate} = scoped_task!()

      branchless =
        gate
        |> Ecto.Changeset.change(%{
          evaluation_payload: Map.delete(gate.evaluation_payload, "branch")
        })
        |> Repo.update!()

      assert branchless.evaluation_payload["ci"] == "none"
      assert branchless.evaluation_payload["auto_merge"] == false
      assert DeployMergeReconciler.unrecorded_branch_gates().count == 1

      capture_io(fn -> assert ScopeGate.run(args(branchless)) == :ok end)

      repaired = reload(branchless)
      assert repaired.evaluation_payload["branch"] == @envelope_branch
      assert repaired.evaluation_payload["ci"] == "none"
      assert repaired.evaluation_payload["auto_merge"] == false
      assert repaired.evaluation_payload["merge_method"] == "squash"

      # And the retirement counter, which is what pointed the operator here,
      # now agrees the row is repaired.
      assert DeployMergeReconciler.unrecorded_branch_gates() == %{count: 0, validation_ids: []}
    end

    test "a blank recorded branch is repairable — the counter counts it, so this must fix it" do
      # The deliberate consequence of keying "already recorded" on
      # `present?/1` rather than on key presence. `unrecorded_branch_gates/0`
      # counts a blank branch and `refuse/2` declines to poll it; if this
      # command refused it as "already recorded", the row the refusal's own
      # log line points here would be unrepairable by the command it names.
      %{gate: gate} = scoped_task!()

      blank =
        gate
        |> Ecto.Changeset.change(%{
          evaluation_payload: Map.put(gate.evaluation_payload, "branch", "   ")
        })
        |> Repo.update!()

      assert Map.has_key?(blank.evaluation_payload, "branch"),
             "the fixture must KEEP the key, or this is the absent-key case again"

      assert DeployMergeReconciler.unrecorded_branch_gates().count == 1

      capture_io(fn -> assert ScopeGate.run(args(blank)) == :ok end)

      assert reload(blank).evaluation_payload["branch"] == @envelope_branch
      assert DeployMergeReconciler.unrecorded_branch_gates() == %{count: 0, validation_ids: []}
    end
  end

  # ── The five conditions borrowed from the sweeper's own scoping ─────────

  describe "run/1 — refusals derived from `candidates/0`" do
    test "refuses a validation id that does not exist" do
      id = Platform.Types.UUIDv7.generate()

      assert_raise Mix.Error, ~r/no validation #{id}/, fn ->
        ScopeGate.run([id, "--repo-url", @bridge_url, "--branch", @envelope_branch])
      end
    end

    test "refuses an id that is not a well-formed uuid, including the 16-byte case" do
      # THE GUARD IS SHOWN TO BE LOAD-BEARING FIRST. Without it,
      # `why_not_live/1`'s `where: v.id == ^id` raises `Ecto.Query.CastError`
      # rather than returning a reason — a stack trace out of a CLI is not a
      # named refusal. Demonstrated against the real query so the assertion
      # below is about a hazard that exists.
      assert_raise Ecto.Query.CastError, fn ->
        Repo.one(from(v in Validation, where: v.id == ^"not-a-uuid"))
      end

      for id <- ["not-a-uuid", "higginshigginsxx", ""] do
        assert_raise Mix.Error, ~r/not a well-formed validation id/, fn ->
          ScopeGate.run([id, "--repo-url", @bridge_url, "--branch", @envelope_branch])
        end
      end

      # `"higginshigginsxx"` is in that list for a specific reason: it is
      # sixteen bytes, and bare `Ecto.UUID.cast/1` HEX-ENCODES a 16-byte
      # binary into a valid-looking uuid instead of rejecting it — the gap
      # `Platform.UUID`'s moduledoc records. Pinned so a future
      # "simplification" of the guard to `Ecto.UUID.cast/1` fails here.
      assert {:ok, _} = Ecto.UUID.cast("higginshigginsxx")
      refute Platform.UUID.valid?("higginshigginsxx")
    end

    test "accepts an UPPERCASE uuid — persisted ids are lowercase" do
      # `Platform.UUID.valid?/1` passes an uppercase uuid, so without the
      # downcase in `live_gate/1` the `Enum.find/2` over `candidates/0` would
      # miss and an operator pasting a copied id would be told the gate is
      # not a live candidate when it is.
      %{gate: gate} = unscoped_task!()

      capture_io(fn ->
        assert ScopeGate.run(args(%{gate | id: String.upcase(gate.id)})) == :ok
      end)

      assert reload(gate).evaluation_payload["branch"] == @envelope_branch
    end

    test "refuses a gate whose kind is not `pr_merged`" do
      %{stage: stage} = unscoped_task!()

      {:ok, ci} =
        Tasks.create_validation(%{
          stage_id: stage.id,
          kind: "ci_passed",
          evaluation_payload: nil
        })

      assert_raise Mix.Error, ~r/is not a `pr_merged` gate/, fn ->
        ScopeGate.run(args(ci))
      end

      assert_unchanged(ci)
    end

    test "refuses a gate that has already been dispositioned" do
      # Two gates on one stage, so passing one leaves the stage RUNNING and
      # the refusal below is attributable to `status` alone. With a single
      # gate the pass would also complete the stage, and the test would go on
      # passing with the pending filter deleted.
      %{stage: stage, gate: scoped} = scoped_task!()

      {:ok, legacy} = Tasks.create_validation(%{stage_id: stage.id, kind: "pr_merged"})
      assert legacy.evaluation_payload == nil

      {:ok, _} =
        PlanEngine.evaluate_validation(legacy.id, %{
          status: "passed",
          evidence: %{"pr_url" => "https://github.com/#{@bridge}/pull/644"},
          evaluated_by: "operator"
        })

      settled = reload(legacy)
      assert settled.status == "passed"
      assert Repo.get!(Platform.Tasks.Stage, stage.id).status == "running"
      assert reload(scoped).status == "pending"

      assert_raise Mix.Error, ~r/is not pending/, fn -> ScopeGate.run(args(settled)) end

      assert_unchanged(settled)
    end

    test "refuses a gate whose stage is not running" do
      %{stage: stage, gate: gate} = unscoped_task!()

      {:ok, _} = stage |> Ecto.Changeset.change(%{status: "passed"}) |> Repo.update()

      # The gate itself is untouched — still pending, still nil-payload. Only
      # the stage moved, so the refusal is attributable to the stage.
      assert reload(gate).status == "pending"

      assert_raise Mix.Error, ~r/on a stage that is not running/, fn ->
        ScopeGate.run(args(gate))
      end

      assert_unchanged(gate)
    end

    test "refuses a gate on a superseded plan version" do
      %{task: task, stage: stage, gate: gate} = unscoped_task!()

      {:ok, v2} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 2})
      assert Tasks.current_plan(task.id).id == v2.id

      # v1's deploy stage stays RUNNING and its gate stays pending — only
      # `current_plan/1`'s answer moved.
      assert Repo.get!(Platform.Tasks.Stage, stage.id).status == "running"
      assert reload(gate).status == "pending"

      assert_raise Mix.Error, ~r/superseded plan version/, fn -> ScopeGate.run(args(gate)) end

      assert_unchanged(gate)
    end
  end

  # ── The two refusals this command owns ─────────────────────────────────

  describe "run/1 — refusals this command owns" do
    test "refuses to overwrite a payload that already records a branch" do
      # A freshly-minted scoped gate. Stage 1 records the branch at mint
      # time, so this fixture needs no doctoring — which is the point: the
      # overwhelming majority of live gates are exactly this shape, and the
      # command must decline all of them.
      %{task: task, gate: gate} = scoped_task!(id: "019fb90f-36e3-7fd6-a416-f128f4c0190f")

      recorded = gate.evaluation_payload["branch"]
      assert recorded == "task/019fb90f-36e3-7fd6-a416-f128f4c0190f"
      assert recorded != @envelope_branch, "the fixture must not already record the new value"
      assert task.id == "019fb90f-36e3-7fd6-a416-f128f4c0190f"

      assert_raise Mix.Error, ~r/already records branch/, fn -> ScopeGate.run(args(gate)) end

      # Byte-identical. A repair that raised after writing has still
      # re-pointed a task at a branch it never pushed.
      assert_unchanged(gate)
      assert reload(gate).evaluation_payload["branch"] == recorded
    end

    test "refuses a --repo-url that will not normalize to a slug" do
      # `gate_repo/1` skips a gate with no canonical slug — the same guard
      # `Tasks.resolve_deploy_repos/1` keeps a nil-slug entry for. Writing
      # `"repo" => nil` here would produce a gate that is scoped, unpollable,
      # AND no longer matchable by the unscoped webhook path: the hang moved
      # somewhere harder to see.
      %{gate: gate} = unscoped_task!()

      assert Platform.Tasks.RepoRef.slug("gitlab.com/Startup-Suite/core") == nil

      assert_raise Mix.Error, ~r/does not normalize to an `owner\/name` slug/, fn ->
        ScopeGate.run(args(gate, repo_url: "gitlab.com/Startup-Suite/core"))
      end

      assert_unchanged(gate)

      # And the same gate with a normalizable URL goes through, so the
      # refusal above is about the URL and not about the fixture.
      capture_io(fn -> assert ScopeGate.run(args(gate)) == :ok end)
      assert reload(gate).evaluation_payload["repo"] == @bridge
    end
  end

  # ── Argument shape ─────────────────────────────────────────────────────

  describe "run/1 — argument refusals" do
    test "refuses a blank --branch rather than writing a value the sweeper refuses back" do
      %{gate: gate} = unscoped_task!()

      assert_raise Mix.Error, ~r/--branch was supplied but is blank/, fn ->
        ScopeGate.run(args(gate, branch: "   "))
      end

      assert_unchanged(gate)
    end

    test "refuses a missing --repo-url and a missing --branch by name" do
      %{gate: gate} = unscoped_task!()

      assert_raise Mix.Error, ~r/--repo-url is required/, fn ->
        ScopeGate.run([gate.id, "--branch", @envelope_branch])
      end

      assert_raise Mix.Error, ~r/--branch is required/, fn ->
        ScopeGate.run([gate.id, "--repo-url", @bridge_url])
      end

      assert_unchanged(gate)
    end

    test "refuses no validation id, and refuses two" do
      %{gate: gate} = unscoped_task!()

      assert_raise Mix.Error, ~r/a validation id is required/, fn ->
        ScopeGate.run(["--repo-url", @bridge_url, "--branch", @envelope_branch])
      end

      assert_raise Mix.Error, ~r/expected exactly one validation id, got 2/, fn ->
        ScopeGate.run([gate.id, gate.id, "--repo-url", @bridge_url, "--branch", @envelope_branch])
      end

      assert_unchanged(gate)
    end

    test "refuses an unrecognized switch rather than silently ignoring it" do
      %{gate: gate} = unscoped_task!()

      assert_raise Mix.Error, ~r/unrecognized option/, fn ->
        ScopeGate.run(args(gate) ++ ["--pass", "true"])
      end

      assert_unchanged(gate)
    end
  end
end
