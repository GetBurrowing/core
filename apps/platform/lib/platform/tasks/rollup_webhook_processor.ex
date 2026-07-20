defmodule Platform.Tasks.RollupWebhookProcessor do
  @moduledoc """
  End-to-end processor for a merged stack rollup PR's fan-out cascade.

  Extracted from `PlatformWeb.GithubWebhookController` (task 019f7b7f
  stage 3) so both the webhook receiver AND the operator recovery
  Mix task (`mix platform.stacks.reprocess_rollup_pr`) can drive the
  same code path without duplicating the fan-out + status-cascade +
  telemetry-emit chain.

  Not overlapping with `Mix.Tasks.Platform.BackfillStackDeployCascade`:
  that task recovers stacks already at `status: "done"` with stranded
  members (post-PR-#531 hang shape). This processor is the FRESH
  webhook path: stack is still `deploying`, members haven't cascaded,
  the webhook simply never arrived or arrived and was dropped.

  Public entry:

    * `process_stack_merged_pr/4` — pass a `%Stack{}` + the parsed
      pull_request payload map + merged_at DateTime + optional
      per-task task_id. Returns `:ok` on success, `:error` when the
      stack's terminal `complete_rollup_merge/2` fails. Never raises
      (the caller's outer rescue is preserved for the webhook path,
      but the Mix task also needs the same never-crash guarantee so
      one bad stack doesn't halt an operator recovery loop).

  Idempotency: replays route through the full chain — `fan_out_rollup_merge`
  skips already-`done` members via `unexpected_status` anomaly, and
  `Stacks.complete_rollup_merge/2` returns `{:ok, stack}` unchanged
  when the stack is already `done` with `metadata["rollup_merge"]`
  populated. `StackDeployer.handle_rollup_pr_merged/2` is replay-aware
  as well — it re-emits the `:cascade_completed` telemetry for
  dashboard parity but never re-stamps `metadata.rollup_pr.merged_at`
  or re-kicks the rollup-branch delete.
  """

  import Ecto.Query

  require Logger

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{Plan, PlanEngine, Stack, StackDeployer, Stacks, Stage, Task, Validation}

  # Member statuses that are considered valid sources for a rollup-PR
  # `pr_merged` fan-out (ADR 0041 §"Stack-level deploy"). See the
  # original controller comment: `in_review` = member finished work
  # waiting on the rollup PR; `deploying` = member picked up by
  # `StackDeployer` mid-deploy. Anything else → `unexpected_status:*`
  # anomaly, deliberately NOT passed to avoid masking workflow bugs
  # where the webhook arrives out of order.
  @rollup_fan_out_expected_member_statuses ["in_review", "deploying"]

  @doc """
  Process a rollup-PR merge end-to-end. See module doc for full
  semantics; equivalent to the controller's private
  `process_stack_merged_pr/4` before the extraction.

  Steps:

    1. Fan `pr_merged` pass out to every eligible member.
    2. Transition the stack itself to `done` via
       `Stacks.complete_rollup_merge/2` (which stamps the
       `metadata["rollup_merge"]` summary).
    3. Route through `StackDeployer.handle_rollup_pr_merged/2` to
       emit the uniform `[:platform, :stacks, :deploy, :cascade_completed]`
       telemetry event + kick the rollup-branch cleanup pipeline.

  Returns `:ok` on the happy path (and on legitimate replays),
  `:error` when `Stacks.complete_rollup_merge/2` fails.

  Args:

    * `stack` — the `%Stack{}` matched by the webhook / operator lookup.
    * `pr` — the parsed `pull_request` payload map (must carry
      `html_url`, `merge_commit_sha`, `merged_by`/`user`).
    * `merged_at` — `%DateTime{}` (or nil / ISO8601 string, tolerated).
    * `task_id` — the extracted per-task id if the PR carried one on
      its branch; may be nil for pure rollup PRs. Kept in the
      signature for parity with the controller's original call shape
      (the fan-out path does NOT need it, but future call sites may
      want to log it or thread per-task fallback).
  """
  @spec process_stack_merged_pr(
          Stack.t(),
          map(),
          DateTime.t() | String.t() | nil,
          String.t() | nil
        ) :: :ok | :error
  def process_stack_merged_pr(%Stack{} = stack, pr, merged_at, _task_id) do
    # Preserved test seam: the controller's exception-rescue path
    # sets `Process.put(:webhook_stack_fault, :raise)` to induce a
    # fault inside the fan-out branch. Kept here so extracted-module
    # coverage still exercises the outer rescue in the controller.
    maybe_inject_test_fault()

    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}
    was_already_done = stack.status == "done" and Map.has_key?(base_meta, "rollup_merge")

    if was_already_done do
      Logger.info(
        "[RollupWebhookProcessor] Stack #{stack.id} rollup-PR replay (status=done, " <>
          "rollup_merge set); routing through fan-out/cascade chain for telemetry parity — " <>
          "no state changes expected (PR=#{pr["html_url"]})"
      )
    end

    {passed, anomalies} = fan_out_rollup_merge(stack, pr, merged_at)
    passed_member_ids = Enum.map(passed, & &1.task_id) |> Enum.reject(&is_nil/1)

    # Real-degradation guard (mirrors the controller's original log):
    # replays where every member is already `done` fall into the
    # `unexpected_status` anomaly bucket — that's design, not
    # degradation. Only raise ERROR when a fresh delivery produced
    # zero passes.
    if passed_member_ids == [] and not was_already_done do
      Logger.error(
        "[RollupWebhookProcessor] Stack #{stack.id} rollup fan-out completed with ZERO " <>
          "passed members (every member anomalous). PR=#{pr["html_url"]} " <>
          "anomalies=#{inspect(anomalies)}. Marking stack done with degraded=true; " <>
          "operator triage required."
      )
    end

    attrs = %{
      passed_member_ids: passed_member_ids,
      anomalies: anomalies,
      merge_commit_sha: pr["merge_commit_sha"],
      merged_at: merged_at
    }

    case Stacks.complete_rollup_merge(stack, attrs) do
      {:ok, updated} ->
        unless was_already_done do
          Logger.info(
            "[RollupWebhookProcessor] Stack #{stack.id} transitioned to done via rollup-merge " <>
              "fan-out (#{length(passed_member_ids)} member(s) passed, " <>
              "#{length(anomalies)} anomaly/anomalies)"
          )
        end

        # `complete_rollup_merge/2` stamps `rollup_merge` metadata +
        # flips status to done, but does NOT trigger rollup-branch
        # cleanup, cascade-fallback, or the uniform
        # `:stacks, :deploy, :pr_merged` telemetry. Route through
        # `handle_rollup_pr_merged/2` so its replay branch invokes
        # `cascade_members_to_done/2` and the `:cascade_completed`
        # telemetry event fires once per delivery.
        _ = StackDeployer.handle_rollup_pr_merged(updated, pr["merge_commit_sha"])

        :ok

      {:error, reason} ->
        Logger.warning(
          "[RollupWebhookProcessor] Stack #{stack.id} complete_rollup_merge failed: " <>
            inspect(reason)
        )

        :error
    end
  end

  # ── Internal fan-out ────────────────────────────────────────────────────

  # Pass `pr_merged` for every member of `stack` in a single transaction.
  # See original controller comment (deleted from that module in the
  # extraction) for the full anomaly-handling and Ecto reentrancy
  # rationale.
  defp fan_out_rollup_merge(%Stack{} = stack, pr, merged_at) do
    Logger.info(
      "[RollupWebhookProcessor] Rollup-PR merge detected for stack #{stack.id} " <>
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
            anomaly = %{
              "task_id" => member.id,
              "member_status" => member.status,
              "reason" => "unexpected_status:" <> member.status,
              "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
            }

            Logger.warning(
              "[RollupWebhookProcessor] Stack #{stack.id} rollup fan-out: member task " <>
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

  defp fan_out_member(stack, member, evidence_base, passed_acc, anomaly_acc) do
    case find_pending_pr_merged_validation(member.id) do
      nil ->
        anomaly = %{
          "task_id" => member.id,
          "member_status" => member.status,
          "reason" => "no_pending_pr_merged",
          "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }

        Logger.warning(
          "[RollupWebhookProcessor] Stack #{stack.id} rollup fan-out: member task " <>
            "#{member.id} (status=#{member.status}) has no pending pr_merged validation; " <>
            "recording anomaly and skipping"
        )

        {passed_acc, [anomaly | anomaly_acc]}

      validation ->
        evidence = Map.merge(evidence_base, %{"member_task_id" => member.id})

        case PlanEngine.evaluate_validation(validation.id, %{
               status: "passed",
               evidence: evidence,
               evaluated_by: "github_webhook"
             }) do
          {:ok, updated} ->
            Logger.info(
              "[RollupWebhookProcessor] Evaluated pr_merged validation #{updated.id} as " <>
                "passed for stack member task #{member.id} (stack #{stack.id})"
            )

            promote_member_to_done(stack, member)

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
              "[RollupWebhookProcessor] Stack #{stack.id} rollup fan-out: failed to " <>
                "evaluate pr_merged for member #{member.id}: #{inspect(reason)}"
            )

            {passed_acc, [anomaly | anomaly_acc]}
        end
    end
  end

  defp promote_member_to_done(%Stack{} = stack, %Task{status: "done"} = member) do
    Logger.debug(
      "[RollupWebhookProcessor] Stack #{stack.id} fan-out: member #{member.id} already done; " <>
        "skipping promote (idempotent replay)"
    )

    :ok
  end

  defp promote_member_to_done(%Stack{} = stack, %Task{} = member) do
    case Tasks.transition_task(member, "done") do
      {:ok, _updated} ->
        Logger.info(
          "[RollupWebhookProcessor] Stack #{stack.id} fan-out: member task #{member.id} " <>
            "promoted #{member.status} → done"
        )

        :ok

      {:error, :invalid_transition} ->
        Logger.warning(
          "[RollupWebhookProcessor] Stack #{stack.id} fan-out: refusing to promote member " <>
            "#{member.id} from #{member.status} → done (invalid_transition); leaving " <>
            "status unchanged"
        )

        :error

      {:error, reason} ->
        Logger.warning(
          "[RollupWebhookProcessor] Stack #{stack.id} fan-out: failed to promote member " <>
            "#{member.id} from #{member.status} → done: #{inspect(reason)}"
        )

        :error
    end
  end

  @doc """
  Reachable pending-pr_merged lookup for a task.

  Publicly reachable (`@doc false` semantics — internal but used by
  both the controller's auto-merge path and the Mix task's dry-run
  preview). Mirror of the definition in
  `PlatformWeb.GithubWebhookController.find_pending_pr_merged_validation/1`.
  """
  @spec find_pending_pr_merged_validation(String.t()) :: Validation.t() | nil
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

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp format_merged_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_merged_at(str) when is_binary(str), do: str
  defp format_merged_at(_), do: nil

  # Test-only fault seam (see the original controller comment):
  # `Process.put(:webhook_stack_fault, :raise)` in a test process to
  # induce a fault inside the fan-out branch. Production code never
  # sets the key, so this is a noop.
  defp maybe_inject_test_fault do
    case Process.get(:webhook_stack_fault) do
      fun when is_function(fun, 0) -> fun.()
      :raise -> raise "synthetic webhook stack fault (test only)"
      _ -> :noop
    end
  end
end
