defmodule Platform.Tasks.DeployMergeReconciler do
  @moduledoc """
  Observes merges in repositories that cannot tell us about them.

  ## Why this exists

  Task 019fa63a stages 2-3 split the deploy stage's single `pr_merged` gate
  into one gate PER repository, so a merge in repo A can no longer mark repo
  B as deployed. That fix is correct and, on its own, incomplete — because of
  a fact about the actual repositories involved.

  Verified 2026-07-27 and again 2026-07-31 via `gh api repos/<r>/hooks`:
  `Startup-Suite/core` has two active webhooks (one being
  `https://suite.example.com/api/webhooks/github`, events
  `check_suite`, `pull_request`, `workflow_run`).
  `Startup-Suite/openclaw-suite-channel` and
  `Startup-Suite/claude-code-suite-channel` have ZERO webhooks installed.
  Suite receives nothing whatsoever from the bridge repos.

  So the per-repo gates convert a silent-completion bug into a silent-HANG
  bug: repo B's `pr_merged` sits pending forever because no
  `pull_request.closed` delivery can ever reach it. A hang nobody can see is
  the same defect in new clothes. This sweeper closes it from the other side —
  it POLLS the repositories that cannot push to us.

  ## What a pass here means, and what it does not

  A gate passed by this module carries `"observed_by" => "reconciler"` in its
  evidence, and that key is load-bearing. A webhook delivery and a polled
  observation are different facts with different latency and different
  provenance, and evidence that read identically would erase the distinction.

  Both, equally, mean MERGED — not SHIPPED. Measured 2026-07-31: task
  019fa609 reached `done` at 12:09 CDT on the merge of PR #640, while moon
  was still serving PR #639's image from 10:43. `pr_merged` is a merge
  observation. Deploy completion is a separate fact that this module does not
  claim to have.

  ## It never merges

  `MergeRunner` has no merge callback and this module never asks for one.
  Machine-merging stays with `Platform.Tasks.AutoMerger`, which since stage 4
  refuses any repository declaring `ci: "none"` — the ticket's hard
  constraint is that a green CI in repo A authorizes nothing in repo B, and
  the bridge repos have no CI at all. Their gates therefore open only on a
  merge a HUMAN performed and this sweeper subsequently saw. That is the
  whole design: observation is safe to automate, merging is not.

  ## Scoping

  Candidates are pending `pr_merged` validations on RUNNING stages, filtered
  to the rows whose plan is the task's `Tasks.current_plan/1`. That filter is
  applied through `current_plan/1` itself rather than a hand-rolled
  `p.status == "approved"` join predicate: `current_plan/1` selects
  `status in ["approved", "completed"]` ordered by `version desc`, and an
  approved-only filter answers `nil` for a task whose plan has completed —
  which is how `StackDeployer.review_readiness/1` once blocked a gate
  indefinitely (recorded on the org's process-patterns page). One derivation
  of "which plan is live", used everywhere.

  ## Not verifiable from the box this was written on

  Whether the deployed `core-platform` container can reach GitHub and holds a
  token with read access to the bridge repos. If it cannot, this degrades to
  the `available?/0` no-op and the bridge gate must be passed by an operator
  with evidence — a visible, named state, which is the point. Installing the
  webhook on the two bridge repos would remove the need to poll entirely;
  that is a repo-admin action rather than a code change and is filed
  separately.
  """

  use GenServer

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Orchestration.HeartbeatScheduler
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.DeployMergeReconciler.GhMergeRunner
  alias Platform.Tasks.Plan
  alias Platform.Tasks.PlanEngine
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Task
  alias Platform.Tasks.Validation

  @tick_interval_ms 5 * 60 * 1000

  @default_runner GhMergeRunner

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Run one sweep synchronously. Returns the number of gates passed.

  Public and synchronous so the behaviour under test is the sweep itself
  rather than GenServer scheduling — the process is not started in the test
  environment at all.

  Options:

    * `:runner` — override the configured `MergeRunner` implementation.
  """
  @spec sweep(keyword()) :: non_neg_integer()
  def sweep(opts \\ []) do
    runner = Keyword.get(opts, :runner, merge_runner())

    case runner.available?() do
      :ok ->
        do_sweep(runner)

      # ONE error per sweep, not one per gate, and a count of zero rather
      # than a raise. A tool we could not run is never a merge and never a
      # failure.
      {:error, :gh_unavailable, message} ->
        Logger.error("[deploy_merge_reconciler] #{message} — no gates polled this pass")
        0
    end
  end

  @doc """
  The configured `MergeRunner` implementation.

  Public so tests can pin the production default without mutating
  application env from an async case.
  """
  @spec merge_runner() :: module()
  def merge_runner do
    :platform
    |> Application.get_env(:deploy_merge_reconciler, [])
    |> Keyword.get(:merge_runner, @default_runner)
  end

  @impl true
  def init(_opts) do
    schedule_next_tick()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    count = sweep()

    if count > 0 do
      Logger.info("[deploy_merge_reconciler] passed #{count} pr_merged gate(s) by polling")
    end

    schedule_next_tick()
    {:noreply, state}
  end

  defp schedule_next_tick, do: Process.send_after(self(), :tick, @tick_interval_ms)

  defp do_sweep(runner) do
    candidates()
    |> Enum.reduce(0, fn row, passed -> passed + reconcile(row, runner) end)
  end

  # ── Which gates are this sweeper's business ─────────────────────────────

  defp candidates do
    query =
      from(v in Validation,
        join: s in Stage,
        on: s.id == v.stage_id,
        join: p in Plan,
        on: p.id == s.plan_id,
        join: t in Task,
        on: t.id == p.task_id,
        where: v.kind == "pr_merged",
        where: v.status == "pending",
        where: s.status == "running",
        order_by: [asc: s.position, asc: v.inserted_at],
        select: %{validation: v, task: t, plan_id: p.id}
      )

    query
    |> Repo.all()
    |> scope_to_current_plans()
  end

  # `current_plan/1` is queried once per distinct task, not once per gate: a
  # two-repo deploy stage carries two rows on ONE plan and they cannot
  # disagree about which plan is live.
  defp scope_to_current_plans(rows) do
    live =
      rows
      |> Enum.map(& &1.task.id)
      |> Enum.uniq()
      |> Map.new(fn task_id -> {task_id, current_plan_id(task_id)} end)

    Enum.filter(rows, fn row ->
      case Map.get(live, row.task.id) do
        nil -> false
        plan_id -> plan_id == row.plan_id
      end
    end)
  end

  defp current_plan_id(task_id) do
    case Tasks.current_plan(task_id) do
      %Plan{id: id} -> id
      _ -> nil
    end
  end

  # ── One gate ────────────────────────────────────────────────────────────

  defp reconcile(%{validation: validation, task: task}, runner) do
    case gate_repo(validation) do
      :skip ->
        0

      {:ok, %{target: target, slug: slug}} ->
        ask(runner, validation, task, target, slug)
    end
  end

  defp ask(runner, validation, task, target, slug) do
    branch = branch_for(task)

    case runner.merged_pr(%{repo: target, branch: branch}) do
      {:ok, nil} ->
        # `debug` deliberately. This fires every five minutes for every open
        # deploy gate and is the overwhelmingly common answer; promoting it
        # would drown the log for zero signal. Same reasoning as the `debug`
        # on the no-pending-gate branch of
        # `GithubWebhookController.auto_merge_delivering_repo/3`.
        Logger.debug(
          "[deploy_merge_reconciler] no merged PR for #{branch} on #{slug} " <>
            "(validation #{validation.id})"
        )

        0

      {:ok, pr} ->
        pass(validation, slug, pr, branch)

      # A failed question is not a "no". Leave the gate pending and say so
      # above `debug` — an unreachable GitHub is an operator-visible
      # condition, unlike an unmerged PR.
      {:error, reason} ->
        Logger.warning(
          "[deploy_merge_reconciler] could not poll #{slug} for #{branch}: " <>
            "#{inspect(reason)} — leaving validation #{validation.id} pending"
        )

        0
    end
  end

  defp pass(validation, slug, pr, branch) do
    evidence = %{
      "pr_url" => pr.url,
      "pr_number" => pr.number,
      "merged_at" => pr.merged_at,
      "merge_commit_sha" => pr.merge_commit_sha,
      "repo" => slug,
      # The provenance key. A webhook-passed gate does not carry this, so
      # "was this merge pushed to us or did we go looking?" stays answerable
      # from the evidence alone.
      "observed_by" => "reconciler"
    }

    case PlanEngine.evaluate_validation(validation.id, %{
           status: "passed",
           evidence: evidence,
           evaluated_by: "deploy_merge_reconciler"
         }) do
      {:ok, _updated} ->
        Logger.info(
          "[deploy_merge_reconciler] #{slug} PR ##{pr.number} merged for #{branch}; " <>
            "passed validation #{validation.id}"
        )

        1

      {:error, reason} ->
        Logger.error(
          "[deploy_merge_reconciler] observed #{slug} PR ##{pr.number} merged for " <>
            "#{branch} but could not record it on validation #{validation.id}: " <>
            inspect(reason)
        )

        0
    end
  end

  # ── Reading the gate ────────────────────────────────────────────────────

  # `DeployStageBuilder.repo_validation/1` writes BOTH `"repo"` (canonical
  # slug, what the webhook matcher compares on) and `"repo_url"` (what the
  # human declared). `gh -R` is handed the URL, matching
  # `AutoMerger.execute_merge/3`; the slug is what lands in evidence, so the
  # polled and delivered paths agree on how a repository is named.
  defp gate_repo(%Validation{evaluation_payload: payload}) when is_map(payload) do
    repo_url = Map.get(payload, "repo_url")
    slug = Map.get(payload, "repo") || Platform.Tasks.RepoRef.slug(repo_url)

    cond do
      # A gate with no canonical slug is a DECLARED repository whose URL
      # would not normalize — `Tasks.resolve_deploy_repos/1` keeps it with
      # `slug: nil` precisely so it can never be matched by accident. It must
      # be unmatchable by polling too, or the guard holds on one path and
      # leaks on the other. Its task hangs visibly, which is the intent.
      not present?(slug) ->
        :skip

      present?(repo_url) ->
        {:ok, %{target: repo_url, slug: slug}}

      true ->
        {:ok, %{target: slug, slug: slug}}
    end
  end

  # A nil payload is a LEGACY UNSCOPED gate: the single-repo webhook path,
  # minted before gates carried a repository. It is not this sweeper's
  # business — `GithubWebhookController.select_unscoped_validation/3` owns
  # the rules for when such a gate may pass, and polling one would need a
  # repository this row does not name.
  defp gate_repo(_), do: :skip

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # The branch name is `HeartbeatScheduler.member_slug/1`'s answer, not a
  # second derivation of it. The dispatch prompt tells the executor to push
  # `task/<member_slug>`; if this module computed its own slug the poller
  # would ask about a branch nobody pushed and report "not merged" forever.
  defp branch_for(%Task{} = task), do: "task/" <> HeartbeatScheduler.member_slug(task)
end
