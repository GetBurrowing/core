defmodule PlatformWeb.GithubWebhookController do
  @moduledoc """
  Receives GitHub webhook events and processes them.

  Handles:
  - `pull_request` events with `action: "closed"` + `merged: true` → changelog
    entries and auto-evaluate the task's pending `pr_merged` validation
  - `check_suite.completed` → auto-evaluate `ci_passed` validations via PlanEngine
  - `workflow_run.completed` → auto-evaluate `ci_passed` validations via PlanEngine

  HMAC signature verification is performed when a project-level webhook secret
  is configured in `project.deploy_config["webhook_secret"]`.
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
    Stack,
    Stacks,
    Stage,
    Task,
    Validation
  }

  require Logger

  # ── Plugs ────────────────────────────────────────────────────────────────

  plug(:verify_signature when action in [:handle])

  # ── Handlers ─────────────────────────────────────────────────────────────

  @doc """
  Handle merged pull request events → create changelog entries.
  """
  def handle(conn, %{"action" => "closed", "pull_request" => pr} = _params) do
    if pr["merged"] do
      process_merged_pr(conn, pr)
    else
      conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not merged"})
    end
  end

  @doc """
  Handle check_suite.completed events → evaluate ci_passed validations.
  """
  def handle(conn, %{"action" => "completed", "check_suite" => check_suite} = _params) do
    branch = check_suite["head_branch"]
    conclusion = check_suite["conclusion"]
    sha = get_in(check_suite, ["head_sha"])
    run_url = get_in(check_suite, ["url"])

    process_ci_event(conn, branch, conclusion, sha, run_url, "check_suite")
  end

  @doc """
  Handle workflow_run.completed events → evaluate ci_passed validations.
  """
  def handle(conn, %{"action" => "completed", "workflow_run" => workflow_run} = _params) do
    branch = workflow_run["head_branch"]
    conclusion = workflow_run["conclusion"]
    sha = get_in(workflow_run, ["head_sha"])
    run_url = get_in(workflow_run, ["html_url"])

    process_ci_event(conn, branch, conclusion, sha, run_url, "workflow_run")
  end

  def handle(conn, _params) do
    conn |> put_status(:ok) |> json(%{status: "ignored", reason: "not a relevant event"})
  end

  # ── CI event processing ─────────────────────────────────────────────────

  defp process_ci_event(conn, branch, conclusion, sha, run_url, event_type) do
    task_id = Changelog.extract_task_id_from_branch(branch)

    if task_id do
      case find_pending_ci_validation(task_id) do
        nil ->
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

        validation ->
          status = if conclusion == "success", do: "passed", else: "failed"

          evidence = %{
            "event_type" => event_type,
            "conclusion" => conclusion,
            "sha" => sha,
            "run_url" => run_url,
            "branch" => branch,
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
                  "for task #{task_id} (#{event_type}, conclusion: #{conclusion})"
              )

              # After CI passes, check if auto-merge should fire
              if status == "passed" do
                maybe_trigger_auto_merge(task_id, branch)
              end

              conn
              |> put_status(:created)
              |> json(%{
                status: "evaluated",
                validation_id: updated.id,
                result: status
              })

            {:error, reason} ->
              Logger.warning(
                "[Webhook] Failed to evaluate ci_passed validation: #{inspect(reason)}"
              )

              conn
              |> put_status(:unprocessable_entity)
              |> json(%{status: "error", reason: inspect(reason)})
          end
      end
    else
      conn
      |> put_status(:ok)
      |> json(%{status: "ignored", reason: "branch does not match task pattern"})
    end
  end

  @doc false
  def find_pending_ci_validation(task_id) do
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
        # see `find_pending_pr_merged_validation/1` below for the full rationale.
        where: s.status == "running",
        where: v.kind == "ci_passed",
        where: v.status == "pending",
        order_by: [asc: s.position],
        limit: 1
      )

    Repo.one(query)
  end

  # ── Auto-merge ───────────────────────────────────────────────────────────

  defp maybe_trigger_auto_merge(task_id, branch) do
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
        task = Tasks.ensure_project_loaded(task)
        strategy = Tasks.resolve_deploy_strategy(task)

        if AutoMerger.should_auto_merge?(strategy) do
          # Find the pending pr_merged validation for this task
          case find_pending_pr_merged_validation(task_id) do
            nil ->
              # Stays at `debug` on purpose (task 019f9b34): this fires after
              # every CI success on the task branch while auto-merge is
              # configured, which is routinely long before any deploy stage
              # exists. Genuinely a normal no-op.
              Logger.debug(
                "[Webhook] No pending pr_merged validation for auto-merge on task #{task_id}"
              )

            pr_validation ->
              # Find the PR number from the branch
              repo_url = task.project && task.project.repo_url
              method = AutoMerger.merge_method(strategy)

              if repo_url do
                # Spawn async task for the merge (with timeout)
                Elixir.Task.start(fn ->
                  case find_pr_number_for_branch(repo_url, branch) do
                    {:ok, pr_number} ->
                      # Pass the task so AutoMerger's defense-in-depth
                      # guard short-circuits if stack_id was set after
                      # the controller-level check.
                      result = AutoMerger.execute_merge(task, repo_url, pr_number, method)
                      AutoMerger.record_merge_result(pr_validation.id, result)

                    {:error, reason} ->
                      Logger.warning(
                        "[Webhook] Could not find PR for branch #{branch}: #{inspect(reason)}"
                      )

                      AutoMerger.record_merge_result(
                        pr_validation.id,
                        {:error, :not_found,
                         "Could not find PR for branch #{branch}: #{inspect(reason)}"}
                      )
                  end
                end)
              else
                Logger.warning(
                  "[Webhook] No repo_url configured for task #{task_id}, skipping auto-merge"
                )
              end
          end
        end
    end
  end

  @doc false
  def find_pending_pr_merged_validation(task_id) do
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
        order_by: [asc: s.position],
        limit: 1
      )

    Repo.one(query)
  end

  defp find_pr_number_for_branch(repo_url, branch) do
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

    case System.cmd("gh", args, stderr_to_stdout: true) do
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

  # ── Merged PR processing (changelog) ────────────────────────────────────

  defp process_merged_pr(conn, pr) do
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
    #       QUERY was the miss, because `find_pending_pr_merged_validation/1`
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
              maybe_evaluate_pr_merged_validation(task_id, pr, merged_at)
            else
              :ok
            end
          end

        nil ->
          if is_binary(task_id) do
            maybe_evaluate_pr_merged_validation(task_id, pr, merged_at)
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
          maybe_evaluate_pr_merged_validation(task_id, pr, merged_at)
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

  defp maybe_evaluate_pr_merged_validation(task_id, pr, merged_at) do
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
        do_evaluate_pr_merged_validation(task_id, pr, merged_at)
    end
  end

  defp do_evaluate_pr_merged_validation(task_id, pr, merged_at) do
    case find_pending_pr_merged_validation(task_id) do
      nil ->
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

      validation ->
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
  end

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

  # ── HMAC signature verification ─────────────────────────────────────────

  @doc false
  defp verify_signature(conn, _opts) do
    # We need the raw body for HMAC verification.
    # If no signature header is present, skip verification (backward compat).
    signature = get_req_header(conn, "x-hub-signature-256") |> List.first()

    if signature do
      raw_body = conn.assigns[:raw_body] || read_raw_body(conn)

      # Try to find the webhook secret from the request context.
      # The repo URL in the payload maps to a project's webhook_secret.
      repo_url = extract_repo_url(conn.params)
      secret = lookup_webhook_secret(repo_url)

      cond do
        is_nil(secret) ->
          # No secret configured for this project — skip verification
          conn

        verify_hmac(raw_body, signature, secret) ->
          conn

        true ->
          Logger.warning("[Webhook] HMAC signature mismatch for repo: #{repo_url}")

          conn
          |> put_status(:unauthorized)
          |> json(%{status: "error", reason: "signature mismatch"})
          |> halt()
      end
    else
      # No signature header — backward compat, allow through
      conn
    end
  end

  defp read_raw_body(conn) do
    case Plug.Conn.read_body(conn) do
      {:ok, body, _conn} -> body
      _ -> ""
    end
  end

  defp extract_repo_url(params) do
    get_in(params, ["repository", "html_url"])
  end

  defp lookup_webhook_secret(nil), do: nil

  defp lookup_webhook_secret(repo_url) do
    alias Platform.Tasks.Project

    project =
      Project
      |> where([p], p.repo_url == ^repo_url)
      |> limit(1)
      |> Repo.one()

    case project do
      %{deploy_config: %{"webhook_secret" => secret}} when is_binary(secret) and secret != "" ->
        secret

      _ ->
        nil
    end
  end

  @doc false
  def verify_hmac(body, signature, secret) do
    # signature format: "sha256=<hex>"
    case String.split(signature, "=", parts: 2) do
      ["sha256", hex_digest] ->
        computed = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
        Plug.Crypto.secure_compare(computed, String.downcase(hex_digest))

      _ ->
        false
    end
  end
end
