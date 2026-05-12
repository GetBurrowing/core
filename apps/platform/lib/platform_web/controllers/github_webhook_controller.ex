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
  alias Platform.Tasks.{AutoMerger, PlanEngine, Plan, Stack, Stacks, Stage, Task, Validation}

  require Logger

  # Member statuses that are considered valid sources for a rollup-PR
  # `pr_merged` fan-out (ADR 0041 §"Stack-level deploy"). A member at
  # `in_review` has finished its work and is waiting on the rollup PR;
  # a member at `deploying` has been picked up by `StackDeployer` and
  # is mid-deploy. Anything else — `in_progress`, `stack_pending`,
  # `done`, `blocked`, etc. — is recorded as an `unexpected_status:*`
  # anomaly and explicitly NOT passed, to avoid masking workflow bugs
  # where the webhook arrives out of order.
  @rollup_fan_out_expected_member_statuses ["in_review", "deploying"]

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
        where: p.status in ~w(approved),
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

      AutoMerger.defer_for_stack?(task) ->
        # ADR 0041 (T5 stage 3) — stack members never open their own
        # PRs. The stack rollup PR (T6) carries the deploy. Skip the
        # per-task auto-merge entirely.
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
        where: p.status in ~w(approved),
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
    # NOTE on webhook delivery reliability: during T2-T5 dogfooding we
    # observed that `pull_request.closed` events did not always reach
    # this controller, forcing admin-passthrough on `pr_merged` for
    # those merges. Stage 1 here ensures that WHEN the webhook fires
    # for a rollup PR, all member validations are processed correctly;
    # it does NOT fix delivery itself (that investigation is GitHub-
    # side / nginx / gateway and pending separately).
    try do
      case Stacks.get_stack_by_rollup_branch(branch) do
        %Stack{} = stack ->
          process_stack_merged_pr(stack, pr, merged_at, task_id)

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

  defp maybe_evaluate_pr_merged_validation(task_id, pr, merged_at) do
    task = Tasks.get_task_record(task_id)

    cond do
      AutoMerger.defer_for_stack?(task) ->
        # ADR 0041 (T5 stage 3) — stack members' per-task `pr_merged`
        # validations are auto-passed by the stack rollup PR's merge
        # webhook fan-out (T6 owns that). DO NOT auto-pass from the
        # per-task webhook; the per-task branch shouldn't be opening
        # PRs in the first place (the auto-merge guard prevents that),
        # but if a webhook fires for a member's individual branch
        # somehow, the per-task path must NOT pre-empt T6.
        Logger.info(
          "[StackDeployer] task #{task_id} is in stack #{task.stack_id}; deferring to " <>
            "stack deployer (skipping per-task pr_merged auto-pass for PR " <>
            "#{pr["html_url"]})"
        )

        :ok

      true ->
        do_evaluate_pr_merged_validation(task_id, pr, merged_at)
    end
  end

  defp do_evaluate_pr_merged_validation(task_id, pr, merged_at) do
    case find_pending_pr_merged_validation(task_id) do
      nil ->
        Logger.debug("[Webhook] No pending pr_merged validation for task #{task_id} on PR merge")

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

  # ── Stack rollup-PR fan-out (T6 stages 1 + 2) ───────────────────────────

  # Process a rollup-PR merge end-to-end:
  #
  #   1. Fan `pr_merged` pass out to every member (stage 1 logic).
  #   2. Transition the stack itself to `done` via
  #      `Stacks.complete_rollup_merge/2`, recording the per-member
  #      outcome in `stack.metadata["rollup_merge"]` (stage 2).
  #
  # Idempotency: if the stack is already at `done` with a populated
  # `metadata["rollup_merge"]` (a replay of the same webhook),
  # `complete_rollup_merge/2` returns the existing stack unchanged and
  # we short-circuit the fan-out so member validations are NOT
  # re-evaluated. The replay is silent (logged at info) and returns 2xx.
  defp process_stack_merged_pr(%Stack{} = stack, pr, merged_at, _task_id) do
    # Stage 2 test seam: when running in `:test` env tests can set
    # `Application.put_env(:platform, :webhook_stack_fault, fun_or_atom)`
    # to induce a fault inside the stack-fan-out branch and verify the
    # outer rescue/fallback path. Never set in :prod/:dev — this guard
    # short-circuits without that env key.
    maybe_inject_test_fault()

    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    if stack.status == "done" and Map.has_key?(base_meta, "rollup_merge") do
      Logger.info(
        "[Webhook] Stack #{stack.id} already completed (status=done, rollup_merge set); " <>
          "skipping fan-out and stack transition for replayed PR #{pr["html_url"]}"
      )

      :ok
    else
      {passed, anomalies} = fan_out_rollup_merge(stack, pr, merged_at)
      passed_member_ids = Enum.map(passed, & &1.task_id) |> Enum.reject(&is_nil/1)

      if passed_member_ids == [] do
        Logger.error(
          "[Webhook] Stack #{stack.id} rollup fan-out completed with ZERO passed members " <>
            "(every member anomalous). PR=#{pr["html_url"]} anomalies=#{inspect(anomalies)}. " <>
            "Marking stack done with degraded=true; operator triage required."
        )
      end

      attrs = %{
        passed_member_ids: passed_member_ids,
        anomalies: anomalies,
        merge_commit_sha: pr["merge_commit_sha"],
        merged_at: merged_at
      }

      case Stacks.complete_rollup_merge(stack, attrs) do
        {:ok, _updated} ->
          Logger.info(
            "[Webhook] Stack #{stack.id} transitioned to done via rollup-merge fan-out " <>
              "(#{length(passed_member_ids)} member(s) passed, #{length(anomalies)} anomaly/anomalies)"
          )

          :ok

        {:error, reason} ->
          Logger.warning(
            "[Webhook] Stack #{stack.id} complete_rollup_merge failed: #{inspect(reason)}"
          )

          :error
      end
    end
  end

  # Pass `pr_merged` for every member of `stack` in a single transaction.
  #
  # ADR 0041 §"Validation routing": a stack rollup PR satisfies every
  # member's `pr_merged` validation simultaneously. We use one
  # `Repo.transaction/1` so the fan-out is atomic — either every member
  # validation flips to `passed` or none do. (`PlanEngine.evaluate_validation/2`
  # opens its own inner transaction; Ecto reentrancy joins it to the
  # outer one via a savepoint.)
  #
  # Anomaly handling: members are expected to be at `in_review` with a
  # pending `pr_merged` validation on their running review stage. If a
  # member is in some other state — typically `stack_pending` because
  # someone merged the rollup PR out of band before deps cleared — we
  # collect the anomaly and KEEP PROCESSING the remaining members. The
  # canonical record of these anomalies is `stack.metadata["rollup_merge"]
  # ["anomalies"]`, written by `Stacks.complete_rollup_merge/2` (stage 2);
  # this function just returns them to the caller. The webhook handler
  # must never crash on anomalies; that would let the next retry-delivery
  # re-run the whole fan-out and pollute metadata.
  #
  # Returns `{passed_validations, anomalies}` — `passed_validations` is
  # the list of updated `%Validation{}` structs, and `anomalies` is a
  # list of maps each shaped for `metadata["rollup_merge"]["anomalies"]`:
  # `%{"task_id" => id, "reason" => "...", "recorded_at" => iso8601, ...}`.
  defp fan_out_rollup_merge(%Stack{} = stack, pr, merged_at) do
    Logger.info(
      "[Webhook] Rollup-PR merge detected for stack #{stack.id} " <>
        "(rollup_branch=#{stack.rollup_branch}, PR=#{pr["html_url"]}); " <>
        "fanning pr_merged validation pass out to members"
    )

    members = Stacks.members(stack.id)

    evidence_base = %{
      "pr_url" => pr["html_url"],
      "merged_at" => format_merged_at(merged_at),
      "merged_by" => get_in(pr, ["merged_by", "login"]) || get_in(pr, ["user", "login"]),
      "merge_commit_sha" => pr["merge_commit_sha"],
      "stack_id" => stack.id,
      "stack_rollup_branch" => stack.rollup_branch,
      "fanned_out_from_stack_rollup_pr" => true
    }

    Repo.transaction(fn ->
      Enum.reduce(members, {[], []}, fn member, {passed_acc, anomaly_acc} ->
        cond do
          member.status not in @rollup_fan_out_expected_member_statuses ->
            # Member is in an unexpected status for rollup-merge fan-out.
            # Per ADR 0041 §"Stack-level deploy", only `in_review` and
            # `deploying` members are eligible to absorb a rollup-PR
            # merge. Anything else (`in_progress`, `stack_pending`,
            # `done`, `blocked`, etc.) is a contract violation that we
            # record as an anomaly and skip — we deliberately do NOT
            # call `PlanEngine.evaluate_validation/2` for these members,
            # even if they happen to have a pending pr_merged validation,
            # because passing it would mask a real workflow bug.
            anomaly = %{
              "task_id" => member.id,
              "member_status" => member.status,
              "reason" => "unexpected_status:" <> member.status,
              "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            Logger.warning(
              "[Webhook] Stack #{stack.id} rollup fan-out: member task " <>
                "#{member.id} is in unexpected status #{inspect(member.status)} " <>
                "(expected one of #{inspect(@rollup_fan_out_expected_member_statuses)}); " <>
                "recording anomaly and skipping"
            )

            {passed_acc, [anomaly | anomaly_acc]}

          true ->
            fan_out_member(stack, member, evidence_base, passed_acc, anomaly_acc)
        end
      end)
    end)
    |> case do
      {:ok, {passed_acc, anomaly_acc}} ->
        {Enum.reverse(passed_acc), Enum.reverse(anomaly_acc)}

      {:error, reason} ->
        {[],
         [
           %{
             "task_id" => nil,
             "reason" => "transaction_failed",
             "detail" => inspect(reason),
             "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
           }
         ]}
    end
  end

  # Per-member happy path + no-pending anomaly. Extracted so the
  # `fan_out_rollup_merge/3` body stays readable around the
  # member-status check that gates the call.
  defp fan_out_member(stack, member, evidence_base, passed_acc, anomaly_acc) do
    case find_pending_pr_merged_validation(member.id) do
      nil ->
        # No pending pr_merged validation for this member — it
        # either never got a review-stage plan, is still
        # `stack_pending` (deps didn't clear before the rollup
        # merged), or its validation already resolved out of band.
        anomaly = %{
          "task_id" => member.id,
          "member_status" => member.status,
          "reason" => "no_pending_pr_merged",
          "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Logger.warning(
          "[Webhook] Stack #{stack.id} rollup fan-out: member task " <>
            "#{member.id} (status=#{member.status}) has no pending " <>
            "pr_merged validation; recording anomaly and skipping"
        )

        {passed_acc, [anomaly | anomaly_acc]}

      validation ->
        # Stamp the member's task_id onto the validation evidence
        # (used by tests and downstream consumers) and remember it on
        # the returned struct so the caller can collect member ids
        # without a second DB hit.
        evidence = Map.merge(evidence_base, %{"member_task_id" => member.id})

        case PlanEngine.evaluate_validation(validation.id, %{
               status: "passed",
               evidence: evidence,
               evaluated_by: "github_webhook"
             }) do
          {:ok, updated} ->
            Logger.info(
              "[Webhook] Evaluated pr_merged validation #{updated.id} as passed " <>
                "for stack member task #{member.id} (stack #{stack.id})"
            )

            # Tag the in-memory struct with the member task id so
            # `process_stack_merged_pr/4` can build `passed_member_ids`
            # without re-querying.
            tagged = Map.put(updated, :task_id, member.id)
            {[tagged | passed_acc], anomaly_acc}

          {:error, reason} ->
            anomaly = %{
              "task_id" => member.id,
              "member_status" => member.status,
              "reason" => "evaluate_validation_error",
              "detail" => inspect(reason),
              "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            Logger.warning(
              "[Webhook] Stack #{stack.id} rollup fan-out: failed to " <>
                "evaluate pr_merged for member #{member.id}: #{inspect(reason)}"
            )

            {passed_acc, [anomaly | anomaly_acc]}
        end
    end
  end

  defp format_merged_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_merged_at(_), do: nil

  # Test-only fault seam (stage 2). The defensive try/rescue around the
  # stack-fan-out branch is meant to swallow unexpected exceptions and
  # fall back to the per-task path; tests verify that by stashing a
  # marker on the calling process dictionary (`:webhook_stack_fault`).
  # Process-dictionary scope means concurrent (`async: true`) tests
  # cannot leak the fault into one another, since Phoenix runs the
  # controller in the test's own process when invoked via `post/2`.
  # Production code paths never set the key, so this returns `:noop`.
  defp maybe_inject_test_fault do
    case Process.get(:webhook_stack_fault) do
      fun when is_function(fun, 0) -> fun.()
      :raise -> raise "synthetic webhook stack fault (test only)"
      _ -> :noop
    end
  end

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
