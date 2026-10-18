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
  Burrow receives nothing whatsoever from the bridge repos.

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

  ## A merge must POSTDATE the stage it is offered as evidence for

  `gh pr list --head` looks backwards over all time, so "a PR from this
  branch merged" is not the same claim as "a PR from this branch merged for
  this stage". Until task 01a06d6d this module conflated them and passed
  gates on merges hours older than the stage that minted them; see
  `merge_postdates_stage?/2` for the live specimen and the reasoning. A merge
  whose time is unknown, unparseable, or not strictly after the stage's
  `started_at` leaves the gate pending at `warning` — it is never a failure,
  and never a pass.

  This bounds WHEN, not WHAT: on its own it does not establish that the
  merged commit contains this stage's work. Task 01a0e663 added a WHAT
  check — `merge_carries_reviewed_tree?/2` (does `head_sha` equal the
  gate's recorded `branch_tip_sha`?), with a narrow accept-by-author-and-
  window exception for a legitimate fix-forward push after review; see "Is
  this merge THE TREE the gate was minted for?" below. It is not general
  containment or ancestry — `main` squash-merges, so `git merge-base
  --is-ancestor` is deliberately never used (see the reasoning there) — it
  answers only "did the reviewed tip ship, or a same-author, post-stage-
  start fix-forward of it?".

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

  ## The transitional refusal branch, and how to know when it can go

  `ask/7` splits on whether the gate RECORDS a deploy branch. A gate minted
  before `DeployStageBuilder.repo_validation/3` began writing `"branch"`
  does not, and `refuse/2` leaves it pending at `warning` rather than
  guessing a name. That branch is transitional and its population is
  bounded: gates with a nil payload were never this sweeper's business, and
  scoped payloads exist only from `d63abdc0` (production 20:47Z
  2026-07-31), so only gates minted between that deploy and the recording
  change landing can reach it. It drains as those tasks finish.

  A transitional path with no signal for "no longer needed" becomes
  permanent. So it is COUNTABLE. `unrecorded_branch_gates/0` returns the
  live gates that would reach `refuse/2`, and `handle_info(:tick, …)` logs
  one `info` per sweep naming the count while it is non-zero — the
  condition announces itself rather than waiting to be queried. When it
  reaches zero and stays there, `refuse/2` and the `present?/1` split in
  `ask/7` can be deleted along with the tests that pin them.

  ### It counts what the sweeper REFUSES, not what lacks a key

  `refuse/2` fires on `not present?/1` — an absent `"branch"` key, a key
  written as `nil`, and a key holding `""` or whitespace are all "not
  recorded". A counter keyed on key-PRESENCE would therefore report zero
  while a blank-branch row was still routing through `refuse/2` every five
  minutes, and deleting the branch on that zero would send `""` to
  `gh pr list --head`. The count is only worth having if reaching zero
  means the branch is unreachable, so it shares `present?/1` with the code
  it is reporting on rather than approximating it.

  It is scoped through `candidates/0`, for the same reason: the counter and
  the sweeper cannot disagree about which rows are live if there is one
  query that decides. One consequence is deliberate and worth naming — a
  countable row whose repo_url will not normalize is counted here even
  though `gate_repo/1` skips it before `refuse/2` is reached. That
  over-counts, never under-counts, and such a row is hung on both axes
  anyway.

  ### The retirement query

  Answerable without running the app. `stages` is the table name — there is
  no `plan_stages` — confirmed against
  `priv/repo/migrations/20260320120000_create_tasks_tables.exs`, and
  `evaluation_payload` is `jsonb` (`20260505000000_…`), which is what makes
  the `?` operator legal. The `LATERAL` join is `Tasks.current_plan/1`
  written out: without it this is an upper bound that also counts gates on
  superseded plan versions.

  This exact text is extracted from this moduledoc and executed by
  `deploy_merge_reconciler_test.exs`, which asserts it returns the same
  count as `unrecorded_branch_gates/0` against a fixture holding one of
  every row the count excludes. A documented query nobody runs is a guard
  nobody watched fire.

  ```sql
  SELECT count(*)
    FROM validations v
    JOIN stages s ON s.id = v.stage_id
    JOIN plans p ON p.id = s.plan_id
    JOIN LATERAL (
           SELECT p2.id
             FROM plans p2
            WHERE p2.task_id = p.task_id
              AND p2.status IN ('approved', 'completed')
            ORDER BY p2.version DESC
            LIMIT 1
         ) cur ON cur.id = p.id
   WHERE v.kind = 'pr_merged'
     AND v.status = 'pending'
     AND s.status = 'running'
     AND v.evaluation_payload IS NOT NULL
     AND (NOT (v.evaluation_payload ? 'branch')
          OR ((v.evaluation_payload ? 'branch')
              AND btrim(coalesce(v.evaluation_payload ->> 'branch', '')) = ''));
  ```

  The two disjuncts are kept disjoint on purpose. Folding them into one
  `coalesce(… ->> 'branch', '') = ''` would be shorter and would make the
  first disjunct deletable with no change in result — a predicate that
  cannot be shown to matter.

  ## What recording does NOT close

  Recording the branch on the gate fixes the reconciler. The class is
  wider, and naming the rest is the point of writing it down here:

    * `stack_deployer.ex:1193` — `member_branch_for/1`, the stack rollup
      path, still derives.
    * `heartbeat_scheduler.ex` lines 438, 1272 and 1811 — prompt rendering
      still derives.

  Neither is changed here: `heartbeat_scheduler.ex` belongs to task
  019fb949 and is out of this ticket's scope, and `StackDeployer` drives
  the rollup path rather than this one. They are the named follow-up. The
  class is not closed until those read the recorded branch too, and a
  chokepoint is not a fix — `member_slug/1` has moved twice, and each move
  re-pointed every consumer at a different name for tasks that had already
  pushed under the old one.

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

  @doc """
  The live gates that would reach `refuse/2` — the retirement counter for
  the transitional no-recorded-branch path.

  Returns `%{count: n, validation_ids: ids}`. Zero, sustained, means
  `refuse/2` is unreachable and can be deleted; see the moduledoc for the
  equivalent SQL and for why "unrecorded" means `not present?/1` rather
  than a missing key.

  Scoped through `candidates/0`, so this and the sweep cannot disagree
  about which rows are live.
  """
  @spec unrecorded_branch_gates() :: %{
          count: non_neg_integer(),
          validation_ids: [String.t()]
        }
  def unrecorded_branch_gates do
    ids =
      candidates()
      |> Enum.filter(&unrecorded_branch?(&1.validation))
      |> Enum.map(& &1.validation.id)

    %{count: length(ids), validation_ids: ids}
  end

  # `present?/1` and not `Map.has_key?/2`, deliberately — this must agree
  # with what `ask/7` refuses, or the zero it reports is about a different
  # set than the branch it licenses deleting. A nil payload is a legacy
  # unscoped row and was never in scope.
  defp unrecorded_branch?(%Validation{evaluation_payload: payload}) when is_map(payload),
    do: not branch_recorded?(payload)

  defp unrecorded_branch?(_), do: false

  @doc """
  Whether a gate's `evaluation_payload` RECORDS a deploy branch.

  The one predicate three call sites share: `ask/7`'s split between
  polling and `refuse/2`, `unrecorded_branch_gates/0`'s count, and
  `mix burrow.deploy.scope_gate`'s refusal to overwrite a fact that is
  already written down.

  It is `present?/1` and not `Map.has_key?/2`. An absent `"branch"` key, a
  key written as `nil`, and a key holding `""` or whitespace are all "not
  recorded" — the sweeper refuses all three and the counter counts all
  three, so the repair tool has to be willing to FIX all three. Keying the
  overwrite refusal on key presence instead would make the blank-branch
  row — a row the counter reports and the sweeper declines to poll every
  five minutes — unrepairable by the very command the refusal's log line
  names.
  """
  @spec branch_recorded?(map() | nil) :: boolean()
  def branch_recorded?(payload) when is_map(payload), do: present?(Map.get(payload, "branch"))

  def branch_recorded?(_), do: false

  @doc """
  The live candidate row with this validation id, or a NAMED reason why
  there is not one.

  `candidates/0` DECIDES — this looks the id up in that list rather than
  re-stating its five conditions, so an operator tool and the sweeper
  cannot disagree about which gates are live. Two copies of "which gates
  are live" is the defect `StackDeployer.review_readiness/1` shipped once
  (org process-patterns page, "StackDeployer.review_ready? Scoping Bug");
  one of them drifted and the other kept a task hung.

  `why_not_live/1` only NAMES a decision `candidates/0` has already made.
  If it ever drifts from the query the worst case is a misleading message
  — never a wrong answer — and it falls back to `:not_a_live_candidate`
  rather than inventing a reason it cannot evidence.

  Reasons: `:malformed_id`, `:not_found`, `:not_pr_merged`, `:not_pending`,
  `:stage_not_running`, `:superseded_plan`, `:not_a_live_candidate`.
  """
  @spec live_gate(term()) :: {:ok, map()} | {:error, atom()}
  def live_gate(validation_id) do
    # The id here arrives from a COMMAND LINE (`mix burrow.deploy.scope_gate`)
    # and `why_not_live/1`'s `where: v.id == ^id` raises
    # `Ecto.Query.CastError` on a malformed value exactly as `Repo.get/2`
    # does, so it needs a guard — which is also what
    # `repo_lookup_boundary_test.exs` demands of a new counted `Repo.one`.
    #
    # `Platform.UUID.valid?/1` and not `Platform.Types.UUIDv7.cast/1`, on the
    # ONE-DERIVATION argument rather than a safety one. Probed on this
    # checkout: `UUIDv7.cast("higginshigginsxx")` is `:error`, so it does NOT
    # carry the 16-byte-binary hole `Platform.UUID`'s moduledoc records
    # against bare `Ecto.UUID.cast/1`. Both are safe. `Platform.UUID` is the
    # module that names itself "the canonical UUID predicate for boundary
    # lookups", it is what the boundary test's triage instruction cites, and
    # a second spelling of a guard is how the two drift apart later.
    if Platform.UUID.valid?(validation_id) do
      # Persisted ids are lowercase; an operator pasting an uppercase uuid
      # would otherwise miss the `Enum.find/2` and be told the row is not a
      # live candidate when it is.
      id = String.downcase(validation_id)

      case Enum.find(candidates(), &(&1.validation.id == id)) do
        nil -> {:error, why_not_live(id)}
        row -> {:ok, row}
      end
    else
      {:error, :malformed_id}
    end
  end

  defp why_not_live(id) do
    row =
      Repo.one(
        from(v in Validation,
          left_join: s in Stage,
          on: s.id == v.stage_id,
          left_join: p in Plan,
          on: p.id == s.plan_id,
          where: v.id == ^id,
          select: %{
            kind: v.kind,
            status: v.status,
            stage_status: s.status,
            plan_id: p.id,
            task_id: p.task_id
          }
        )
      )

    cond do
      is_nil(row) -> :not_found
      row.kind != "pr_merged" -> :not_pr_merged
      row.status != "pending" -> :not_pending
      row.stage_status != "running" -> :stage_not_running
      is_nil(row.task_id) -> :not_a_live_candidate
      current_plan_id(row.task_id) != row.plan_id -> :superseded_plan
      true -> :not_a_live_candidate
    end
  end

  @doc false
  @spec report_unrecorded_branch_gates(%{
          count: non_neg_integer(),
          validation_ids: [String.t()]
        }) :: :ok
  # Takes the tally rather than computing it, so the line the retirement
  # condition announces is testable without starting the GenServer or
  # letting `sweep/0` shell out to `gh` from a sandboxed test process.
  def report_unrecorded_branch_gates(%{count: 0}), do: :ok

  def report_unrecorded_branch_gates(%{count: count, validation_ids: ids}) do
    Logger.info(
      "[deploy_merge_reconciler] #{count} pending pr_merged gate(s) record no deploy " <>
        "branch and are being refused rather than polled: #{Enum.join(ids, ", ")}. " <>
        "Scope each with `mix burrow.deploy.scope_gate <id> --repo-url <url> --branch " <>
        "<branch>`; when this count reaches zero the refusal branch can be deleted."
    )

    :ok
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

    # ONE line per sweep, not one per gate, and only while the transitional
    # population is non-empty.
    report_unrecorded_branch_gates(unrecorded_branch_gates())

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
        # The stage rides along on the JOIN this query already performs.
        # `poll/7` needs its `started_at` to decide whether an observed merge
        # postdates the gate, and selecting it here keeps that a property of
        # the row `candidates/0` hands out rather than a second lookup that
        # could disagree about which stage owns the gate — and avoids adding
        # a `Repo.get` on an id this query already resolved.
        select: %{validation: v, task: t, plan_id: p.id, stage: s}
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

  defp reconcile(%{validation: validation, stage: stage}, runner) do
    case gate_repo(validation) do
      :skip ->
        0

      {:ok, %{target: target, slug: slug, branch: branch, branch_tip_sha: tip}} ->
        ask(runner, validation, branch, target, slug, stage, tip)
    end
  end

  # The branch is READ from the gate. `ask/7` no longer takes the task,
  # because there is nothing left to compute from it. It does take the STAGE,
  # which is not a derivation but a fact the gate is scoped to — see
  # `merge_postdates_stage?/2`.
  defp ask(runner, validation, branch, target, slug, stage, tip) do
    if present?(branch) do
      poll(runner, validation, branch, target, slug, stage, tip)
    else
      refuse(validation, slug)
    end
  end

  # A scoped gate minted before `DeployStageBuilder.repo_validation/3` began
  # recording the branch. Deriving one here is the thing this module stopped
  # doing, and the reason is not style:
  #
  # `gh pr list --head` answers about a BRANCH, and GitHub returns one PR per
  # branch, so a derivation that produces the wrong name is invisible to both
  # the runner and GitHub. Nothing downstream can fail closed on it. That
  # makes a derived branch a source of WRONG ATTRIBUTION, and
  # `changelog.ex:253-262` already states this codebase's rule for that case:
  # "A wrong attribution is strictly worse than no attribution." A refusal
  # hangs the gate visibly at `warning`; a bad derivation marks unmerged code
  # as shipped and the task reaches `done` having deployed nothing.
  #
  # The population is finite and hours wide. Gates with a nil payload were
  # already skipped above; scoped payloads only exist from `d63abdc0`
  # (production 20:47Z 2026-07-31). So this clause can only be reached by a
  # gate minted between that deploy and this change landing.
  #
  # The named remedy — `mix burrow.deploy.scope_gate` — is minted by stage 4 of
  # this same plan and ships in the same change; it writes the missing
  # `"branch"` onto the payload without passing the gate, after which the next
  # sweep polls it normally.
  defp refuse(validation, slug) do
    Logger.warning(
      "[deploy_merge_reconciler] validation #{validation.id} on #{slug} records no deploy " <>
        "branch; refusing to derive one and leaving the gate pending — a derived branch " <>
        "cannot be checked by the runner or by GitHub, so a wrong one would pass this gate " <>
        "silently. Record it with " <>
        "`mix burrow.deploy.scope_gate #{validation.id} --repo-url <url> --branch <branch>`."
    )

    0
  end

  defp poll(runner, validation, branch, target, slug, stage, tip) do
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
        cond do
          not merge_postdates_stage?(pr, stage) ->
            pend_stale(validation, slug, pr, branch, stage)

          merge_carries_reviewed_tree?(pr, tip) ->
            pass(validation, slug, pr, branch)

          true ->
            case fix_forward_delta(runner, target, branch, tip, pr, stage) do
              {:ok, commits} ->
                pass(validation, slug, pr, branch, %{"fix_forward_commits" => commits})

              {:reject, reason} ->
                pend_wrong_tree(validation, slug, pr, branch, tip, reason)
            end
        end

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

  # ── Is this merge evidence for THIS stage? ──────────────────────────────

  # `{:ok, pr}` answers "a PR from this branch merged". It does NOT answer "a
  # PR from this branch merged FOR THIS STAGE", and until task 01a06d6d this
  # module read the first as if it were the second.
  #
  # `gh pr list --head` looks BACKWARDS over all time. A branch that already
  # shipped — a previous plan version, an earlier deploy stage on the same
  # task, a re-run after a revert — answers every subsequent poll with the
  # same historical merge, forever. Measured live 2026-09-04: validation
  # `01a06d69-7ece-7001-a61f-dd7349436391` passed at 17:14:03Z on a stage
  # whose `started_at` was 17:13:45Z, citing PR #919 merged at 14:33:13Z — a
  # merge two hours and forty minutes older than the gate it was accepted as
  # evidence for. The task reached `done` with its reviewed code not on main.
  #
  # This is `refuse/2`'s harm arriving by a different route. There, a DERIVED
  # BRANCH NAME attributes a merge to the wrong branch; here, a correctly
  # recorded branch attributes the wrong MERGE. "A wrong attribution is
  # strictly worse than no attribution" (changelog.ex:253-262) decides both
  # the same way: hang the gate visibly rather than mark unmerged code as
  # shipped.
  #
  # The webhook path needs no equivalent. `GithubWebhookController` matches
  # pending gates at the moment a PR closes, so it can only pass a gate that
  # already exists — the ordering is a property of WHEN it runs. This module
  # is the only one that looks backwards, which is why it is the only one
  # with the hole.
  #
  # ## Nil and unparseable fail CLOSED
  #
  # `MergeRunner`'s `merged_pr` typedoc: "Every field except `:number` may be
  # `nil`". So `merged_at` is a `String.t() | nil` from `gh`, and an absent or
  # malformed one cannot be SHOWN to postdate the stage. Unknown is therefore
  # not-after, not maybe-after: admitting unknown would reinstate this entire
  # defect for any merge method that returns a null timestamp. A `nil`
  # `started_at` folds into the same clause for the same reason — a stage we
  # cannot date is a comparison we cannot make.
  #
  # STRICTLY after. A merge stamped at exactly the stage's `started_at` is not
  # evidence the stage caused it, and equality here is far likelier to be a
  # truncated timestamp than a real simultaneity.
  defp merge_postdates_stage?(%{merged_at: merged_at}, %Stage{started_at: %DateTime{} = started}) do
    case parse_merged_at(merged_at) do
      {:ok, merged} -> DateTime.compare(merged, started) == :gt
      :error -> false
    end
  end

  defp merge_postdates_stage?(_pr, _stage), do: false

  defp parse_merged_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, merged, _offset} -> {:ok, merged}
      {:error, _reason} -> :error
    end
  end

  defp parse_merged_at(_value), do: :error

  # ── Is this merge THE TREE the gate was minted for? ─────────────────────

  # The ordering check above is a PROXY. It proves a merge is recent enough
  # to be plausible; it does not prove the merge carried the reviewed work.
  # A force-push onto the task branch, followed by a PR merging seconds after
  # the deploy stage opened, satisfies ordering exactly and ships a tree
  # nobody looked at. This is the check that pins the real invariant:
  #
  #     the tip the gate was minted for == the tip the PR merged
  #
  # `branch_tip_sha` is written by `DeployStageBuilder.repo_validation/3` at
  # the instant the deploy stage is injected, which is the instant the last
  # review stage passed. `head_sha` is GitHub's `headRefOid` on the merged
  # PR. Equal means the reviewed commit is what went in.
  #
  # Equal is sufficient to pass the gate on the spot, but UNEQUAL is no
  # longer sufficient to reject it outright. A mismatch here only means
  # `poll/7` hands the pair to `fix_forward_delta/6`, which accepts the
  # delta between `tip` and `head_sha` when — and only when — EVERY commit
  # in it is BOTH committed strictly after this stage's `started_at` AND
  # authored by the same GitHub login that opened the merged PR; see
  # "Fix-forward: a moved tip is not automatically a wrong tree" below. So
  # this section documents the equality invariant
  # `merge_carries_reviewed_tree?/2` itself checks — accept-by-author-and-
  # window, not bare identity, is what actually decides a mismatched tip.
  #
  # ## Why this is an EQUALITY and not an ancestry test
  #
  # `git merge-base --is-ancestor` is the obvious expression of "the merge
  # contains the reviewed commit" and it is WRONG here, in both directions,
  # because `main` squash-merges:
  #
  #   * `--is-ancestor <branch tip> main` is FALSE for a branch that shipped
  #     perfectly — the squash created a new commit and the branch tip never
  #     becomes an ancestor of main. Used as the check, it hangs every
  #     correct deploy.
  #   * `--is-ancestor <the cited merge commit> main` is TRUE for ANY commit
  #     that has ever merged, the stale PR #919 that caused this ticket
  #     included. Used as the check, it certifies the exact defect.
  #
  # Comparing two branch tips asks git nothing, needs no clone, and cannot be
  # confused by the merge method. That is why it is the discriminator.
  #
  # ## Absent on either side falls THROUGH — deliberately
  #
  # This is the one fail-SOFT decision in the feature, and it is opposite to
  # how `merge_postdates_stage?/2` handles a nil, so it is worth saying why.
  #
  # A nil `merged_at` is a fact GitHub declined to give about a merge it says
  # happened; admitting it would reinstate the whole defect for any merge
  # method that returns a null timestamp, and the safe reading of "unknown"
  # there is "not after".
  #
  # A nil tip is different in kind. `branch_tip_sha` is absent for every gate
  # minted before this change, and `head_sha` is null for some merge methods
  # and older PRs. Reading either as "the trees differ" would hang every
  # pre-existing live deploy in the system at once — the population is not a
  # narrow window here, it is every gate open right now. `refuse/2`'s comment
  # settles this class of question the same way: the harm of stranding live
  # deploys outweighs a narrower check, so the gate keeps the ordering check
  # it already had and loses only the strengthening. A gate that falls
  # through is no weaker than it was before this stage existed.
  #
  # The absence is not silent: `BranchProvisioner.branch_tip_shas/3` logs a
  # `warning` naming the repository whenever it cannot resolve a tip, so a
  # gate that will only ever get the ordering check says so when it is minted
  # rather than at the moment it matters.
  defp merge_carries_reviewed_tree?(%{head_sha: head_sha}, tip)
       when is_binary(head_sha) and is_binary(tip) do
    trimmed_head = String.trim(head_sha)
    trimmed_tip = String.trim(tip)

    # Blank on either side is an absent value wearing a string, and must fall
    # through with the nils rather than compare unequal — otherwise a payload
    # written as `""` by any future path hangs the gate forever with no
    # operator-legible reason.
    if trimmed_head == "" or trimmed_tip == "" do
      true
    else
      trimmed_head == trimmed_tip
    end
  end

  defp merge_carries_reviewed_tree?(_pr, _tip), do: true

  # ── Fix-forward: a moved tip is not automatically a wrong tree ──────────

  # `merge_carries_reviewed_tree?/2` is an EQUALITY, and a legitimate
  # fix-forward push after review — a typo fixed, a lint failure answered —
  # moves the branch tip and fails that equality exactly like a stranger's
  # force-push does. Both look identical to `pend_wrong_tree/6`: head_sha and
  # tip differ. This is the narrow exception that tells them apart WITHOUT
  # ancestry (`git merge-base --is-ancestor` is deliberately not used here —
  # see the moduledoc reasoning above `merge_carries_reviewed_tree?/2` on
  # squash merges making it both too strict and too loose).
  #
  # The delta is accepted only when EVERY commit strictly between the
  # recorded tip and the merged head is BOTH committed strictly after this
  # stage started AND authored by the same GitHub login that opened the
  # merged PR. Either fact alone is not enough: same-window timing alone
  # admits an interloper's commit landed in the same few minutes, and
  # same-author alone admits a historical or unrelated commit replayed onto
  # the branch. `commits_between/3` failing, or answering an empty compare,
  # is treated as non-acceptance, not as vacuously satisfied — an empty or
  # failed compare has told us nothing about what shipped.
  #
  # Fails CLOSED on missing or unparseable per-commit data. This is
  # deliberately NOT the same concession `merge_carries_reviewed_tree?/2`
  # makes for an absent `branch_tip_sha`/`head_sha` — that fallback exists to
  # avoid hanging every gate minted before the tip was recorded, a
  # population this check has no bearing on. A `commits_between/3` result
  # with a nil or unparseable `committer_date` or `author_login` on any
  # commit is data this stage was given and declined to read, not data it
  # never had, so it rejects rather than falling through.
  #
  # Returns `{:ok, commits}` on acceptance or `{:reject, reason}` on
  # non-acceptance, where `reason` names WHICH check refused the delta —
  # `:no_commits_in_delta`, `{:commits_lookup_error, term}`,
  # `:author_mismatch`, or `:window_violation` — so `pend_wrong_tree/6` can
  # log something more specific than "the two shas differ". The reason is
  # diagnostic only: it is derived from the same `Enum.all?/2` that already
  # decided pass vs. reject, via `fix_forward_rejection_reason/3` below, and
  # cannot change what passes.
  defp fix_forward_delta(runner, target, branch, tip, %{head_sha: head_sha} = pr, stage) do
    case runner.commits_between(%{repo: target, branch: branch}, tip, head_sha) do
      {:ok, []} ->
        {:reject, :no_commits_in_delta}

      {:ok, commits} ->
        if Enum.all?(commits, &fix_forward_commit_accepted?(&1, stage, pr.author_login)) do
          {:ok, Enum.map(commits, &fix_forward_commit_evidence/1)}
        else
          {:reject, fix_forward_rejection_reason(commits, stage, pr.author_login)}
        end

      {:error, reason} ->
        {:reject, {:commits_lookup_error, reason}}
    end
  end

  # Names the SPECIFIC check that failed, for the one commit that failed
  # first — mirrors `fix_forward_commit_accepted?/3`'s own check order
  # (author login, then window) so it cannot report a different failure
  # than the one that actually decided the `Enum.all?/2` above. Only
  # called on the reject path, where at least one commit fails one of the
  # two checks, so the `nil` default is not reachable in practice; it is
  # there so a future caller gets a legible atom instead of a crash if that
  # ever stops being true.
  defp fix_forward_rejection_reason(commits, stage, pr_login) do
    Enum.find_value(commits, :author_mismatch, fn commit ->
      cond do
        not (is_binary(commit.author_login) and commit.author_login == pr_login) ->
          :author_mismatch

        not commit_postdates_stage?(commit.committer_date, stage) ->
          :window_violation

        true ->
          nil
      end
    end)
  end

  # Both halves of the rule, ANDed: the commit's own login must match the
  # PR's own login (a login GitHub genuinely declined to give, on either
  # side, can never equal another `nil` and pass — see the moduledoc for why
  # that is deliberate), and the commit must have been committed strictly
  # after the stage started, by `committer_date` (not `author_date` — the
  # field the `commit/0` typedoc names as the one that moves under a rebase
  # or amend, which is what a fix-forward push onto a new tip actually is).
  defp fix_forward_commit_accepted?(
         %{committer_date: committer_date, author_login: commit_login},
         stage,
         pr_login
       ) do
    is_binary(commit_login) and commit_login == pr_login and
      commit_postdates_stage?(committer_date, stage)
  end

  # Same parser and the same strictness as `merge_postdates_stage?/2` — a
  # commit whose timestamp we cannot show postdates the stage is treated as
  # not-after, never as maybe-after.
  defp commit_postdates_stage?(committer_date, %Stage{started_at: %DateTime{} = started}) do
    case parse_merged_at(committer_date) do
      {:ok, committed} -> DateTime.compare(committed, started) == :gt
      :error -> false
    end
  end

  defp commit_postdates_stage?(_committer_date, _stage), do: false

  # The evidence shape for an accepted fix-forward delta — one map per
  # accepted commit, string-keyed to match every other key `pass/5` writes.
  # `pend_wrong_tree/6` writes nothing queryable today; this is what lets a
  # pass under this rule answer "which commits did this gate actually
  # accept?" from the evidence alone, the same standard `head_sha` and
  # `observed_by` are already held to.
  defp fix_forward_commit_evidence(%{
         sha: sha,
         committer_date: committer_date,
         author_login: author_login
       }) do
    %{"sha" => sha, "committer_date" => committer_date, "author_login" => author_login}
  end

  # `warning`, and for the same reason as `pend_stale/5`: a merge the sweeper
  # found but will not accept is not the routine answer, it is a deploy that
  # now hangs until an operator looks. Both shas are in the line because the
  # single most useful thing an operator can do with this message is compare
  # them by eye — one is the commit the review passed on, the other is what
  # actually merged, and knowing WHICH tree shipped is the entire question.
  #
  # `reason` is `fix_forward_delta/6`'s `{:reject, reason}` — naming WHICH of
  # the fix-forward checks refused the delta, not only that the two shas
  # differ, so an operator does not have to re-derive the compare by hand to
  # learn why this one didn't qualify.
  defp pend_wrong_tree(validation, slug, pr, branch, tip, reason) do
    Logger.warning(
      "[deploy_merge_reconciler] #{slug} PR ##{pr.number} for #{branch} merged head " <>
        "#{inspect(pr.head_sha)}, but this gate was minted for branch tip #{inspect(tip)}; " <>
        "the merge did not carry the reviewed tree (#{fix_forward_rejection_text(reason)}), " <>
        "so leaving validation #{validation.id} pending. This is what a force-push after " <>
        "review looks like. Re-review the branch as it now stands rather than passing the " <>
        "gate by hand."
    )

    0
  end

  # One clause per `fix_forward_rejection_reason/3` (plus the lookup-error
  # shape from `fix_forward_delta/6` itself) so the log line names the exact
  # check that refused the delta. The catch-all is defensive only — every
  # reason `fix_forward_delta/6` can actually produce has its own clause
  # above it.
  defp fix_forward_rejection_text(:no_commits_in_delta),
    do: "commits_between/3 found no commits between the recorded tip and the merged head"

  defp fix_forward_rejection_text({:commits_lookup_error, error}),
    do: "commits_between/3 could not be resolved: #{inspect(error)}"

  defp fix_forward_rejection_text(:author_mismatch),
    do: "a commit in the delta was not authored by the merged PR's own author"

  defp fix_forward_rejection_text(:window_violation),
    do:
      "a commit in the delta does not have a committer_date strictly after the stage's started_at"

  defp fix_forward_rejection_text(other), do: "fix-forward check failed: #{inspect(other)}"

  # `warning`, matching `refuse/2` and NOT the `{:ok, nil}` branch's `debug`.
  # "No merged PR yet" is the routine answer for every open gate on every
  # five-minute tick and would drown the log. A merge this sweeper found but
  # cannot attribute is not routine: it means the branch is in a state the
  # gate cannot vouch for, and the deploy will now hang until an operator
  # looks. Both facts belong in the line, so it names the validation, the
  # branch, the PR, the merge time it was given and the stage time it failed
  # against.
  defp pend_stale(validation, slug, pr, branch, stage) do
    Logger.warning(
      "[deploy_merge_reconciler] #{slug} PR ##{pr.number} for #{branch} reports merged_at " <>
        "#{inspect(pr.merged_at)}, which is not strictly after the stage's started_at " <>
        "#{stage_started_display(stage)}; refusing to attribute a merge this gate cannot " <>
        "have caused and leaving validation #{validation.id} pending. An unknown or " <>
        "unparseable merge time counts as not-after. If this merge really is the deploy, " <>
        "pass the gate by hand with the evidence rather than widening this check."
    )

    0
  end

  # ISO8601 and not `inspect/1`, so the two timestamps in that line are
  # comparable by eye and greppable by the same shape. `~U[…]` next to a
  # quoted ISO8601 string invites a misreading of which one is older.
  defp stage_started_display(%Stage{started_at: %DateTime{} = started_at}),
    do: DateTime.to_iso8601(started_at)

  defp stage_started_display(_stage), do: "nil (the stage records no start time)"

  # `extra_evidence` defaults to empty for the fast path and every other
  # existing caller, so the change here is additive: only
  # `fix_forward_delta/6`'s caller passes a non-empty map, keyed
  # `"fix_forward_commits"`, and `Map.merge/2` puts it alongside the fields
  # every pass already wrote rather than replacing any of them.
  defp pass(validation, slug, pr, branch, extra_evidence \\ %{}) do
    evidence =
      %{
        "pr_url" => pr.url,
        "pr_number" => pr.number,
        "merged_at" => pr.merged_at,
        "merge_commit_sha" => pr.merge_commit_sha,
        # The tree, next to the merge commit. Under a squash merge
        # `merge_commit_sha` is a NEW commit on the base and shares no sha with
        # anything the branch held, so it cannot answer "which work shipped?".
        # `head_sha` can. Recorded for the same reason as `observed_by`: the
        # question "what did this gate actually accept?" has to stay answerable
        # from the evidence alone, months later, without re-asking GitHub about
        # a PR whose branch may no longer exist.
        "head_sha" => Map.get(pr, :head_sha),
        "repo" => slug,
        # The provenance key. A webhook-passed gate does not carry this, so
        # "was this merge pushed to us or did we go looking?" stays answerable
        # from the evidence alone.
        "observed_by" => "reconciler"
      }
      |> Map.merge(extra_evidence)

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

  # `DeployStageBuilder.repo_validation/3` writes BOTH `"repo"` (canonical
  # slug, what the webhook matcher compares on) and `"repo_url"` (what the
  # human declared). `gh -R` is handed the URL, matching
  # `AutoMerger.execute_merge/3`; the slug is what lands in evidence, so the
  # polled and delivered paths agree on how a repository is named.
  #
  # `"branch"` is read the same way and deliberately NOT defaulted: absent
  # and present-but-empty both have to reach `ask/7` as "not recorded", so the
  # refusal is what decides, rather than a default quietly standing in for a
  # fact nobody wrote down.
  #
  # `"branch_tip_sha"` is read here too and NOT defaulted either, but it
  # decides the opposite way — absent means "fall back to the ordering check",
  # not "refuse". See `merge_carries_reviewed_tree?/2` for why the two keys
  # get opposite treatment.
  defp gate_repo(%Validation{evaluation_payload: payload}) when is_map(payload) do
    repo_url = Map.get(payload, "repo_url")
    slug = Map.get(payload, "repo") || Platform.Tasks.RepoRef.slug(repo_url)
    branch = Map.get(payload, "branch")
    branch_tip_sha = Map.get(payload, "branch_tip_sha")

    cond do
      # A gate with no canonical slug is a DECLARED repository whose URL
      # would not normalize — `Tasks.resolve_deploy_repos/1` keeps it with
      # `slug: nil` precisely so it can never be matched by accident. It must
      # be unmatchable by polling too, or the guard holds on one path and
      # leaks on the other. Its task hangs visibly, which is the intent.
      not present?(slug) ->
        :skip

      present?(repo_url) ->
        {:ok, %{target: repo_url, slug: slug, branch: branch, branch_tip_sha: branch_tip_sha}}

      true ->
        {:ok, %{target: slug, slug: slug, branch: branch, branch_tip_sha: branch_tip_sha}}
    end
  end

  # A nil payload is a LEGACY UNSCOPED gate: the single-repo webhook path,
  # minted before gates carried a repository. It is not this sweeper's
  # business — `GithubWebhookController.select_unscoped_validation/3` owns
  # the rules for when such a gate may pass, and polling one would need a
  # repository this row does not name.
  defp gate_repo(_), do: :skip

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # This module used to end in `branch_for/1`, which computed
  # `"task/" <> HeartbeatScheduler.member_slug(task)`. Its comment argued that
  # routing through the single slug CHOKEPOINT was the guard: if this module
  # derived its own name, the poller would ask about a branch nobody pushed.
  #
  # The argument was sound and the guard still failed, because routing through
  # a chokepoint does not help when the chokepoint MOVES. `member_slug/1` has
  # changed shape twice — most recently in task 019fb949 / PR #647, which made
  # it unconditionally full-uuid — and each move silently re-pointed every
  # consumer at a different branch name for tasks that had already pushed
  # under the old one. A chokepoint keeps N derivations agreeing with each
  # other; it does not keep them agreeing with a branch that was pushed in the
  # past. Only recording the name at mint time does that.
  #
  # So the branch is now READ from the gate — `DeployStageBuilder`
  # `repo_validation/3` writes it when the deploy stage is built (stage 1 of
  # this plan) and `gate_repo/1` reads it back. When it is absent the sweeper
  # refuses rather than guessing; see `refuse/2`.
  #
  # The derivations this change does NOT close, and the retirement condition
  # for the refusal branch above, are recorded in the moduledoc — see
  # "What recording does NOT close" and "The retirement query".
end
