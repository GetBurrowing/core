defmodule Mix.Tasks.Platform.Stacks.ReprocessRollupPr do
  @moduledoc """
  Operator escape hatch for re-running the rollup-PR merge cascade
  against a stack whose GitHub webhook delivery was lost or dropped.

  Distinct from `Mix.Tasks.Platform.BackfillStackDeployCascade`:

    * `backfill_stack_deploy_cascade` recovers stacks already at
      `status: "done"` with stranded members — the PR #531 hang shape
      where the fan-out ran but the member cascade did not.
    * `stacks.reprocess_rollup_pr` (this task) recovers stacks where
      the webhook NEVER ran at all: stack still at `deploying`, members
      still at `in_review`/`deploying`, PR merged on GitHub weeks ago.

  Uses the same `Platform.Tasks.RollupWebhookProcessor.process_stack_merged_pr/4`
  entry point the webhook controller drives, so behavior + telemetry
  are identical to a fresh delivery.

  ## Usage

      # Dry-run: hydrate the PR, resolve the stack, print what WOULD
      # be flipped. Never mutates. Safe to run against production.
      bin/platform eval \\
        'Mix.Tasks.Platform.Stacks.ReprocessRollupPr.run([
           "--pr-number", "569",
           "--repo", "StartupSuite/core"
         ])'

      # Real run: mutate the stack + members. Requires `--confirm`.
      bin/platform eval \\
        'Mix.Tasks.Platform.Stacks.ReprocessRollupPr.run([
           "--pr-number", "569",
           "--repo", "StartupSuite/core",
           "--confirm"
         ])'

      # Explicit stack id (safest — bypass the multi-strategy lookup):
      bin/platform eval \\
        'Mix.Tasks.Platform.Stacks.ReprocessRollupPr.run([
           "--pr-number", "569",
           "--repo", "StartupSuite/core",
           "--stack-id", "<uuid>",
           "--confirm"
         ])'

  ## Options

    * `--pr-number <n>` — required. GitHub PR number to hydrate.
    * `--repo <owner/name>` — required. `gh pr view -R <this>`.
    * `--stack-id <uuid>` — optional. Explicit stack id, skips the
      multi-strategy `Stacks.get_stack_for_pull_request/1` lookup.
      Preferred when the operator already knows the stack (e.g. from
      a stack-page URL) because it avoids any surprise strategy hits.
    * `--confirm` — required to mutate. Absent = dry-run.

  ## Failure modes surfaced to the operator

    * PR not merged → refuses to proceed (loudly). We don't want an
      operator to accidentally advance a stack for a PR that was
      closed-without-merge or is still open.
    * Stack lookup failed → refuses to proceed. Operator must pass an
      explicit `--stack-id` in this case (or repair the stack's
      `rollup_branch` / `metadata.rollup_pr.number` first).
    * `gh` shell not available or auth failed → surfaces the raw
      stderr from `gh` so the operator can fix their env.

  ## Testability

  `do_run/2` accepts an injected `gh_runner` (mirrors the `NoopRunner`
  pattern in `github_webhook_rollup_cascade_test.exs`) so tests can
  drive the task without shelling out. See
  `test/mix/tasks/platform/stacks_reprocess_rollup_pr_test.exs`.
  """

  use Mix.Task

  alias Platform.Repo
  alias Platform.Tasks.{RollupWebhookProcessor, Stack, Stacks}

  require Logger

  @shortdoc "Reprocess a merged rollup PR (operator recovery when the webhook dropped)"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, _, _} =
      OptionParser.parse(args,
        strict: [
          pr_number: :string,
          repo: :string,
          stack_id: :string,
          confirm: :boolean
        ]
      )

    do_run(opts)
  end

  @doc """
  Public for testability. Same option surface as `run/1`; additionally
  accepts an `injects` keyword:

    * `:gh_runner` — a module implementing `pr_view/2` that mimics the
      shape of `gh pr view -R <repo> <n> --json ...`, returning
      `{:ok, pr_map} | {:error, reason}`. Defaults to
      `#{inspect(__MODULE__)}.ShellGhRunner`.
    * `:processor` — a module exposing
      `process_stack_merged_pr/4`. Defaults to
      `Platform.Tasks.RollupWebhookProcessor` (production path). Tests
      can inject a fake to assert the call shape without invoking the
      full fan-out chain.
  """
  @spec do_run(keyword(), keyword()) :: :ok | {:error, term()}
  def do_run(opts, injects \\ []) do
    gh_runner = Keyword.get(injects, :gh_runner, __MODULE__.ShellGhRunner)
    processor = Keyword.get(injects, :processor, RollupWebhookProcessor)

    with :ok <- validate_required(opts),
         pr_number = Keyword.fetch!(opts, :pr_number),
         repo = Keyword.fetch!(opts, :repo),
         {:ok, pr} <- hydrate_pr(gh_runner, pr_number, repo),
         :ok <- require_merged(pr),
         {:ok, stack} <- resolve_stack(opts, pr),
         {:ok, merged_at} <- extract_merged_at(pr) do
      confirm? = Keyword.get(opts, :confirm, false)

      log(
        "[ReprocessRollupPr] PR ##{pr["number"]} merged=#{pr["merged"]} " <>
          "head=#{get_in(pr, ["headRefName"])} base=#{get_in(pr, ["baseRefName"])} " <>
          "sha=#{get_in(pr, ["mergeCommit", "oid"])}"
      )

      log(
        "[ReprocessRollupPr] Resolved stack #{stack.id} (slug=#{stack.slug}, " <>
          "status=#{stack.status}, rollup_branch=#{stack.rollup_branch})"
      )

      preview_members(stack)

      if confirm? do
        # Normalize the PR payload from `gh pr view --json` shape into
        # the shape the webhook processor expects (webhook payload uses
        # nested `head.ref` / `base.ref` / `merge_commit_sha` /
        # `merged_by.login`; `gh --json` uses `headRefName` /
        # `baseRefName` / `mergeCommit.oid` / `mergedBy.login`).
        webhook_pr = to_webhook_shape(pr)

        result = processor.process_stack_merged_pr(stack, webhook_pr, merged_at, nil)

        log(
          "[ReprocessRollupPr] processor.process_stack_merged_pr returned: " <>
            inspect(result)
        )

        result
      else
        log(
          "[ReprocessRollupPr] DRY-RUN — no mutations. Pass `--confirm` to actually " <>
            "advance the stack + fan pr_merged out to members."
        )

        :ok
      end
    else
      {:error, reason} = err ->
        log("[ReprocessRollupPr] ABORT: #{inspect(reason)}")
        err
    end
  end

  # ── Option validation ────────────────────────────────────────────────────

  defp validate_required(opts) do
    cond do
      is_nil(Keyword.get(opts, :pr_number)) ->
        {:error, "--pr-number is required"}

      is_nil(Keyword.get(opts, :repo)) ->
        {:error, "--repo is required (e.g. StartupSuite/core)"}

      true ->
        :ok
    end
  end

  # ── PR hydration ─────────────────────────────────────────────────────────

  defp hydrate_pr(gh_runner, pr_number, repo) do
    case gh_runner.pr_view(pr_number, repo) do
      {:ok, pr} when is_map(pr) ->
        {:ok, pr}

      {:ok, other} ->
        {:error, {:unexpected_gh_output, other}}

      {:error, reason} ->
        {:error, {:gh_failed, reason}}
    end
  end

  defp require_merged(%{"merged" => true}), do: :ok

  defp require_merged(%{"merged" => merged, "number" => n}),
    do: {:error, {:not_merged, "PR ##{n} merged=#{inspect(merged)} — refusing to reprocess"}}

  defp require_merged(other),
    do: {:error, {:not_merged, "PR payload missing `merged` key: #{inspect(other)}"}}

  defp extract_merged_at(%{"mergedAt" => iso}) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, _} -> {:error, {:bad_merged_at, iso}}
    end
  end

  defp extract_merged_at(_), do: {:ok, DateTime.utc_now()}

  # ── Stack resolution ─────────────────────────────────────────────────────

  # Explicit `--stack-id` bypasses the multi-strategy lookup. Preferred
  # when the operator has the id in hand.
  defp resolve_stack(opts, pr) do
    case Keyword.get(opts, :stack_id) do
      id when is_binary(id) ->
        case Repo.get(Stack, id) do
          %Stack{} = stack -> {:ok, stack}
          nil -> {:error, {:stack_not_found, id}}
        end

      _ ->
        # Fall back to the same multi-strategy lookup the webhook uses.
        # Translate `gh --json` shape to what
        # `Stacks.get_stack_for_pull_request/1` expects (nested
        # `head.ref` + numeric `number`).
        payload = to_webhook_shape(pr)

        case Stacks.get_stack_for_pull_request(payload) do
          %Stack{} = stack ->
            {:ok, stack}

          nil ->
            {:error,
             {:stack_lookup_failed,
              "no stack matched PR ##{pr["number"]} via rollup_branch / pr_number / slug — " <>
                "pass --stack-id to bypass the lookup"}}
        end
    end
  end

  # ── Dry-run preview ──────────────────────────────────────────────────────

  defp preview_members(%Stack{} = stack) do
    members = Stacks.members(stack.id)

    log("[ReprocessRollupPr] Stack has #{length(members)} member(s):")

    for member <- members do
      pending =
        case RollupWebhookProcessor.find_pending_pr_merged_validation(member.id) do
          nil -> "no pending pr_merged"
          %{id: id} -> "pending pr_merged=#{id}"
        end

      log("  - task #{member.id} status=#{member.status} #{pending}")
    end

    :ok
  end

  # ── Payload shape translation ────────────────────────────────────────────

  # `gh pr view --json …` produces:
  #     %{"number" => 569, "merged" => true, "mergeCommit" => %{"oid" => "..."},
  #       "headRefName" => "stack/foo", "baseRefName" => "main",
  #       "mergedAt" => "...", "mergedBy" => %{"login" => "..."},
  #       "user" => %{"login" => "..."}, "htmlUrl" => "https://..."}
  #
  # The webhook processor expects the shape GitHub emits on
  # `pull_request.closed`:
  #     %{"number" => 569, "merged" => true, "merge_commit_sha" => "...",
  #       "head" => %{"ref" => "stack/foo"}, "base" => %{"ref" => "main"},
  #       "merged_at" => "...", "merged_by" => %{"login" => "..."},
  #       "user" => %{"login" => "..."}, "html_url" => "https://..."}
  @doc false
  def to_webhook_shape(pr) when is_map(pr) do
    %{
      "number" => pr["number"],
      "merged" => pr["merged"],
      "merge_commit_sha" => get_in(pr, ["mergeCommit", "oid"]),
      "head" => %{"ref" => pr["headRefName"]},
      "base" => %{"ref" => pr["baseRefName"]},
      "merged_at" => pr["mergedAt"],
      "merged_by" => pr["mergedBy"],
      "user" => pr["user"],
      "html_url" => pr["htmlUrl"]
    }
  end

  # ── Logging shim ─────────────────────────────────────────────────────────

  # Mirror `backfill_stack_deploy_cascade.ex`: prefer `Mix.shell().info/1`
  # so `capture_io` catches output in tests, fall back to `Logger`
  # under `bin/platform eval`.
  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      Logger.info(msg)
    end
  end

  # ── Default gh runner ────────────────────────────────────────────────────

  defmodule ShellGhRunner do
    @moduledoc false
    @behaviour Mix.Tasks.Platform.Stacks.ReprocessRollupPr.GhRunner

    @impl true
    def pr_view(pr_number, repo) do
      args = [
        "pr",
        "view",
        pr_number,
        "-R",
        repo,
        "--json",
        "number,merged,mergeCommit,headRefName,baseRefName,mergedAt,mergedBy,htmlUrl,user"
      ]

      case System.cmd("gh", args, stderr_to_stdout: true) do
        {output, 0} ->
          case Jason.decode(output) do
            {:ok, pr} -> {:ok, pr}
            {:error, err} -> {:error, {:json_decode, err}}
          end

        {output, code} ->
          {:error, {:gh_exit, code, String.trim(output)}}
      end
    end
  end

  defmodule GhRunner do
    @moduledoc false
    @callback pr_view(pr_number :: String.t(), repo :: String.t()) ::
                {:ok, map()} | {:error, term()}
  end
end
