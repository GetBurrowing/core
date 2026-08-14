defmodule Platform.Tasks.MergeControl do
  @moduledoc """
  The `Merge` / `Open PR` cluster on the task detail panel: when it may
  render at all, and what the state band above it says.

  ## The problem this exists for

  GitHub reports `mergeable: MERGEABLE` when ZERO checks ran, and that is
  character-for-character what it reports when every check passed. Every
  decision in here keeps those two apart:

    * "no status checks configured" takes `--color-warning`. Never
      success, never neutral grey. Grey reads *not applicable*, green
      reads *verified*; the true statement is "nothing was checked".
    * `--color-error` is reserved for a FAILING check and a REFUSED
      merge. Absence of checks never borrows the colour of failure.
    * the band carries a SENTENCE, not a status word. "No checks" is
      skimmed past; "Nothing has verified this branch" has to be
      disagreed with before it is clicked past.

  All of the state lives in the band. The Merge button holds an
  identical appearance in every state on purpose — a button that changes
  colour teaches people to read the BUTTON for safety, and the button is
  precisely what lies when zero checks ran.

  ## When it renders

  `for_task/1` returns `nil` — no control at all — unless every one of
  these holds:

    * the resolved deploy strategy is `pr_merge`. Any other strategy
      merges somewhere else or not at all.
    * `auto_merge` is FALSE. With it true the auto-merger owns the merge
      and a human button races it.
    * the task is NOT a stack member. A stack ships as ONE rollup PR and
      the stack detail panel already carries its own PR link; a per-member
      Merge button is wrong twice over (ADR 0041).
    * a deploy stage is LIVE (`running`) and carries a `pr_merged` gate
      recording a branch. The branch on that gate is the only recorded
      one — see `Platform.Tasks.DeployStageBuilder.repo_validation/2`.

  ## What it never does

  It never calls `Platform.Tasks.Validation` evaluation from the click.
  The `pr_merged` gate auto-passes on the `pull_request.closed` webhook;
  passing it from the button would pass it on a merge that might not have
  landed. It never disables Merge when checks fail either — the control
  surfaces state, it does not block, and a human overriding a red check
  deliberately is legitimate and is recorded (see `merge/3`).
  """

  alias Platform.Audit
  alias Platform.Tasks
  alias Platform.Tasks.AutoMerger
  alias Platform.Tasks.BranchReconciler
  alias Platform.Tasks.MergeControl.GhRunner
  alias Platform.Tasks.Task, as: TaskRecord

  require Logger

  @default_runner GhRunner
  @default_merger AutoMerger

  @gh_unavailable_sentence "Cannot merge from Suite: the GitHub CLI is unavailable on the server."

  @typedoc """
  The state band above the buttons. `tone` drives the colour token and
  nothing else does.
  """
  @type band :: %{tone: :success | :warning | :error, headline: String.t(), sentence: String.t()}

  @typedoc "Everything the panel needs to render the cluster."
  @type t :: %{
          stage_id: String.t(),
          validation_id: String.t(),
          repo_url: String.t(),
          branch: String.t(),
          base_ref: String.t(),
          merge_method: String.t(),
          pr_number: pos_integer() | nil,
          pr_url: String.t() | nil,
          band: band()
        }

  @doc """
  The configured `Platform.Tasks.MergeControl.Runner`.

  Public so tests can pin the production default without mutating
  application env from an async case — same reason as
  `Platform.Tasks.DeployMergeReconciler.merge_runner/0`.
  """
  @spec runner() :: module()
  def runner do
    :platform
    |> Application.get_env(:merge_control, [])
    |> Keyword.get(:runner, @default_runner)
  end

  @doc """
  The module `merge/3` calls to perform the merge.

  Defaults to `Platform.Tasks.AutoMerger`, whose `execute_merge/4` is the
  SAME entry point the auto-merge webhook path uses: it carries the
  planning-gate refusal and the stack-member deferral. This is a seam for
  observing the call in a test, NOT a second merge implementation — there
  is exactly one, and it lives in `AutoMerger`.
  """
  @spec merger() :: module()
  def merger do
    :platform
    |> Application.get_env(:merge_control, [])
    |> Keyword.get(:merger, @default_merger)
  end

  @doc """
  Build the control for `task`, or `nil` when it must not render.

  Reaches GitHub through `runner/0` for the PR and its check rollup. A
  `gh` failure does not suppress the control: the button stays visible
  and enabled and the band names the cause, because a control that
  silently vanishes is the failure mode this task exists to remove.
  """
  @spec for_task(TaskRecord.t()) :: t() | nil
  def for_task(%TaskRecord{} = task) do
    with true <- eligible_strategy?(task),
         false <- stack_member?(task),
         %{} = gate <- live_pr_merged_gate(task) do
      build(gate)
    else
      _ -> nil
    end
  end

  def for_task(_), do: nil

  @doc """
  Merge the task's branch, attributed to `actor`.

  Resolves the branch's open PR on demand and hands it to
  `merger/0`.`execute_merge/4` — the auto-merge entry point, not a second
  implementation.

  `actor` is `%{id: user_id, org_id: org_id}` or `nil`. Every outcome,
  including a refusal, writes a `platform.tasks.merge_control` audit event
  naming the user, the task, the STAGE and the branch. A Suite-performed
  merge must not be indistinguishable from an auto-merger one, which is
  why the event records `"performed_by" => "merge_control"` — the same
  provenance discipline as `DeployMergeReconciler`'s `"observed_by"`.

  Returns `{:ok, merge_sha}` or `{:error, band}` — the error IS the band,
  so the caller renders the reason rather than inventing one.
  """
  @spec merge(TaskRecord.t(), t(), map() | nil) :: {:ok, String.t()} | {:error, band()}
  def merge(%TaskRecord{} = task, %{} = control, actor) do
    case runner().pr_state(%{repo: control.repo_url, branch: control.branch}) do
      {:ok, %{number: number}} ->
        task
        |> do_merge(control, number, actor)
        |> tap(fn result -> audit(task, control, actor, number, result) end)

      {:ok, nil} ->
        # Reconcile before refusing, so a click on a task whose branch was
        # never pushed under the recorded name gets the mismatch sentence
        # rather than the generic one — and so the audit row records the
        # mismatch headline instead of an ordinary "No open pull request".
        refuse(task, control, actor, no_pr_band(control.repo_url, control.branch))

      {:error, :gh_unavailable, _message} ->
        refuse(task, control, actor, gh_unavailable_band())

      {:error, reason} ->
        refuse(task, control, actor, gh_error_band(reason))
    end
  end

  @doc """
  The band for a resolved PR state. Exposed because it is the single
  definition of the colour rule and is asserted directly.
  """
  @spec band({:ok, map() | nil} | {:error, term()} | {:error, atom(), String.t()}) :: band()
  def band({:ok, %{checks: []}}) do
    %{
      tone: :warning,
      headline: "No status checks configured",
      sentence: "Nothing has verified this branch."
    }
  end

  def band({:ok, %{checks: checks}}) do
    total = length(checks)
    failing = Enum.count(checks, &(not &1.passed?))

    if failing == 0 do
      %{
        tone: :success,
        headline: "#{total} #{pluralize(total)} passed",
        sentence: "Every configured check on this branch has passed."
      }
    else
      %{
        tone: :error,
        headline: "#{failing} of #{total} #{pluralize(total)} failing",
        sentence: "This branch has failing checks. Merging anyway is recorded against you."
      }
    end
  end

  def band({:ok, nil}), do: no_open_pr_band()
  def band({:error, :gh_unavailable, _message}), do: gh_unavailable_band()
  def band({:error, reason}), do: gh_error_band(reason)

  # ── Internals ───────────────────────────────────────────────────────────

  defp build(gate) do
    payload = gate.validation.evaluation_payload
    repo_url = payload["repo_url"]
    branch = payload["branch"]

    pr_state = runner().pr_state(%{repo: repo_url, branch: branch})

    pr =
      case pr_state do
        {:ok, %{} = pr} -> pr
        _ -> nil
      end

    %{
      stage_id: gate.stage.id,
      validation_id: gate.validation.id,
      repo_url: repo_url,
      branch: branch,
      base_ref: (pr && pr.base_ref) || "main",
      merge_method: payload["merge_method"] || "squash",
      pr_number: pr && pr.number,
      pr_url: pr && pr.url,
      band: render_band(pr_state, repo_url, branch)
    }
  end

  # `band/1` stays the pure colour rule and is asserted directly. Only the
  # `{:ok, nil}` state needs the repository context, because it is the only
  # one whose sentence is ambiguous between a wrong state and an ordinary
  # one.
  defp render_band({:ok, nil}, repo_url, branch), do: no_pr_band(repo_url, branch)
  defp render_band(pr_state, _repo_url, _branch), do: band(pr_state)

  # `:match` and `:unknown` are byte-for-byte today's behaviour. A probe
  # that could not run is NEVER reported as a mismatch.
  defp no_pr_band(repo_url, branch) do
    case BranchReconciler.reconcile(repo_url, branch) do
      {:mismatch, [found | _]} -> branch_mismatch_band(branch, found)
      _ -> no_open_pr_band()
    end
  end

  defp branch_mismatch_band(recorded, found) do
    %{
      tone: :error,
      headline: "Recorded branch not found",
      sentence: "Expected `#{recorded}`, found `#{found}` on the remote."
    }
  end

  defp do_merge(task, control, number, _actor) do
    case merger().execute_merge(task, control.repo_url, number, control.merge_method) do
      {:ok, :deferred} ->
        {:error, deferred_band()}

      {:ok, sha} ->
        {:ok, sha}

      {:error, :gh_unavailable, _message} ->
        {:error, gh_unavailable_band()}

      {:error, type, detail} ->
        {:error, refused_band(type, detail)}
    end
  end

  defp refuse(task, control, actor, band) do
    audit(task, control, actor, nil, {:error, band})
    {:error, band}
  end

  # The audit row is the attribution. `performed_by: "merge_control"`
  # separates a Suite-performed merge from an auto-merger one; without it
  # the two are one undifferentiated merge in the trail.
  defp audit(task, control, actor, pr_number, result) do
    {outcome, detail} =
      case result do
        {:ok, sha} -> {"merged", sha}
        {:error, %{headline: headline}} -> {"refused", headline}
      end

    Audit.record(%{
      event_type: "platform.tasks.merge_control",
      action: outcome,
      actor_type: if(actor && actor[:id], do: "user", else: "system"),
      actor_id: actor && actor[:id],
      actor_org_id: actor && actor[:org_id],
      resource_type: "task",
      resource_id: task.id,
      metadata: %{
        "performed_by" => "merge_control",
        "stage_id" => control.stage_id,
        "branch" => control.branch,
        "repo_url" => control.repo_url,
        "pr_number" => pr_number,
        "merge_method" => control.merge_method,
        "detail" => detail
      }
    })
  end

  defp eligible_strategy?(%TaskRecord{} = task) do
    strategy = Tasks.resolve_deploy_strategy(task)

    match?(%{"type" => "pr_merge"}, strategy) and not AutoMerger.should_auto_merge?(strategy)
  end

  # `stack_id` and not `Tasks.resolve_deploy_strategy/1`'s rollup check:
  # a stack member with no rollup branch YET still must not get a
  # per-member Merge button, because the rollup is what will ship it.
  defp stack_member?(%TaskRecord{stack_id: stack_id}), do: not is_nil(stack_id)

  defp live_pr_merged_gate(%TaskRecord{plans: plans}) when is_list(plans) do
    plans
    |> Enum.flat_map(fn plan -> plan_stages(plan) end)
    |> Enum.filter(&(&1.status == "running"))
    |> Enum.find_value(fn stage ->
      case Enum.find(stage_validations(stage), &recorded_pr_merged_gate?/1) do
        nil -> nil
        validation -> %{stage: stage, validation: validation}
      end
    end)
  end

  defp live_pr_merged_gate(_), do: nil

  defp plan_stages(%{stages: stages}) when is_list(stages), do: stages
  defp plan_stages(_), do: []

  defp stage_validations(%{validations: validations}) when is_list(validations), do: validations
  defp stage_validations(_), do: []

  defp recorded_pr_merged_gate?(%{kind: "pr_merged", evaluation_payload: %{} = payload}) do
    present?(payload["branch"]) and present?(payload["repo_url"])
  end

  defp recorded_pr_merged_gate?(_), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  defp pluralize(1), do: "check"
  defp pluralize(_), do: "checks"

  defp no_open_pr_band do
    %{
      tone: :warning,
      headline: "No open pull request",
      sentence: "This branch has no open pull request to merge."
    }
  end

  defp gh_unavailable_band do
    %{
      tone: :error,
      headline: "Merge unavailable",
      sentence: @gh_unavailable_sentence
    }
  end

  defp gh_error_band(reason) do
    Logger.warning("[merge_control] gh call failed: #{inspect(reason)}")

    %{
      tone: :error,
      headline: "GitHub could not be reached",
      sentence: "Suite could not ask GitHub about this branch."
    }
  end

  defp deferred_band do
    %{
      tone: :warning,
      headline: "Merge deferred",
      sentence: "This task ships through a stack rollup, so its branch is not merged on its own."
    }
  end

  defp refused_band(type, detail) do
    %{
      tone: :error,
      headline: "Merge refused: #{type}",
      sentence: String.slice(to_string(detail), 0, 300)
    }
  end
end
