defmodule Platform.Tasks.DeployGateBranchTipTest do
  @moduledoc """
  The MINT-TIME half of task 01a06d6d stage 2, end to end.

  ## Why this file exists separately from the two unit suites

  `deploy_stage_builder_test.exs` proves the builder writes a tips map onto
  the right gates. `deploy_merge_reconciler_test.exs` proves the sweeper
  compares a recorded tip against a merged PR's head. Both pass, in full,
  against a system where the two halves never meet — a builder writing
  `"branch_tip_sha"` and a reader looking for `"tip_sha"` satisfies every
  assertion in both files, and the production gate silently keeps only the
  ordering check forever.

  What is unpinned by those two suites is the SEAM: that `PlanEngine`
  actually resolves a tip when it injects a deploy stage, that it reaches
  `BranchProvisioner` to do so, that the value lands under the key the
  reconciler reads, and that a real merge is then judged against it. Every
  test below drives the real injection path — `PlanEngine.advance/1` on a
  real plan — rather than calling the builder directly.

  ## `async: false`

  The runner is pinned through `Application.put_env`, which is global. Same
  shape and same reason as
  `Platform.Orchestration.TaskRouterBranchProvisioningTest`.

  ## The negative control

  A file that only asserted "the tip is recorded" would pass against a
  provisioner that answered one hardcoded sha for every repository. So the
  stub answers a DIFFERENT sha per repository and the assertions pin which
  sha landed where, and the sweep case below requires one gate to pass and
  its sibling — polled in the same sweep, by the same runner, reporting a
  merge — to hang.
  """
  use Platform.DataCase, async: false

  import ExUnit.CaptureLog

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployMergeReconciler
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Validation

  @core "Startup-Suite/core"
  @bridge "Startup-Suite/claude-code-suite-channel"

  @core_tip "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"
  @bridge_tip "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222b"

  # ── Stub provisioner runners ─────────────────────────────────────────────

  # Answers a DISTINCT sha per repository. A stub returning one sha for
  # everything would satisfy "a tip was recorded" while hiding the bug this
  # file cares most about — the same sha written onto every gate, which hangs
  # every repository but one.
  defmodule PerRepoTipRunner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(%{repo: "Startup-Suite/core"}),
      do: {:ok, "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}

    def branch_head_sha(%{repo: "Startup-Suite/claude-code-suite-channel"}),
      do: {:ok, "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222b"}

    def branch_head_sha(_args), do: {:error, :ref_not_found}

    @impl true
    def default_branch_sha(_args), do: {:error, :not_stubbed}
    @impl true
    def list_matching_refs(_args), do: {:error, :not_stubbed}
    @impl true
    def create_ref(_args), do: {:error, :not_stubbed}
    @impl true
    def compare_refs(_args), do: {:error, :not_stubbed}
  end

  # Core resolves; the bridge does not. The PARTIAL case is the one that
  # decides whether a flaky lookup degrades one gate or the whole stage.
  defmodule PartialTipRunner do
    @moduledoc false
    @behaviour Platform.Tasks.BranchProvisioner.Runner

    @impl true
    def branch_head_sha(%{repo: "Startup-Suite/core"}),
      do: {:ok, "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"}

    def branch_head_sha(_args), do: {:error, {:gh_error, "HTTP 500: Server Error"}}

    @impl true
    def default_branch_sha(_args), do: {:error, :not_stubbed}
    @impl true
    def list_matching_refs(_args), do: {:error, :not_stubbed}
    @impl true
    def create_ref(_args), do: {:error, :not_stubbed}
    @impl true
    def compare_refs(_args), do: {:error, :not_stubbed}
  end

  # ── Stub merge runner ────────────────────────────────────────────────────

  # Reads its script out of the TEST process dictionary — `sweep/1` is
  # synchronous and runs here, so no global state is needed. Same mechanic as
  # `deploy_merge_reconciler_test.exs`.
  defmodule StubMergeRunner do
    @moduledoc false
    @behaviour Platform.Tasks.DeployMergeReconciler.MergeRunner

    @impl true
    def available?, do: :ok

    @impl true
    def merged_pr(%{repo: repo}) do
      :stub_results
      |> Process.get(%{})
      |> Enum.find_value({:ok, nil}, fn {slug, result} ->
        if String.contains?(repo, slug), do: result
      end)
    end
  end

  defp script(slug, result),
    do: Process.put(:stub_results, Map.put(Process.get(:stub_results, %{}), slug, result))

  defp merged(number, head_sha, merged_at) do
    {:ok,
     %{
       number: number,
       url: "https://github.com/x/pull/#{number}",
       merged_at: merged_at,
       merge_commit_sha: "cccc3333cccc3333cccc3333cccc3333cccc3333",
       head_sha: head_sha
     }}
  end

  # ── Fixture ──────────────────────────────────────────────────────────────

  defp pin_runner(module) do
    previous = Application.get_env(:platform, :branch_provisioner, [])
    Application.put_env(:platform, :branch_provisioner, runner: module)
    on_exit(fn -> Application.put_env(:platform, :branch_provisioner, previous) end)
  end

  # Drives the REAL injection path: a plan whose only stage passes, which is
  # what makes `PlanEngine` mint the deploy stage. Calling the builder
  # directly here would test nothing this file exists to test.
  defp deploying_two_repo_task! do
    {:ok, project} =
      Tasks.create_project(%{
        name: "Branch tip #{System.unique_integer([:positive])}",
        repo_url: "https://github.com/#{@core}"
      })

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Lands in two repositories",
        status: "in_review",
        deploy_target: "production",
        deploy_strategy: %{
          "type" => "pr_merge",
          "config" => %{"auto_merge" => false},
          "repos" => [
            %{"repo_url" => "https://github.com/#{@core}", "ci" => "required"},
            %{"repo_url" => "https://github.com/#{@bridge}", "ci" => "none"}
          ]
        }
      })

    {:ok, plan} = Tasks.create_plan(%{task_id: task.id, status: "approved", version: 1})
    {:ok, s1} = Tasks.create_stage(%{plan_id: plan.id, position: 1, name: "Build"})
    {:ok, _} = PlanEngine.start_stage(s1.id)
    {:ok, plan} = PlanEngine.advance(plan.id)

    stage = Enum.find(plan.stages, &(&1.name == "Deploy: PR merge"))

    gates =
      Repo.all(from(v in Validation, where: v.stage_id == ^stage.id and v.kind == "pr_merged"))
      |> Map.new(fn v -> {v.evaluation_payload["repo"], v} end)

    %{task: task, plan: plan, stage: stage, gates: gates}
  end

  defp reload(%Validation{id: id}), do: Repo.get!(Validation, id)

  defp after_stage(stage, offset) do
    Repo.get!(Platform.Tasks.Stage, stage.id).started_at
    |> DateTime.add(offset, :second)
    |> DateTime.to_iso8601()
  end

  # ── The seam ─────────────────────────────────────────────────────────────

  describe "PlanEngine deploy-stage injection" do
    test "records each repository's branch tip under the key the reconciler reads" do
      pin_runner(PerRepoTipRunner)

      %{gates: gates} = deploying_two_repo_task!()

      assert gates[@core].evaluation_payload["branch_tip_sha"] == @core_tip
      assert gates[@bridge].evaluation_payload["branch_tip_sha"] == @bridge_tip

      # The two shas differ, so neither assertion above can be satisfied by a
      # single value written everywhere.
      refute @core_tip == @bridge_tip
    end

    test "a repository whose tip lookup fails records nil without disturbing its sibling" do
      pin_runner(PartialTipRunner)

      log = capture_log(fn -> send(self(), {:fixture, deploying_two_repo_task!()}) end)
      assert_received {:fixture, %{gates: gates}}

      assert gates[@core].evaluation_payload["branch_tip_sha"] == @core_tip
      assert gates[@bridge].evaluation_payload["branch_tip_sha"] == nil

      # The degraded gate is announced when it is MINTED, not left to be
      # discovered hours later when a merge is refused for no visible reason.
      # A real failure is a `warning`; only the deliberately-disabled runner
      # is quiet.
      assert log =~ "[warning]"
      assert log =~ @bridge
      assert log =~ "branch_tip_sha"
    end
  end

  # ── Mint and sweep, in one run ───────────────────────────────────────────

  describe "a minted tip is what the sweeper compares against" do
    # THE integration claim. Both repositories report a merge, both merges
    # postdate the stage, so stage 1's ordering check passes both. They differ
    # only in whether the PR's head is the tree the gate was minted for.
    #
    # If the mint-time key and the read-time key ever drift apart, both gates
    # pass here and this goes red.
    test "the repo whose PR merged the minted tip passes; its sibling hangs" do
      pin_runner(PerRepoTipRunner)

      %{gates: gates, stage: stage} = deploying_two_repo_task!()
      fresh = after_stage(stage, 30)

      script(@core, merged(801, @core_tip, fresh))
      # A force-push: the bridge's PR merged some other tree entirely.
      script(@bridge, merged(802, "dddd4444dddd4444dddd4444dddd4444dddd4444", fresh))

      log =
        capture_log(fn ->
          assert DeployMergeReconciler.sweep(runner: StubMergeRunner) == 1
        end)

      assert reload(gates[@core]).status == "passed"
      assert reload(gates[@core]).evidence["head_sha"] == @core_tip

      assert reload(gates[@bridge]).status == "pending"
      assert reload(gates[@bridge]).evidence == %{}

      assert log =~ "did not carry the reviewed tree"
      assert log =~ @bridge_tip
    end
  end
end
