defmodule PlatformWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook events and processes them.

  Handles:
  - `pull_request` events with `action: "closed"` + `merged: true` → changelog
    entries and auto-evaluate the task's pending `pr_merged` validation
  - `check_suite.completed` → auto-evaluate `ci_passed` validations via PlanEngine
  - `workflow_run.completed` → auto-evaluate `ci_passed` validations via PlanEngine

  HMAC signature verification does NOT live here. It is fail-closed at the
  router: `pipeline :github_webhook` runs
  `PlatformWeb.Plugs.VerifyGithubSignature`, which rejects an unsigned or
  mis-signed delivery with a 401 before any controller code runs. This
  controller only handles events. See
  `docs/runbooks/github_webhook_secret.md` for the secret cutover.
  """

  use PlatformWeb, :controller

  import Ecto.Query

  alias Platform.Changelog
  alias Platform.Repo
  alias Platform.Tasks

  alias Platform.Tasks.{
    AutoMerger,
    Plan,
    PlanEngine,
    RollupWebhookProcessor,
    RepoRef,
    Stack,
    Stacks,
    Stage,
    Task,
    Validation
  }

  require Logger

  # ── Handlers ─────────────────────────────────────────────────────────────

  @doc """
  Dispatch one GitHub webhook delivery.

  ONE `@doc` for all four clauses. Elixir reports a second `@doc` on the
  same name/arity as "redefining @doc attribute"; the three per-clause
  strings this replaces were two such warnings, carried since before this
  task.

    * `pull_request` closed + merged → changelog entry, and the
      `pr_merged` gate belonging to the merging repository.
    * `check_suite.completed` → the `ci_passed` gate belonging to the
      repository that ran it, and per-repo auto-merge for that repository.
    * `workflow_run.completed` → same, from the other CI event shape.
    * anything else → ignored.
  """
  def handle(conn, %{"action" => "closed", "pull_request" => pr} = params) do
    if pr["merged"] do
      process_merged_pr(conn, pr, delivering_repo(pr, params))
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not merged"})
    end
  end

  # check_suite.completed → evaluate ci_passed validations.
  def handle(conn, %{"action" => "completed", "check_suite" => check_suite} = params) do
    branch = check_suite["head_branch"]
    conclusion = check_suite["conclusion"]
    sha = get_in(check_suite, ["head_sha"])
    run_url = get_in(check_suite, ["url"])

    process_ci_event(
      conn,
      branch,
      conclusion,
      sha,
      run_url,
      "check_suite",
      ci_delivering_repo(params)
    )
  end

  # workflow_run.completed → evaluate ci_passed validations.
  def handle(conn, %{"action" => "completed", "workflow_run" => workflow_run} = params) do
    branch = workflow_run["head_branch"]
    conclusion = workflow_run["conclusion"]
    sha = get_in(workflow_run, ["head_sha"])
    run_url = get_in(workflow_run, ["html_url"])

    process_ci_event(
      conn,
      branch,
      conclusion,
      sha,
      run_url,
      "workflow_run",
      ci_delivering_repo(params)
    )
  end

  def handle(conn, _params) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not a relevant event"})
  end

  # ── Which repository delivered this event ───────────────────────────────
  #
  # Both readers live BELOW every `handle/2` clause rather than next to the
  # clause that calls them. Interleaving a private function between clauses of
  # the same name and arity is a "clauses ... should be grouped together"
  # compile warning, and stage 3 left two of those behind by placing
  # `delivering_repo/2` inline; stage 4 would have added a third.

  # WHICH REPOSITORY DELIVERED THIS MERGE.
  #
  # `pr_merged` is scoped per repository (task 019fa63a stage 2 — one gate per
  # entry in the resolved repo set, each carrying its own identity in
  # `evaluation_payload`), so the delivering repo is the ONLY thing that can
  # decide which gate a merge satisfies. Read it here, at the edge, and pass
  # the resolved string down: `process_merged_pr/3` then stays a function of
  # the PR plus one extra fact, instead of threading the whole params map
  # through four call sites.
  #
  # GitHub sends the repository twice on a `pull_request` event — on
  # `pull_request.base.repo` and on the top-level `repository`. Prefer the
  # former (it is the repo the PR MERGED INTO, which is the deploy fact;
  # `head.repo` differs on a fork) and fall back to the latter.
  defp delivering_repo(pr, params) do
    get_in(pr, ["base", "repo", "full_name"]) || get_in(params, ["repository", "full_name"])
  end

  # WHICH REPOSITORY RAN THIS CI (task 019fa63a stage 4).
  #
  # The hard constraint from the ticket — "a green CI in repo A must never
  # authorize a merge in repo B" — is unenforceable unless the delivering
  # repository is read. It was not read before this stage: `process_ci_event/6`
  # took the run's branch and conclusion and nothing else, and the auto-merge
  # it triggered resolved its target from `task.project.repo_url`. On a
  # two-repo task that is repo A's green authorizing repo B's merge, live.
  #
  # Unlike `pull_request`, a `check_suite` / `workflow_run` payload has no
  # `base.repo` — the top-level `repository` is the only spelling — so this is
  # a single read rather than the two-step `delivering_repo/2` above. It stays
  # a named function anyway so the two edges read alike.
  defp ci_delivering_repo(params), do: get_in(params, ["repository", "full_name"])

  # ── CI event processing ─────────────────────────────────────────────────

  defp process_ci_event(conn, branch, conclusion, sha, run_url, event_type, delivering_repo) do
    task_id = Changelog.extract_task_id_from_branch(branch)

    if task_id do
      case find_pending_ci_validations(task_id) do
        [] ->
          # Stays at `debug` on purpose (task 019f9b34): this fires on every
          # `check_suite.completed` / `workflow_run.completed` for a task
          # branch — i.e. on every push during execution, long before any
          # deploy stage exists. Promoting it would drown the log.
          Logger.debug(
            "[Webhook] No pending ci_passed validation for task #{task_id} (branch: #{branch})"
          )

          conn
          |> put_status(:ok)
          |> json(%{status: "ignored", reason: "no pending ci_passed validation"})

        candidates ->
          case select_validation_for_repo(candidates, task_id, delivering_repo) do
            {:ok, validation} ->
              evaluate_ci_validation(conn, validation, %{
                task_id: task_id,
                branch: branch,
                conclusion: conclusion,
                sha: sha,
                run_url: run_url,
                event_type: event_type,
                delivering_repo: delivering_repo
              })

            {:unmatched, repo} ->
              record_unmatched_ci_delivery(candidates, task_id, repo, branch, run_url)

              conn
              |> put_status(:ok)
              |> json(%{
                status: "ignored",
                reason: "ci_passed gate belongs to another repository"
              })
          end
      end
    else
      conn
      |> put_status(:ok)
      |> json(%{status: "ignored", reason: "branch does not match task pattern"})
    end
  end

  defp evaluate_ci_validation(conn, validation, ctx) do
    status = if ctx.conclusion == "success", do: "passed", else: "failed"

    evidence = %{
      "event_type" => ctx.event_type,
      "conclusion" => ctx.conclusion,
      "sha" => ctx.sha,
      "run_url" => ctx.run_url,
      "branch" => ctx.branch,
      "repo" => ctx.delivering_repo,
      "evaluated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case PlanEngine.evaluate_validation(validation.id, %{
           status: status,
           evidence: evidence,
           evaluated_by: "github_webhook"
         }) do
      {:ok, updated} ->
        Logger.info(
          "[Webhook] Evaluated ci_passed validation #{updated.id} as #{status} " <>
            "for task #{ctx.task_id} (#{ctx.event_type}, conclusion: #{ctx.conclusion}, " <>
            "repo: #{inspect(ctx.delivering_repo)})"
        )

        # After CI passes, check if auto-merge should fire — FOR THE
        # DELIVERING REPOSITORY ONLY.
        if status == "passed" do
          maybe_trigger_auto_merge(ctx.task_id, ctx.branch, ctx.delivering_repo)
        end

        conn
        |> put_status(:created)
        |> json(%{status: "evaluated", validation_id: updated.id, result: status})

      {:error, reason} ->
        Logger.warning("[Webhook] Failed to evaluate ci_passed validation: #{inspect(reason)}")

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{status: "error", reason: inspect(reason)})
    end
  end

  # Every pending `ci_passed` on the task's running stage, in stage-position
  # then insertion order.
  #
  # Plural since task 019fa63a stage 4, for the same reason
  # `find_pending_pr_merged_validations/1` became plural in stage 3: a
  # `ci_passed` gate is repo-scoped exactly as a `pr_merged` gate is, and
  # `limit: 1` + `Repo.one` hands the first row on the stage to whichever
  # repository happened to deliver — which is repo A's CI result recorded as
  # repo B's.
  @doc false
  def find_pending_ci_validations(task_id) do
    query =
      from(v in Validation,
        join: s in Stage,
        on: s.id == v.stage_id,
        join: p in Plan,
        on: p.id == s.plan_id,
        join: t in Task,
        on: t.id == p.task_id,
        where: t.id == ^task_id,
        # Task 019f9b34: the plan's status is deliberately NOT filtered here —
        # see `find_pending_pr_merged_validations/1` below for the full
        # rationale.
        where: s.status == "running",
        where: v.kind == "ci_passed",
        where: v.status == "pending",
        order_by: [asc: s.position, asc: v.inserted_at]
      )

    Repo.all(query)
  end

  # ── Auto-merge ───────────────────────────────────────────────────────────

  # PER-REPOSITORY AUTO-MERGE (task 019fa63a stage 4).
  #
  # The ticket's hard constraint: a green CI in repo A must never authorize a
  # merge in repo B. Before this stage the trigger never read the delivering
  # repository at all — it took the merge target from `task.project.repo_url`
  # and the validation from a repo-BLIND `limit: 1` lookup, so on a two-repo
  # task a `check_suite` success from either repo attempted a merge on the
  # project's repo and recorded the result against whichever gate came first.
  #
  # Now the delivery selects ONE gate — the one whose
  # `evaluation_payload["repo"]` names the repository that ran the CI — and
  # the merge target comes from that gate's own `"repo_url"`. There is no
  # project-repo fallback; a delivery that names no gate merges nothing.
  defp maybe_trigger_auto_merge(task_id, branch, delivering_repo) do
    task = Tasks.get_task_detail(task_id)

    cond do
      is_nil(task) ->
        :ok

      Tasks.dispatch_deploy_for_task(task) == {:error, :stack_ships_atomically} ->
        # ADR 0041 (T5 stage 3) — stack members never open their own
        # PRs. The stack rollup PR (T6) carries the deploy. Skip the
        # per-task auto-merge entirely. The
        # `Tasks.dispatch_deploy_for_task/1` guard owns the
        # `[:platform, :tasks, :deploy_dispatch, :rejected_stack_member]`
        # telemetry emission, so operators see per-task branch attempts
        # in metrics without every call site duplicating it.
        Logger.info(
          "[StackDeployer] task #{task.id} is in stack #{task.stack_id}; deferring to " <>
            "stack deployer (skipping per-task auto-merge for branch #{branch})"
        )

      true ->
        auto_merge_delivering_repo(task, branch, delivering_repo)
    end
  end

  defp auto_merge_delivering_repo(task, branch, delivering_repo) do
    task = Tasks.ensure_project_loaded(task)
    strategy = Tasks.resolve_deploy_strategy(task)

    case find_pending_pr_merged_validations(task.id) do
      [] ->
        # Stays at `debug` on purpose (task 019f9b34): this fires after every
        # CI success on the task branch, which is routinely long before any
        # deploy stage exists. Genuinely a normal no-op.
        Logger.debug(
          "[Webhook] No pending pr_merged validation for auto-merge on task #{task.id}"
        )

      candidates ->
        case select_validation_for_repo(candidates, task.id, delivering_repo) do
          {:ok, validation} ->
            decide_auto_merge(task, strategy, validation, branch, delivering_repo)

            name_repos_this_ci_does_not_authorize(
              task.id,
              candidates,
              validation,
              delivering_repo
            )

          # NEVER FALL BACK TO THE PROJECT REPO. A CI success that names no
          # gate is a green we cannot attribute, and the old behavior —
          # merge `task.project.repo_url` anyway — is precisely the inference
          # the ticket forbids. Say so and stop.
          {:unmatched, repo} ->
            Logger.warning(
              "[Webhook] CI success delivered from #{inspect(repo)} on task #{task.id} matches " <>
                "no pr_merged gate (gates: #{inspect(expected_repos(candidates, task.id))}) — " <>
                "nothing auto-merged. A green in one repository does not authorize a merge in " <>
                "another. See task 019fa63a."
            )

            :telemetry.execute(
              [:platform, :tasks, :auto_merge, :unmatched_repo],
              %{count: 1},
              %{
                task_id: task.id,
                delivering_repo: repo,
                expected_repos: expected_repos(candidates, task.id)
              }
            )

            :ok
        end
    end
  end

  # THREE OUTCOMES, and the two refusals stay distinct — see
  # `AutoMerger.auto_merge_decision/0`.
  defp decide_auto_merge(task, strategy, validation, branch, delivering_repo) do
    entry = validation.evaluation_payload

    case AutoMerger.should_auto_merge?(strategy, entry) do
      :yes ->
        spawn_auto_merge(task, validation, branch, delivering_repo, strategy)

      # Ordinary: a human merges, as configured. No evidence, no warning —
      # this is the default for most projects and fires on every CI success.
      {:no, :disabled} ->
        Logger.debug(
          "[Webhook] auto_merge disabled for #{inspect(gate_repo(validation))} on task " <>
            "#{task.id}; leaving the merge to a human"
        )

      # NOT ordinary, and NOT a failure. This repository can never be machine
      # merged — `auto_merge` means "merge once CI is green" and there is no
      # CI here to be green. Recorded on the gate so "why did nothing merge?"
      # is answerable from the validation itself, and left `pending` so the
      # human merge (and stage 6's reconciler observing it) still passes it.
      {:no, :no_ci_to_gate} ->
        repo = gate_repo(validation)

        Logger.info(
          "[Webhook] refusing auto-merge for #{inspect(repo)} on task #{task.id}: the repository " <>
            "declares ci: \"none\", so there is no CI signal that could authorize a machine " <>
            "merge. This is a manual merge, not a failed one — the gate stays pending until " <>
            "the PR is merged by hand."
        )

        :telemetry.execute(
          [:platform, :tasks, :auto_merge, :no_ci_to_gate],
          %{count: 1},
          %{task_id: task.id, repo: repo}
        )

        AutoMerger.record_auto_merge_refusal(validation, :no_ci_to_gate, repo)
    end
  end

  defp spawn_auto_merge(task, validation, branch, delivering_repo, strategy) do
    entry = validation.evaluation_payload
    method = AutoMerger.merge_method(strategy, entry)

    case merge_target(validation, delivering_repo) do
      nil ->
        Logger.warning(
          "[Webhook] auto-merge authorized for task #{task.id} but no repository could be " <>
            "resolved from the gate or the delivery; skipping. Nothing was merged."
        )

      repo_url ->
        # Spawn async task for the merge (with timeout)
        Elixir.Task.start(fn ->
          case find_pr_number_for_branch(repo_url, branch) do
            {:ok, pr_number} ->
              # Pass the task so AutoMerger's defense-in-depth guards —
              # the planning-gate refusal and the stack-member
              # short-circuit — still run even though the controller
              # already checked the latter.
              result = AutoMerger.execute_merge(task, repo_url, pr_number, method)
              AutoMerger.record_merge_result(validation.id, result)

            {:error, reason} ->
              Logger.warning(
                "[Webhook] Could not find PR for branch #{branch} on #{repo_url}: " <>
                  inspect(reason)
              )

              AutoMerger.record_merge_result(
                validation.id,
                {:error, :not_found,
                 "Could not find PR for branch #{branch} on #{repo_url}: #{inspect(reason)}"}
              )
          end
        end)
    end
  end

  # THE GATE'S OWN REPOSITORY, never the project's.
  #
  # `task.project.repo_url` is what this used to read, and on a multi-repo
  # task it is simply a different repository from the one that ran the CI.
  # The fallback is the DELIVERING repo — not the project's — for the legacy
  # unscoped gate, which carries no `repo_url` of its own: the repository
  # that just reported green is the only repository that green speaks for.
  defp merge_target(%Validation{evaluation_payload: payload}, delivering_repo)
       when is_map(payload) do
    case Map.get(payload, "repo_url") do
      url when is_binary(url) and url != "" -> url
      _ -> Map.get(payload, "repo") || delivering_repo
    end
  end

  defp merge_target(_validation, delivering_repo), do: delivering_repo

  # THE UNSATISFIABLE CASE, SAID OUT LOUD.
  #
  # Every other pending gate on this stage is a repository this green does
  # NOT speak for, and each is waiting on something different:
  #
  #   * `ci: "none"` — waiting on a PERSON. Nothing will ever machine-merge
  #     it; stage 6's reconciler polls for the human merge and passes the
  #     gate when it sees one.
  #   * `ci: "required"` — waiting on ITS OWN `check_suite` delivery. If that
  #     repository has no webhook installed (verified 2026-07-31:
  #     `claude-code-suite-channel` and `openclaw-suite-channel` have zero
  #     hooks, `core` has two) that delivery can never arrive and the gate
  #     waits forever. Naming the repo here is what makes that a visible
  #     non-outcome rather than a silent hang; the actual close is stage 6.
  #
  # Emitted only when there ARE siblings, i.e. only on genuinely multi-repo
  # deploys, so a single-repo task's CI pushes add no log volume.
  defp name_repos_this_ci_does_not_authorize(task_id, candidates, authorized, delivering_repo) do
    case Enum.reject(candidates, &(&1.id == authorized.id)) do
      [] ->
        :ok

      siblings ->
        {manual, awaiting} = Enum.split_with(siblings, &(gate_ci(&1) == "none"))
        manual_repos = Enum.map(manual, &gate_repo/1)
        awaiting_repos = Enum.map(awaiting, &gate_repo/1)

        Logger.info(
          "[Webhook] CI success from #{inspect(delivering_repo)} on task #{task_id} authorizes " <>
            "that repository only. Still pending — awaiting their own CI: " <>
            "#{inspect(awaiting_repos)}; awaiting a human merge (ci: \"none\"): " <>
            "#{inspect(manual_repos)}. A repository with no webhook installed will never " <>
            "deliver the CI it is awaiting; see task 019fa63a."
        )

        :telemetry.execute(
          [:platform, :tasks, :auto_merge, :not_authorized_for_siblings],
          %{count: length(siblings)},
          %{
            task_id: task_id,
            delivering_repo: delivering_repo,
            awaiting_own_ci: awaiting_repos,
            awaiting_manual_merge: manual_repos
          }
        )
    end
  end

  defp gate_ci(%Validation{evaluation_payload: payload}) when is_map(payload),
    do: Map.get(payload, "ci")

  defp gate_ci(_), do: nil

  # Every pending `pr_merged` / `ci_check` on the task's running stage, in
  # stage-position then insertion order.
  #
  # Plural since task 019fa63a: a task that lands in N repositories carries N
  # `pr_merged` rows on one deploy stage, and a merge satisfies exactly the one
  # whose `evaluation_payload["repo"]` names the delivering repository. Taking
  # `limit: 1` — as the singular version did — is precisely the bug: the first
  # row wins regardless of which repo actually merged, so a merge in repo B
  # marks repo A as deployed.
  #
  # Kept as a plain comment rather than `@doc`: the function is `@doc false`
  # (internal, public only for the webhook path and tests), and an `@doc`
  # string immediately followed by `@doc false` is a "redefining @doc
  # attribute" compile warning.
  @doc false
  def find_pending_pr_merged_validations(task_id) do
    query =
      from(v in Validation,
        join: s in Stage,
        on: s.id == v.stage_id,
        join: p in Plan,
        on: p.id == s.plan_id,
        join: t in Task,
        on: t.id == p.task_id,
        where: t.id == ^task_id,
        # Task 019f9b34: the plan's status is deliberately NOT filtered here.
        # The plan's lifecycle status is engine bookkeeping and it has drifted
        # from the stage's actual state in production before (a plan read
        # `completed` while its deploy stage was still `running`), which made
        # this query return nil and hung the deploy indefinitely. A deploy that
        # has genuinely happened must be recordable no matter what the plan row
        # claims. The `join: p in Plan` stays — it is the only path from
        # Validation → Stage → Plan → Task — but nothing is filtered on it.
        where: s.status == "running",
        where: v.kind in ~w(pr_merged ci_check),
        where: v.status == "pending",
        order_by: [asc: s.position, asc: v.inserted_at]
      )

    Repo.all(query)
  end

  # NOTE — the repo-BLIND `find_pending_pr_merged_validation/1` wrapper that
  # stood here through stage 3 is GONE as of stage 4.
  #
  # Stage 3 kept it for exactly one production caller: the auto-merge trigger,
  # on the grounds that choosing a gate to record a merge ATTEMPT against is
  # not the same question as "did the PR for THIS repository merge?". Stage 4
  # is the discovery that it IS the same question — a merge attempt is an
  # action taken on a specific repository, so choosing its gate blindly is the
  # same conflation one step earlier. `auto_merge_delivering_repo/3` now goes
  # through `find_pending_pr_merged_validations/1` +
  # `select_validation_for_repo/3` like every other caller, which left the
  # wrapper with no production caller at all.
  #
  # It is deleted rather than kept-and-unused deliberately: a public
  # "give me the pr_merged validation" that ignores the repository is the
  # exact footgun this task exists to remove, and leaving one in place invites
  # the next caller to re-adopt it. `Platform.Tasks.RollupWebhookProcessor`
  # keeps its own same-named function — a stack rollup PR legitimately
  # satisfies every member's gate at once (ADR 0041), which is a different
  # question with a different answer.

  # Public (`@doc false`) so the `gh`-unavailable guard below is directly
  # testable — reaching it through the webhook endpoint would need a full
  # task + plan + deploy-stage fixture just to observe a missing binary.
  @doc false
  def find_pr_number_for_branch(repo_url, branch) do
    args = [
      "pr",
      "list",
      "--head",
      branch,
      "--state",
      "open",
      "--json",
      "number",
      "--limit",
      "1",
      "-R",
      repo_url
    ]

    # `System.cmd("gh", …)` raises `ErlangError: :enoent` when the GitHub
    # CLI is absent, which in a webhook handler means a failure whose
    # stacktrace reads like anything but "the binary is missing".
    # `{:error, :gh_unavailable}` names the binary. Mirrors the
    # `System.find_executable("gh")` guard in
    # `Platform.Responsibilities.Handlers.ArchitectureCronSweep`.
    case System.find_executable("gh") do
      nil ->
        Logger.error(
          "[GithubWebhook] `gh` (GitHub CLI) not found on PATH; cannot run " <>
            "`gh pr list` to resolve the open PR for branch #{branch} on #{repo_url}"
        )

        {:error, :gh_unavailable}

      gh ->
        case System.cmd(gh, args, stderr_to_stdout: true) do
          {output, 0} ->
            case Jason.decode(output) do
              {:ok, [%{"number" => number} | _]} ->
                {:ok, number}

              {:ok, []} ->
                {:error, :no_open_pr}

              _ ->
                {:error, :parse_error}
            end

          {output, _} ->
            {:error, {:gh_error, String.trim(output)}}
        end
    end
  end

  # ── Merged PR processing (changelog) ────────────────────────────────────

  defp process_merged_pr(conn, pr, delivering_repo) do
    raw_title = pr["title"] || ""
    {cleaned_title, tags} = Changelog.parse_title(raw_title)

    branch = get_in(pr, ["head", "ref"])
    base_ref = get_in(pr, ["base", "ref"])
    body = pr["body"]

    task_id =
      Changelog.extract_task_id_from_branch(branch) ||
        Changelog.extract_task_id_from_body(body)

    merged_at = parse_datetime(pr["merged_at"])

    description =
      case body do
        body when is_binary(body) and byte_size(body) > 0 ->
          body |> String.slice(0, 500) |> String.trim()

        _ ->
          nil
      end

    attrs = %{
      title: cleaned_title,
      description: description,
      pr_number: pr["number"],
      pr_url: pr["html_url"],
      commit_sha: pr["merge_commit_sha"],
      author: get_in(pr, ["user", "login"]),
      task_id: task_id,
      tags: tags,
      merged_at: merged_at
    }

    result = Changelog.create_entry(attrs)

    # ADR 0041 §"Validation routing" (T6 stage 1+2): rollup-PR fan-out.
    #
    # A merged PR whose head branch matches an active stack's
    # `task_stacks.rollup_branch` carries the merge for ALL member
    # tasks simultaneously. Check this FIRST and short-circuit the
    # per-task path: members never open their own PRs (T5's auto-merge
    # guard prevents that), so a `stack/<slug>` branch landing means
    # every member's `pr_merged` validation is satisfied by this single
    # event. The per-task path remains the default for non-stack tasks.
    #
    # Stage 2 adds the stack→done transition after fan-out via
    # `Stacks.complete_rollup_merge/2`. The whole stack branch is
    # wrapped in a defensive try/rescue so a bug in stack lookup or
    # transition NEVER takes out the per-task path for ordinary task
    # PRs — on unexpected exception we log ERROR with stacktrace and
    # fall back to the per-task path on the original branch.
    #
    # NOTE on admin-passthrough of `pr_merged`. An operator having to
    # hand-pass a `pr_merged` validation has TWO distinct causes, and
    # they live at different layers — do not assume the first one:
    #
    #   (a) Non-delivery. During T2-T5 dogfooding we observed that
    #       `pull_request.closed` events did not always reach this
    #       controller. That investigation is GitHub-side / nginx /
    #       gateway and is still open.
    #
    #   (b) A delivered event whose validation lookup returned nil.
    #       Task 019f9b34 (incident 019f9ae5, 2026-07-25): GitHub
    #       delivered, this controller returned HTTP 201, and the
    #       changelog row was written — delivery was perfect and the
    #       QUERY was the miss, because `find_pending_pr_merged_validations/1`
    #       filtered on `plan.status == "approved"` while the plan had
    #       already drifted to `completed`. Fixed by removing that
    #       filter, plus the now-`warning`-level no-match log in
    #       `do_evaluate_pr_merged_validation/3` so cause (b) is
    #       visible instead of silent.
    #
    # T6 stage 1 here ensures that WHEN the webhook fires for a rollup
    # PR, all member validations are processed correctly.
    #
    # Stage 3 (T6 hardening): base-branch guard. `get_stack_by_rollup_branch/1`
    # matches ONLY on the PR head ref. A PR whose head is `stack/<slug>` but
    # whose base is some OTHER branch (e.g. a throwaway integration branch or
    # a member feature branch) must NOT trip the fan-out + stack→done — the
    # acceptance is explicitly a `rollup_branch -> base_branch` merge. We gate
    # the stack path on `base_ref == stack.base_branch`; on mismatch we log a
    # warning and fall through to the per-task path (a deliberate no-op for the
    # stack, not an exception).
    try do
      case Stacks.get_stack_for_pull_request_with_strategy(pr) do
        {:ok, %Stack{} = stack, strategy} ->
          Logger.info(
            "[Webhook] Stack #{stack.id} matched via #{strategy} for PR ##{pr["number"]} " <>
              "(branch=#{inspect(branch)})"
          )

          if base_branch_matches?(stack, base_ref) do
            RollupWebhookProcessor.process_stack_merged_pr(stack, pr, merged_at, task_id)
          else
            Logger.error(
              "[Webhook] BASE-BRANCH MISMATCH — stack #{stack.id} matched PR ##{pr["number"]} " <>
                "via #{strategy} but base_ref=#{inspect(base_ref)} != " <>
                "stack.base_branch=#{inspect(stack.base_branch)} — NOT cascading; " <>
                "operator triage required"
            )

            if is_binary(task_id) do
              maybe_evaluate_pr_merged_validation(task_id, pr, merged_at, delivering_repo)
            else
              :ok
            end
          end

        nil ->
          if is_binary(task_id) do
            maybe_evaluate_pr_merged_validation(task_id, pr, merged_at, delivering_repo)
          else
            :ok
          end
      end
    rescue
      exception ->
        Logger.error(
          "[Webhook] Stack rollup fan-out raised; falling back to per-task path. " <>
            "branch=#{inspect(branch)} task_id=#{inspect(task_id)} " <>
            "exception=#{Exception.format(:error, exception, __STACKTRACE__)}"
        )

        if is_binary(task_id) do
          maybe_evaluate_pr_merged_validation(task_id, pr, merged_at, delivering_repo)
        else
          :ok
        end
    end

    case result do
      {:ok, entry} ->
        Logger.info("[Changelog] Created entry for PR ##{entry.pr_number}: #{entry.title}")
        conn |> put_status(:created) |> json(%{status: "created", id: entry.id})

      {:error, changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
            Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
              opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
            end)
          end)

        Logger.warning("[Changelog] Failed to create entry: #{inspect(errors)}")
        conn |> put_status(:unprocessable_entity) |> json(%{status: "error", errors: errors})
    end
  end

  # Whether the merged PR's base branch matches the stack's declared
  # base for auto-completion.
  #
  # Schema default (`stack.ex:51`) is `"main"`, but historical rows
  # created before that default landed may carry NULL. Fall back to the
  # owning project's `default_branch` (schema default `"main"` per
  # `project.ex:13`) so a NULL base_branch never blocks a legitimate
  # cascade. When both sides are strings, compare exactly — no fuzzy
  # match; branch names are case-sensitive on the git side.
  defp base_branch_matches?(%Stack{base_branch: nil} = stack, base_ref)
       when is_binary(base_ref) do
    project = stack |> Repo.preload(:project) |> Map.get(:project)
    project_default = (project && project.default_branch) || "main"
    base_ref == project_default
  end

  defp base_branch_matches?(%Stack{base_branch: base_branch}, base_ref)
       when is_binary(base_branch) and is_binary(base_ref) do
    base_ref == base_branch
  end

  defp base_branch_matches?(_stack, _base_ref), do: false

  defp maybe_evaluate_pr_merged_validation(task_id, pr, merged_at, delivering_repo) do
    task = Tasks.get_task_record(task_id)

    case Tasks.dispatch_deploy_for_task(task) do
      {:error, :stack_ships_atomically} ->
        # ADR 0041 (T5 stage 3) — stack members' per-task `pr_merged`
        # validations are auto-passed by the stack rollup PR's merge
        # webhook fan-out (T6 owns that). DO NOT auto-pass from the
        # per-task webhook; the per-task branch shouldn't be opening
        # PRs in the first place (the auto-merge guard prevents that),
        # but if a webhook fires for a member's individual branch
        # somehow, the per-task path must NOT pre-empt T6. Guard +
        # telemetry live in `Tasks.dispatch_deploy_for_task/1`.
        Logger.info(
          "[StackDeployer] task #{task_id} is in stack #{task.stack_id}; deferring to " <>
            "stack deployer (skipping per-task pr_merged auto-pass for PR " <>
            "#{pr["html_url"]})"
        )

        :ok

      :ok ->
        do_evaluate_pr_merged_validation(task_id, pr, merged_at, delivering_repo)
    end
  end

  defp do_evaluate_pr_merged_validation(task_id, pr, merged_at, delivering_repo) do
    case find_pending_pr_merged_validations(task_id) do
      [] ->
        # Task 019f9b34: this line used to be `Logger.debug`, which is exactly
        # why the 2026-07-25 incident was invisible — the webhook returned 201,
        # the changelog row was written, and the only trace of the miss was a
        # suppressed debug line. It is at `warning` now and accepts the volume
        # (one line per merged task PR on `none`-strategy projects, plus
        # redeliveries for an already-passed validation).
        Logger.warning(
          "[Webhook] No pending pr_merged validation matched task #{task_id} for merged PR " <>
            "#{pr["html_url"]} (sha #{pr["merge_commit_sha"]}). The merge is real but no deploy " <>
            "validation was auto-passed — if a deploy stage is running for this task it will " <>
            "hang. See task 019f9b34."
        )

        :ok

      candidates ->
        case select_validation_for_repo(candidates, task_id, delivering_repo) do
          {:ok, validation} ->
            pass_pr_merged_validation(validation, task_id, pr, merged_at)

          {:unmatched, repo} ->
            record_unmatched_repo_delivery(candidates, task_id, repo, pr)
        end
    end
  end

  # ── Which gate does this merge satisfy? ─────────────────────────────────
  #
  # THREE OUTCOMES, ALL DISTINCT. `pr_merged` used to mean "a PR merged
  # somewhere" and the first pending row on the running stage absorbed it.
  # It now means "the PR for THIS repository merged", so a delivery either
  # names a gate, names an in-flight unscoped gate it is unambiguously
  # entitled to, or names NOTHING — and the third case is a recorded
  # non-outcome, never a pass.
  #
  # `RepoRef.same?/2` does the comparing. `project.repo_url` stores
  # `https://github.com/Owner/Name` while webhooks deliver the bare
  # `Owner/Name`, and GitHub treats owner/name case-insensitively; that is
  # ONE normalizer's job, not this module's.
  @doc false
  def select_validation_for_repo(candidates, task_id, delivering_repo) do
    case Enum.find(candidates, &RepoRef.same?(gate_repo(&1), delivering_repo)) do
      %Validation{} = matched -> {:ok, matched}
      nil -> select_unscoped_validation(candidates, task_id, delivering_repo)
    end
  end

  # LEGACY UNSCOPED ROW — every `pr_merged` written before the gates carried
  # a repository. It may still pass, but only when it is UNAMBIGUOUS: a nil
  # payload on a task that now resolves to two repos cannot say which merge
  # it is waiting for, and an ambiguous gate must not pass. This clause is
  # what keeps tasks that were already deploying when this shipped from
  # hanging forever.
  defp select_unscoped_validation(candidates, task_id, delivering_repo) do
    case Enum.find(candidates, &unscoped_gate?/1) do
      nil ->
        {:unmatched, delivering_repo}

      %Validation{} = legacy ->
        if unscoped_gate_entitled?(task_id, delivering_repo) do
          {:ok, legacy}
        else
          {:unmatched, delivering_repo}
        end
    end
  end

  defp unscoped_gate_entitled?(task_id, delivering_repo) do
    case resolved_repos(task_id) do
      # The task has no resolvable repository anywhere — no declared set and
      # no usable `project.repo_url` (blank, or the `example.invalid` shape
      # fixtures use). There is nothing to mis-attribute the merge AGAINST,
      # and a single unscoped gate on such a task is exactly the pre-scoping
      # world. Passing it is what happened yesterday and stays correct.
      [] ->
        true

      [only] ->
        # An unattributable delivery — GitHub always sends `repository`, so
        # in practice this is a hand-rolled redelivery or a test double —
        # cannot be compared, and an unscoped gate is the one gate for which
        # "a PR merged somewhere" was always the meaning. It still may not
        # touch a SCOPED gate: that is decided above, by `RepoRef.same?/2`,
        # which never answers true on a nil side.
        not attributable?(delivering_repo) or RepoRef.same?(only.slug, delivering_repo)

      _ambiguous ->
        false
    end
  end

  defp attributable?(repo), do: not is_nil(RepoRef.slug(repo))

  # A gate is SCOPED once its payload carries a `"repo"` key — including when
  # that key is `nil`, which is a DECLARED repository whose URL would not
  # normalize (`Tasks.resolve_deploy_repos/1` keeps it rather than dropping
  # it). Such a gate can never be matched by any webhook, so its task hangs
  # visibly instead of reporting a success it did not earn. It is emphatically
  # not "unscoped".
  defp unscoped_gate?(%Validation{evaluation_payload: nil}), do: true

  defp unscoped_gate?(%Validation{evaluation_payload: payload}) when is_map(payload),
    do: not Map.has_key?(payload, "repo")

  defp unscoped_gate?(_), do: false

  defp gate_repo(%Validation{evaluation_payload: payload}) when is_map(payload),
    do: Map.get(payload, "repo")

  defp gate_repo(_), do: nil

  defp resolved_repos(task_id) do
    case Tasks.get_task_record(task_id) do
      %Task{} = task -> Tasks.resolve_deploy_repos(task)
      _ -> []
    end
  end

  defp pass_pr_merged_validation(validation, task_id, pr, merged_at) do
    evidence = %{
      "pr_url" => pr["html_url"],
      "merged_at" => format_merged_at(merged_at),
      "merged_by" => get_in(pr, ["merged_by", "login"]) || get_in(pr, ["user", "login"]),
      "merge_commit_sha" => pr["merge_commit_sha"]
    }

    case PlanEngine.evaluate_validation(validation.id, %{
           status: "passed",
           evidence: evidence,
           evaluated_by: "github_webhook"
         }) do
      {:ok, updated} ->
        Logger.info(
          "[Webhook] Evaluated pr_merged validation #{updated.id} as passed " <>
            "for task #{task_id} (PR #{pr["html_url"]})"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[Webhook] Failed to evaluate pr_merged validation for task #{task_id}: " <>
            inspect(reason)
        )

        :error
    end
  end

  # A NAMED NON-OUTCOME. The delivery is real — the PR merged, the changelog
  # row is written — it is just not this task's deploy. Nothing passes, and
  # the stage stays `running`, but the delivery leaves a trace in three
  # places so that "the deploy is stuck" is answerable without a GitHub
  # spelunk: a `warning` log (the same level task 019f9b34 promoted the
  # no-match log to, for the same reason — a silent miss is invisible),
  # telemetry, and an evidence entry on the first pending gate.
  defp record_unmatched_repo_delivery(candidates, task_id, delivering_repo, pr) do
    expected = expected_repos(candidates, task_id)

    Logger.warning(
      "[Webhook] Merged PR #{pr["html_url"]} delivered from #{inspect(delivering_repo)} " <>
        "matched no pr_merged gate on task #{task_id} (gates: #{inspect(expected)}) — " <>
        unmatched_cause(delivering_repo, expected) <>
        " Nothing was passed; the merge is real but it is not this gate's merge. The " <>
        "deploy stage stays running until every declared repository merges. See task " <>
        "019fa63a."
    )

    :telemetry.execute(
      [:platform, :tasks, :pr_merged, :unmatched_repo],
      %{count: 1},
      %{task_id: task_id, delivering_repo: delivering_repo, expected_repos: expected}
    )

    append_unmatched_repo_delivery(List.first(candidates), delivering_repo, pr)
  end

  # The two causes present identically as "the deploy is stuck", and the fix
  # is different for each, so the log says which one it is rather than
  # leaving an operator to diff the two lists by eye.
  defp unmatched_cause(delivering_repo, expected) do
    if Enum.any?(expected, &RepoRef.same?(&1, delivering_repo)) do
      "that repository IS in the deploy's repo set, so the gate for it is unscoped " <>
        "(a plan minted before per-repo gates) and ambiguous on a multi-repo task. " <>
        "Pass it by hand, or re-inject the deploy stage."
    else
      "that repository is not in the deploy's repo set. If the task really lands " <>
        "there, add it to the task's deploy_strategy repos."
    end
  end

  # The gates' OWN identities first — that is what the operator has to
  # reconcile the delivery against. Only when none of them carries one (a
  # plan minted before the gates were scoped) fall back to re-resolving the
  # task's repo set.
  defp expected_repos(candidates, task_id) do
    case candidates |> Enum.map(&gate_repo/1) |> Enum.reject(&is_nil/1) do
      [] -> task_id |> resolved_repos() |> Enum.map(& &1.slug) |> Enum.reject(&is_nil/1)
      repos -> repos
    end
  end

  # Written with a direct `Validation.changeset/2` + `Repo.update/2` rather
  # than `PlanEngine.evaluate_validation/2` ON PURPOSE: that function
  # transitions the validation's status and would advance the stage, which is
  # the exact thing an unmatched delivery must not do. `status` is untouched
  # here.
  defp append_unmatched_repo_delivery(%Validation{} = validation, delivering_repo, pr) do
    evidence = validation.evidence || %{}

    existing =
      case Map.get(evidence, "unmatched_repo_deliveries") do
        list when is_list(list) -> list
        _ -> []
      end

    entry = %{
      "repo" => delivering_repo,
      "pr_url" => pr["html_url"],
      "observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    validation
    |> Validation.changeset(%{
      evidence: Map.put(evidence, "unmatched_repo_deliveries", existing ++ [entry])
    })
    |> Repo.update()
    |> case do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Webhook] Failed to record unmatched repo delivery on validation " <>
            "#{validation.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp append_unmatched_repo_delivery(nil, _delivering_repo, _pr), do: :ok

  # The CI-side twin of `record_unmatched_repo_delivery/4`: a `check_suite`
  # that ran in a repository none of the task's `ci_passed` gates name.
  # Nothing is evaluated — not `passed`, and emphatically not `failed`, since
  # a green in another repository says nothing about this one either way.
  #
  # DEDUPED BY REPOSITORY, unlike the merge-side recorder. A merge is a
  # once-per-PR fact worth listing individually; CI fires on every push, so
  # an append-always list here would grow without bound for as long as anyone
  # keeps pushing to the wrong repository. One entry per repository carries
  # the whole signal — WHICH repository is delivering CI nobody asked for —
  # and `last_seen_at` keeps it current.
  defp record_unmatched_ci_delivery(candidates, task_id, delivering_repo, branch, run_url) do
    expected = expected_repos(candidates, task_id)

    Logger.warning(
      "[Webhook] CI run #{inspect(run_url)} on branch #{branch} delivered from " <>
        "#{inspect(delivering_repo)} matched no ci_passed gate on task #{task_id} " <>
        "(gates: #{inspect(expected)}) — nothing was evaluated. A CI result from one " <>
        "repository is not a CI result for another. See task 019fa63a."
    )

    :telemetry.execute(
      [:platform, :tasks, :ci_passed, :unmatched_repo],
      %{count: 1},
      %{task_id: task_id, delivering_repo: delivering_repo, expected_repos: expected}
    )

    append_unmatched_ci_delivery(List.first(candidates), delivering_repo, branch, run_url)
  end

  defp append_unmatched_ci_delivery(%Validation{} = validation, delivering_repo, branch, run_url) do
    evidence = validation.evidence || %{}

    existing =
      case Map.get(evidence, "unmatched_repo_ci_deliveries") do
        list when is_list(list) -> list
        _ -> []
      end

    entry = %{
      "repo" => delivering_repo,
      "branch" => branch,
      "run_url" => run_url,
      "last_seen_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    deduped =
      Enum.reject(existing, fn
        %{"repo" => repo} -> repo == delivering_repo
        _ -> false
      end)

    validation
    |> Validation.changeset(%{
      evidence: Map.put(evidence, "unmatched_repo_ci_deliveries", deduped ++ [entry])
    })
    |> Repo.update()
    |> case do
      {:ok, _updated} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[Webhook] Failed to record unmatched CI delivery on validation " <>
            "#{validation.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp append_unmatched_ci_delivery(nil, _delivering_repo, _branch, _run_url), do: :ok

  # ── Stack rollup-PR fan-out ─────────────────────────────────────────────
  #
  # The end-to-end cascade — fan out `pr_merged` to every member, flip
  # the stack to `done`, emit uniform telemetry — was extracted to
  # `Platform.Tasks.RollupWebhookProcessor` (task 019f7b7f stage 3) so
  # both this webhook receiver AND the operator recovery Mix task
  # (`mix platform.stacks.reprocess_rollup_pr`) drive the same code
  # path. The controller keeps the branch-lookup + base-branch guard
  # (webhook-specific concerns); the processor owns the actual work.
  #
  # The `:webhook_stack_fault` process-dictionary test seam that
  # verifies the outer rescue path is preserved inside the processor —
  # `Process.put(:webhook_stack_fault, :raise)` in a test process still
  # raises through the fan-out, and the outer `try/rescue` here still
  # catches it and falls back to the per-task path.

  defp format_merged_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_merged_at(_), do: nil

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
