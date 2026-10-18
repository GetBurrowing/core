defmodule Mix.Tasks.Burrow.Deploy.ScopeGate do
  @moduledoc """
  Give a `pr_merged` gate the facts it is missing, so
  `Platform.Tasks.DeployMergeReconciler` can poll it.

      mix burrow.deploy.scope_gate <validation_id> \\
        --repo-url https://github.com/Startup-Suite/core \\
        --branch task/envelope-records-019fa63a-02a0-7c9e-b3d1-5f2ae4d81c37

  ## The population this exists for

  Two shapes of gate are unreachable by every automatic path in the tree,
  and both are repaired by writing down a fact rather than by guessing one.

  A gate with `evaluation_payload: nil` — the legacy unscoped row minted
  before gates carried a repository — names no repository at all.
  `DeployMergeReconciler.gate_repo/1`'s nil clause skips it before any
  branch is considered, so no sweep can ever reach it.

  A gate whose payload is scoped but records no `"branch"` was minted
  between `d63abdc0` reaching production (20:47Z 2026-07-31) and the
  recording change landing. The sweeper REFUSES those rather than deriving
  a name, because a derived branch is a source of wrong attribution that
  neither `gh pr list --head` nor GitHub can fail closed on. See
  `DeployMergeReconciler.refuse/2` and the moduledoc there.

  The measured example is task `019fa63a-02a0`. Its merged PR is #644 on
  `task/envelope-records-019fa63a-02a0-…`, a name no derivation in the tree
  produces and `Changelog.extract_task_id_from_branch/1` cannot parse
  either (`changelog.ex:169` wants eight hex characters immediately after
  `task/`, and `envelope-` is not hex). Both paths genuinely miss it. That
  row was closed BY HAND on 2026-07-31 at ~22:08Z, before this command
  existed — which is exactly the cost this command removes, because hand
  passing does not scale and it writes evidence for an observation nobody
  made. Do not read the example as a live queue entry; run
  `DeployMergeReconciler.unrecorded_branch_gates/0` for the current one.

  ## It does not pass the gate

  It writes `"repo"`, `"repo_url"` and `"branch"` and stops. It never calls
  GitHub and it never dispositions the validation. The next sweep observes
  the merge, or does not — so `observed_by: "reconciler"` continues to mean
  a poll actually happened, and an operator supplying facts stays
  distinguishable from an operator supplying a verdict.

  ## What it refuses, and why each refusal is there

  Five of the seven come from the sweeper's own scoping, via
  `DeployMergeReconciler.live_gate/1` — the id must resolve to a row
  `candidates/0` yields: it exists, its kind is `pr_merged`, its status is
  `pending`, its stage is `running`, and its plan is the task's
  `Tasks.current_plan/1`. They are DERIVED from that function rather than
  restated here on purpose; a second copy of "which gates are live" is the
  defect `StackDeployer.review_readiness/1` already shipped once.

  The sixth: it refuses to overwrite a payload that already RECORDS a
  branch. Scoping is a repair for a missing fact, not an edit of a recorded
  one — and a task that has already pushed under one name is precisely the
  case where rewriting the name marks unmerged code as shipped.
  "Already recorded" is `DeployMergeReconciler.branch_recorded?/1`, the
  same `present?/1` predicate the sweeper refuses on and the counter counts
  on, so a blank or nil `"branch"` — which the sweeper DOES refuse and the
  counter DOES count — stays repairable here.

  The seventh: it refuses a `--repo-url` that `Platform.Tasks.RepoRef.slug/1`
  will not normalize, matching `gate_repo/1`'s `not present?(slug) -> :skip`
  guard. A gate this command writes has to be one the sweeper can actually
  poll; writing an unpollable payload would move the hang rather than fix
  it.

  Every refusal exits non-zero via `Mix.raise/1` and names its reason.

  ## One consequence worth knowing before you run it

  Writing a `"repo"` key also moves the gate out of
  `GithubWebhookController.select_unscoped_validation/3`'s reach —
  `unscoped_gate?/1` is `not Map.has_key?(payload, "repo")`. That is the
  point (the gate now names its repository), but it means a nil-payload
  gate stops being matchable by ANY delivery to the task and becomes
  matchable only by one naming this repository. The auto-merge decision is
  unaffected: `AutoMerger.entry_auto_merge?/2` falls back to the
  strategy-wide answer for an entry carrying no `"auto_merge"` key, which
  is the same answer `should_auto_merge?(strategy, nil)` gives today.

  Any other keys already on the payload (`"ci"`, `"auto_merge"`,
  `"merge_method"`) are PRESERVED. They are read by `AutoMerger` and by
  `GithubWebhookController.gate_ci/1`, and a repair that silently dropped
  an `auto_merge: false` into a strategy-level `true` would authorize a
  machine merge the deploy stage was gated against.
  """

  use Mix.Task

  require Logger

  alias Platform.Repo
  alias Platform.Tasks.DeployMergeReconciler
  alias Platform.Tasks.RepoRef
  alias Platform.Tasks.Validation

  @shortdoc "Record repo + branch on a pr_merged gate so the reconciler can poll it"

  @switches [repo_url: :string, branch: :string]

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    case scope(args) do
      {:ok, validation} ->
        report(validation)

      {:error, reason} ->
        Mix.raise(message(reason))
    end
  end

  @doc """
  `run/1` without the non-zero exit — returns `{:ok, validation}` or
  `{:error, reason}` where `reason` names the refusal.

  Public so a caller can branch on the reason atom. `run/1` is still the
  entry point under test, because the contract this stage owes an operator
  is "refuses with a non-zero exit", and only `run/1` produces one.
  """
  @spec scope([String.t()]) :: {:ok, Validation.t()} | {:error, term()}
  def scope(args) when is_list(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    with :ok <- no_unknown_switches(invalid),
         {:ok, validation_id} <- exactly_one_id(positional),
         {:ok, repo_url} <- required(opts, :repo_url, "--repo-url"),
         {:ok, branch} <- required(opts, :branch, "--branch"),
         {:ok, %{validation: validation}} <- live_gate(validation_id),
         :ok <- refuse_recorded_branch(validation),
         {:ok, slug} <- canonical_slug(repo_url) do
      write_scope(validation, slug, repo_url, branch)
    end
  end

  # ── Argument shape ──────────────────────────────────────────────────────

  defp no_unknown_switches([]), do: :ok
  defp no_unknown_switches(invalid), do: {:error, {:unknown_switches, invalid}}

  defp exactly_one_id([id]) when is_binary(id), do: {:ok, id}
  defp exactly_one_id(positional), do: {:error, {:bad_arity, length(positional)}}

  # Blank is not supplied. `--branch ""` must not reach the payload: the
  # sweeper's `present?/1` would refuse it right back, and the operator
  # would have "successfully" written a gate that stays hung.
  defp required(opts, key, flag) do
    case Keyword.get(opts, key) do
      value when is_binary(value) ->
        if String.trim(value) == "", do: {:error, {:blank_option, flag}}, else: {:ok, value}

      _ ->
        {:error, {:missing_option, flag}}
    end
  end

  # ── The five conditions, borrowed rather than restated ──────────────────

  defp live_gate(validation_id) do
    case DeployMergeReconciler.live_gate(validation_id) do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:not_live, validation_id, reason}}
    end
  end

  # ── Repair a missing fact, never edit a recorded one ────────────────────

  defp refuse_recorded_branch(%Validation{evaluation_payload: payload} = validation) do
    if DeployMergeReconciler.branch_recorded?(payload) do
      {:error, {:branch_already_recorded, validation.id, Map.get(payload, "branch")}}
    else
      :ok
    end
  end

  defp canonical_slug(repo_url) do
    case RepoRef.slug(repo_url) do
      slug when is_binary(slug) -> {:ok, slug}
      nil -> {:error, {:unnormalizable_repo_url, repo_url}}
    end
  end

  # ── The write ───────────────────────────────────────────────────────────

  # `Repo.update` and not `PlanEngine.evaluate_validation/2`: the latter
  # DISPOSITIONS a gate, and this command's whole contract is that it does
  # not. Existing keys are merged over rather than replaced — see the
  # moduledoc.
  defp write_scope(%Validation{} = validation, slug, repo_url, branch) do
    payload =
      (validation.evaluation_payload || %{})
      |> Map.merge(%{"repo" => slug, "repo_url" => repo_url, "branch" => branch})

    validation
    |> Ecto.Changeset.change(%{evaluation_payload: payload})
    |> Repo.update()
    |> case do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:write_failed, validation.id, changeset}}
    end
  end

  # ── Output ──────────────────────────────────────────────────────────────

  defp report(%Validation{} = validation) do
    log("[scope_gate] validation #{validation.id} scoped. evaluation_payload:")

    for {key, value} <- Enum.sort(validation.evaluation_payload) do
      log("  #{key}: #{inspect(value)}")
    end

    # The operator's remaining step is a WAIT, not another command. Saying
    # so is the difference between a tool that finished and a tool that
    # looks like it did half a job.
    log(
      "[scope_gate] the gate was NOT passed and GitHub was NOT called — " <>
        "the next reconciler sweep will poll this gate."
    )

    :ok
  end

  # ── Refusal messages ────────────────────────────────────────────────────

  defp message({:unknown_switches, invalid}) do
    "unrecognized option(s) #{inspect(Enum.map(invalid, &elem(&1, 0)))}. " <> usage()
  end

  defp message({:bad_arity, 0}), do: "a validation id is required. " <> usage()

  defp message({:bad_arity, n}),
    do: "expected exactly one validation id, got #{n}. " <> usage()

  defp message({:missing_option, flag}), do: "#{flag} is required. " <> usage()

  defp message({:blank_option, flag}) do
    "#{flag} was supplied but is blank. A blank value is not a fact — the sweeper " <>
      "refuses a blank branch exactly as it refuses an absent one, so writing it " <>
      "would leave the gate hung and look like a repair."
  end

  defp message({:not_live, id, :malformed_id}),
    do: "#{inspect(id)} is not a well-formed validation id."

  defp message({:not_live, id, :not_found}), do: "no validation #{id}."

  defp message({:not_live, id, :not_pr_merged}) do
    "validation #{id} is not a `pr_merged` gate. This command scopes deploy-merge " <>
      "gates only; nothing else is polled by the reconciler."
  end

  defp message({:not_live, id, :not_pending}) do
    "validation #{id} is not pending — it has already been dispositioned. Scoping a " <>
      "settled gate would rewrite the payload behind evidence that has already been " <>
      "read."
  end

  defp message({:not_live, id, :stage_not_running}) do
    "validation #{id} is on a stage that is not running. The reconciler sweeps " <>
      "running stages only, so scoping this gate would not make it pollable."
  end

  defp message({:not_live, id, :superseded_plan}) do
    "validation #{id} is on a superseded plan version — `Tasks.current_plan/1` " <>
      "answers a different plan for its task. The reconciler does not sweep plans " <>
      "nobody is executing."
  end

  defp message({:not_live, id, :not_a_live_candidate}) do
    "validation #{id} is not a live reconciler candidate. `candidates/0` does not " <>
      "yield it and no single condition explains why — inspect the row directly."
  end

  defp message({:branch_already_recorded, id, branch}) do
    "validation #{id} already records branch #{inspect(branch)}. This command repairs " <>
      "a MISSING fact; it does not edit a recorded one. A task that has already pushed " <>
      "under one name is the case where rewriting the name marks unmerged code as " <>
      "shipped. Correct it with a direct `Repo.update` if the recorded value is wrong."
  end

  defp message({:unnormalizable_repo_url, url}) do
    "#{inspect(url)} does not normalize to an `owner/name` slug via " <>
      "`Platform.Tasks.RepoRef.slug/1`. `gate_repo/1` skips a gate with no canonical " <>
      "slug, so writing this would move the hang rather than fix it."
  end

  defp message({:write_failed, id, changeset}),
    do: "could not write the payload onto validation #{id}: #{inspect(changeset.errors)}"

  defp usage do
    "Usage: mix burrow.deploy.scope_gate <validation_id> --repo-url <url> --branch <branch>"
  end

  # ── Logging shim ────────────────────────────────────────────────────────

  # Mirrors `stacks_reprocess_rollup_pr.ex` and
  # `backfill_stack_deploy_cascade.ex`: prefer `Mix.shell().info/1` so
  # `capture_io` sees it, fall back to `Logger` under `bin/platform eval`
  # where Mix is not loaded.
  defp log(msg) do
    if function_exported?(Mix, :shell, 0) do
      Mix.shell().info(msg)
    else
      Logger.info(msg)
    end
  end
end
