defmodule Platform.Tasks.DeployStageBuilder do
  @moduledoc """
  Builds deploy stage definitions from a resolved deploy strategy.

  Converts a strategy map (e.g. `%{"type" => "pr_merge", "config" => %{...}}`)
  into a stage definition suitable for insertion by PlanEngine as the final
  stage of a plan.

  ## CI & Merge Validations

  For `pr_merge` strategy, the builder emits ONE `pr_merged` validation
  PER REPOSITORY in the strategy's resolved repo set (`strategy["repos"]`,
  written by `Platform.Tasks.resolve_deploy_strategy_with_repos/1`), each
  carrying that repository's identity in `evaluation_payload`:

      %{kind: "pr_merged",
        evaluation_payload: %{
          "repo" => "Startup-Suite/core",   # canonical slug, or nil
          "repo_url" => "https://github.com/Startup-Suite/core",
          "branch" => "task/019fba18-d074-7185-8e0e-032ee6d02fbe",
          "branch_tip_sha" => "9fcec268…" | nil,
          "ci" => "required" | "none",
          "auto_merge" => boolean(),
          "merge_method" => "squash" | "merge" | "rebase"
        }}

  ## `"branch"` — recorded, not derived

  The gate records the branch this task pushes, supplied by the caller
  (`PlanEngine`, from `StackDeployer.member_branch_for/1`) as the REQUIRED
  third argument to `build_stage/4`. Every scoped gate on one stage carries
  the SAME value — one branch, N repositories.

  It is recorded rather than re-derived downstream because the derivation is
  not an identifier. `HeartbeatScheduler.member_slug/1` answers the first
  hyphen-segment of the task uuid for a non-stack task, and a UUIDv7's first
  eight hex characters are the high 32 bits of its 48-bit millisecond
  timestamp — a ~65-second bucket. Measured 2026-07-31: tasks
  `019fb90f-36e3-…` and `019fb90f-6226-…` BOTH derive `task/019fb90f`, and
  `task/019fb90f` carries merged PR #648. A consumer that derives can
  therefore close one task's deploy gate on another task's merge, and neither
  GitHub nor `gh pr list --head` can see the collision because the ambiguity
  is Suite-side. `StackDeployer` already paid for this once
  (`stack_deployer.ex:1163-1193`: `fatal: couldn't find remote ref
  task/019f9b27`, four ADR-0046 members collapsing to `task/019f9b28`).

  The third argument is REQUIRED and positional, not an optional keyword: an
  optional one lets a future call site silently mint a gate with no recorded
  branch, and that failure is invisible until a deploy hangs. A required one
  makes the omission a compile error.

  The unscoped fallback gate (no declared repo set) deliberately keeps its
  ABSENT payload — see the comment on that clause.

  `pr_merged` therefore stops meaning "a PR merged somewhere" and starts
  meaning "the PR for THIS repository merged". Each gate is auto-evaluated
  by the GitHub `pull_request.closed` webhook; on a `ci: "required"` repo
  CI is implied because branch protection (and auto-merge wait-for-CI)
  prevent a merge before checks pass, and whether a human or the
  AutoMerger performs the merge, the gate is satisfied the same way.

  N gates need no engine change to mean all-must-merge:
  `PlanEngine.stage_verdict/1` already requires
  `Enum.all?(validations, &(&1.status == "passed"))`. They also make the
  PARTIAL state a row you can look at — one `passed`, one `pending` —
  rather than a counter inside a single gate that is neither passed nor
  failed.

  When `"repos"` is ABSENT the builder emits exactly one unscoped
  `%{kind: "pr_merged"}` with no payload, which is the pre-multi-repo
  behavior every existing caller and every existing plan relies on.

  For `docker_deploy` strategy:
  - `ci_passed` — auto-evaluated by webhook
  - `test_pass` — deploy health check (agent evaluates)

  For `fly` strategy:
  - Same as `docker_deploy`

  ## Note on `e2e_behavior`

  `e2e_behavior` validations are *task-level* (not produced by deploy strategies).
  They are authored by the planning agent and routed to a synthetic task-level
  review stage by `PlanEngine` during plan ingestion — this builder only emits
  deterministic deploy-time validations (`pr_merged`, `ci_passed`, `test_pass`,
  `manual_approval`). Do NOT add `e2e_behavior` to any deploy-stage definition.
  """

  alias Platform.Tasks.RepoRef

  @valid_strategy_types ~w(none pr_merge docker_deploy fly skill_driven manual project_files no_op_wait_for_rollup)
  @valid_merge_methods ~w(squash merge rebase)

  # A `pr_merge` repo entry's `"ci"` is a THREE-STATE fact once you read it
  # together with `config["require_ci_pass"]`:
  #
  #   * `ci: "required"` + `require_ci_pass: true`  — there is CI and we gate on it.
  #   * `ci: "required"` + `require_ci_pass: false` — there IS CI and we choose not to gate.
  #   * `ci: "none"`                                — there is NO CI to gate on.
  #
  # The last two MUST NEVER COLLAPSE INTO ONE VALUE, for the same reason
  # `Task.planning_step_outcomes` keeps `not_applicable` and `failed` apart:
  # a gate that never ran must not become indistinguishable from a gate
  # that ran and passed. On a repo with zero required checks, GitHub
  # reports `mergeStateStatus: CLEAN` — which means "nothing blocks the
  # merge", NOT "checks passed". `auto_merge` there is a fiction, and
  # `validate_strategy/1` refuses to store it.
  @valid_repo_ci_states ~w(required none)

  # Every stage this module mints is named `"Deploy: <something>"`. That prefix
  # is the ONLY reliable marker that a stage is a system-injected deploy stage:
  # planners are explicitly forbidden from authoring deploy stages
  # (`dispatch.planning` — "the system auto-injects it"), so nothing else
  # produces a name in this shape. `PlanEngine.maybe_inject_deploy_or_complete/2`
  # already keys off it; `Platform.Orchestration.DispatchPhase` needs the same
  # fact and must not re-spell it.
  @deploy_stage_name_prefix "Deploy: "

  # ── Public API ─────────────────────────────────────────────────────────

  @doc """
  The name prefix every stage built by `build_stage/4` carries.
  """
  @spec deploy_stage_name_prefix() :: String.t()
  def deploy_stage_name_prefix, do: @deploy_stage_name_prefix

  @doc """
  Whether `name` is a stage name minted by `build_stage/4`.

  Deliberately an EXACT, case-sensitive prefix match — not a substring search.
  `TaskRouter.infer_stage_type/1` does the substring thing on the same field
  and misclassifies any human-authored stage whose name merely mentions
  deploying (e.g. "Rework the deploy strategy resolver"). Do not soften this.
  """
  @spec deploy_stage_name?(String.t() | nil) :: boolean()
  def deploy_stage_name?(name) when is_binary(name),
    do: String.starts_with?(name, @deploy_stage_name_prefix)

  def deploy_stage_name?(_), do: false

  @doc """
  Build a deploy stage definition from a resolved strategy map.

  `branch` is the branch this task pushes — `StackDeployer.member_branch_for/1`
  at both `PlanEngine` call sites. It is recorded onto every repo-scoped
  `pr_merged` gate's `evaluation_payload` so consumers READ it instead of
  re-deriving a name that is a UUIDv7 time bucket rather than an identifier;
  see the moduledoc. Required, so a call site cannot omit it silently.

  `branch_tip_shas` is `%{canonical_slug => sha}` — the tip each repository's
  copy of `branch` stood at when this stage was minted, resolved by the
  caller (`PlanEngine`, via `BranchProvisioner.branch_tip_shas/3`) so the
  builder still touches no `Repo` and makes no network call.

  It DEFAULTS to `%{}`, unlike `branch`, and the asymmetry is deliberate.
  Omitting `branch` makes a consumer DERIVE one, and a derived branch name
  attributes a merge to the wrong branch — strictly worse than no
  attribution. Omitting a tip attributes nothing: the gate falls back to the
  merge-ordering check alone, which is exactly what every gate minted before
  this key existed does. The safe direction is a default; the unsafe one is
  not.

  Returns a map with `:name`, `:description`, `:position`, and `:validations`,
  or `:skip` if the strategy type is `"none"` or `"no_op_wait_for_rollup"`
  (bug #5 — stack members ship via the stack-level rollup PR, not a
  per-member deploy stage).

  ## Examples

      iex> DeployStageBuilder.build_stage(%{"type" => "pr_merge", "config" => %{"require_ci_pass" => true}}, 3, "task/019fba18-d074-7185-8e0e-032ee6d02fbe")
      %{name: "Deploy: PR merge", description: "...", position: 3, validations: [...]}

      iex> DeployStageBuilder.build_stage(%{"type" => "none"}, 3, "task/019fba18-d074-7185-8e0e-032ee6d02fbe")
      :skip

      iex> DeployStageBuilder.build_stage(%{"type" => "no_op_wait_for_rollup"}, 3, "task/019fba18-d074-7185-8e0e-032ee6d02fbe")
      :skip
  """
  @spec build_stage(map(), pos_integer(), String.t(), %{String.t() => String.t()}) ::
          map() | :skip
  def build_stage(strategy, position, branch, branch_tip_shas \\ %{})

  def build_stage(%{"type" => "none"}, _position, _branch, _tips), do: :skip

  # Bug #5 (task 019f708f): stack members with a live rollup branch
  # get `no_op_wait_for_rollup` from `Tasks.resolve_deploy_strategy/1`.
  # Emit NO deploy stage at all — the stack sweep opens ONE rollup PR
  # via `StackDeployer.maybe_open_stack_pr/1`, so a per-member stage
  # would either open a shattering PR (if we materialized `pr_merge`)
  # or dispatch a deploy subagent that has nothing to do (if we
  # materialized a stage_complete-only stage). Skipping is safer.
  def build_stage(%{"type" => "no_op_wait_for_rollup"}, _position, _branch, _tips), do: :skip

  def build_stage(%{"type" => "pr_merge"} = strategy, position, branch, tips) do
    config = Map.get(strategy, "config", %{})

    case Map.get(strategy, "repos") do
      repos when is_list(repos) and repos != [] ->
        entries = Enum.map(repos, &repo_gate(&1, config))

        %{
          name: "Deploy: PR merge",
          description: pr_merge_description(config, entries),
          position: position,
          validations: Enum.map(entries, &repo_validation(&1, branch, tips))
        }

      # No declared repo set. `Tasks.resolve_deploy_strategy_with_repos/1`
      # leaves `"repos"` ABSENT (never `[]`) when the set resolves empty,
      # exactly so "nothing was declared" keeps meaning what it means
      # today: ONE unscoped gate, auto-evaluated by the GitHub
      # pull_request.closed webhook, CI implied via branch protection /
      # auto-merge wait-for-CI.
      #
      # `[]` lands here too, deliberately. Read literally it would mean
      # "one gate per repo, of which there are none" — a deploy stage with
      # ZERO validations, and `PlanEngine.stage_verdict/1` answers
      # `:all_passed` for `[]`. That stage would advance the instant it was
      # injected, reporting a deploy nobody performed. The resolver already
      # refuses to write `[]`; this refuses to build a stage from one.
      #
      # `branch` is deliberately NOT recorded here. This gate keeps its
      # ABSENT payload: `DeployMergeReconciler.gate_repo/1`'s nil-payload
      # clause skips exactly these rows, and
      # `GithubWebhookController.select_unscoped_validation/3` owns the rules
      # for when one may pass. Giving it a payload would move it out of that
      # clause — a routing change dressed up as a field addition.
      _ ->
        %{
          name: "Deploy: PR merge",
          description: pr_merge_description(config),
          position: position,
          validations: [%{kind: "pr_merged"}]
        }
    end
  end

  def build_stage(%{"type" => "docker_deploy"} = strategy, position, _branch, _tips) do
    config = Map.get(strategy, "config", %{})

    %{
      name: "Deploy: Docker deploy",
      description: docker_deploy_description(config),
      position: position,
      validations: [%{kind: "ci_passed"}, %{kind: "test_pass"}]
    }
  end

  def build_stage(%{"type" => "fly"} = strategy, position, _branch, _tips) do
    config = Map.get(strategy, "config", %{})

    %{
      name: "Deploy: Fly deploy",
      description: fly_description(config),
      position: position,
      validations: [%{kind: "ci_passed"}, %{kind: "test_pass"}]
    }
  end

  def build_stage(%{"type" => "skill_driven"} = strategy, position, _branch, _tips) do
    config = Map.get(strategy, "config", %{})
    skill_id = Map.get(strategy, "skill_id")

    %{
      name: "Deploy: Skill execution",
      description: skill_driven_description(config, skill_id),
      position: position,
      validations: [%{kind: "manual_approval"}]
    }
  end

  def build_stage(%{"type" => "manual"} = _strategy, position, _branch, _tips) do
    %{
      name: "Deploy: Manual",
      description:
        "Manual deployment required. A human or agent should perform the deploy " <>
          "and confirm completion via manual approval.",
      position: position,
      validations: [%{kind: "manual_approval"}]
    }
  end

  def build_stage(%{"type" => "project_files"} = strategy, position, _branch, _tips) do
    config = Map.get(strategy, "config", %{})

    # `test_pass` is the canonical success/failure signal for auto-invoked
    # deploy handlers (mirrors `docker_deploy`). Stage 4 wires the actual
    # `Platform.Deploy.ProjectFiles` handler; this stage only registers the
    # strategy so the plan engine can build the stage definition.
    %{
      name: "Deploy: Project files",
      description: project_files_description(config),
      position: position,
      validations: [%{kind: "test_pass"}]
    }
  end

  # ── Strategy Validation ────────────────────────────────────────────────

  @doc """
  Validate a deploy strategy map shape.

  Returns `:ok` if the strategy is valid, or `{:error, reason}` if not.
  Used by `Project.changeset/2` to validate `deploy_config["default_strategy"]`.

  ## Valid shapes

      %{"type" => "pr_merge", "config" => %{"auto_merge" => bool, "merge_method" => "squash"|"merge"|"rebase", ...}}
      %{"type" => "docker_deploy", "config" => %{"host" => str, "image" => str, ...}}
      %{"type" => "fly", "config" => %{"app" => str, ...}}
      %{"type" => "skill_driven", "skill_id" => str, "config" => %{...}}
      %{"type" => "manual"}
      %{"type" => "none"}
      %{"type" => "no_op_wait_for_rollup"}  # stack member — deploy goes via stack-level PR

  ## Multi-repo `pr_merge`

  A `pr_merge` strategy MAY declare the repository set the task actually
  lands in, which is otherwise unknowable — a task carries a `project_id`
  and the project carries exactly one `repo_url`:

      %{"type" => "pr_merge",
        "config" => %{"auto_merge" => false},
        "repos" => [
          %{"repo_url" => "https://github.com/Startup-Suite/core", "ci" => "required"},
          %{"repo_url" => "Startup-Suite/claude-code-suite-channel", "ci" => "none"}
        ]}

  Each entry's own `"config"` overrides the strategy-level `"config"`.
  Validation refuses the config that is a FICTION rather than refusing
  the task: `auto_merge: true` (or `require_ci_pass: true`) on an entry
  with `ci: "none"` is rejected here, naming the repository, because on a
  repo with zero required checks there is nothing for auto-merge to wait
  for.
  """
  @spec validate_strategy(map()) :: :ok | {:error, String.t()}
  def validate_strategy(%{"type" => "pr_merge"} = strategy) do
    validate_repos(strategy)
  end

  def validate_strategy(%{"type" => type}) when type in @valid_strategy_types do
    :ok
  end

  def validate_strategy(%{"type" => type}) do
    {:error,
     "unknown strategy type: #{type}. Valid types: #{Enum.join(@valid_strategy_types, ", ")}"}
  end

  def validate_strategy(_), do: {:error, "strategy must have a \"type\" key"}

  @doc """
  Validate the merge method value.
  """
  @spec valid_merge_method?(String.t()) :: boolean()
  def valid_merge_method?(method), do: method in @valid_merge_methods

  @doc "List valid strategy types."
  @spec valid_strategy_types() :: [String.t()]
  def valid_strategy_types, do: @valid_strategy_types

  @doc "List valid per-repo `\"ci\"` states."
  @spec valid_repo_ci_states() :: [String.t()]
  def valid_repo_ci_states, do: @valid_repo_ci_states

  # ── `pr_merge` repo-set validation ─────────────────────────────────────

  defp validate_repos(strategy) do
    case Map.get(strategy, "repos") do
      # No declared repo set — single-repo task, resolved from
      # `project.repo_url`. Unchanged from before multi-repo existed.
      nil ->
        :ok

      [] ->
        {:error,
         "repos, when present, must be a non-empty list of repository maps " <>
           "(omit the key entirely for a single-repo task)"}

      repos when is_list(repos) ->
        strategy_config = Map.get(strategy, "config", %{})

        repos
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {entry, index}, :ok ->
          case validate_repo_entry(entry, index, strategy_config) do
            :ok -> {:cont, :ok}
            {:error, _} = error -> {:halt, error}
          end
        end)

      _other ->
        {:error, "repos must be a list of repository maps"}
    end
  end

  defp validate_repo_entry(entry, index, strategy_config) when is_map(entry) do
    with {:ok, slug} <- validate_repo_url(entry, index),
         {:ok, ci} <- validate_repo_ci(entry, slug) do
      validate_repo_ci_expressibility(entry, slug, ci, strategy_config)
    end
  end

  defp validate_repo_entry(_entry, index, _strategy_config) do
    {:error, "repos[#{index}] must be a map with a \"repo_url\" key"}
  end

  defp validate_repo_url(entry, index) do
    repo_url = Map.get(entry, "repo_url")

    case RepoRef.normalize(repo_url) do
      {:ok, slug} ->
        {:ok, slug}

      :error ->
        {:error,
         "repos[#{index}].repo_url is not a recognizable GitHub repository: " <>
           inspect(repo_url)}
    end
  end

  defp validate_repo_ci(entry, slug) do
    case Map.get(entry, "ci", "required") do
      ci when ci in @valid_repo_ci_states ->
        {:ok, ci}

      other ->
        {:error,
         "repos entry for #{slug} has invalid ci #{inspect(other)} " <>
           "(allowed: #{Enum.join(@valid_repo_ci_states, ", ")})"}
    end
  end

  # The honest refusal. `ci: "none"` means the repository has no required
  # checks at all, so a CLEAN merge state reports "nothing blocks the
  # merge", not "checks passed". Storing `auto_merge: true` against that
  # would record a CI gate that cannot exist — the same
  # partial-recorded-as-complete conflation this system keeps paying for.
  defp validate_repo_ci_expressibility(_entry, _slug, "required", _strategy_config), do: :ok

  defp validate_repo_ci_expressibility(entry, slug, "none", strategy_config) do
    config = Map.merge(strategy_config, Map.get(entry, "config", %{}))

    cond do
      Map.get(config, "auto_merge") == true ->
        {:error, ci_none_error("auto_merge", slug)}

      Map.get(config, "require_ci_pass") == true ->
        {:error, ci_none_error("require_ci_pass", slug)}

      true ->
        :ok
    end
  end

  defp ci_none_error(key, slug) do
    "#{key} is not expressible for #{slug}: ci is \"none\" (no required checks), " <>
      "so a CLEAN mergeStateStatus means zero checks ran, not checks passed. " <>
      "Set #{key}: false for this repo and merge it by hand."
  end

  # ── Private helpers ────────────────────────────────────────────────────

  # ── One `pr_merged` gate per resolved repository ────────────────────────
  #
  # `PlanEngine.stage_verdict/1` already requires EVERY validation on a
  # stage to be `passed` before `advance_stage/1` moves the stage on, so N
  # gates gives all-must-merge semantics with no engine change. The reason
  # to prefer N rows over one row carrying a counter is not economy: N rows
  # make the PARTIAL state a thing you can LOOK at — one `passed`, one
  # `pending` — where a counter renders as a single gate that is neither
  # passed nor failed, which is the very conflation this task exists to
  # remove.
  #
  # Accepts BOTH shapes an entry arrives in: the normalized map
  # `Tasks.resolve_deploy_strategy_with_repos/1` writes back (carrying
  # `"slug"`, `"role"`, and an already-merged `"config"`) and the raw
  # declared map a human writes into `task.deploy_strategy` (carrying
  # `"repo_url"` and maybe `"ci"` / `"config"`). Re-merging the
  # strategy-level config into an already-merged one is idempotent, and
  # re-deriving an absent slug goes through `RepoRef` — the one canonical
  # normalizer — rather than a second spelling of it.
  defp repo_gate(entry, strategy_config) when is_map(entry) do
    repo_url = Map.get(entry, "repo_url")
    config = Map.merge(strategy_config, Map.get(entry, "config", %{}))
    ci = if Map.get(entry, "ci", "required") == "none", do: "none", else: "required"

    %{
      # A declared entry whose `repo_url` will not normalize keeps its
      # gate, with a nil slug — see `Tasks.resolve_deploy_repos/1`. The gate
      # can never be matched by a webhook, so the task HANGS, which is
      # visible and fixable. Dropping the entry instead would shrink the
      # repo set back to the defect this feature exists to fix: a task
      # reporting a success it did not earn.
      slug: Map.get(entry, "slug") || RepoRef.slug(repo_url),
      repo_url: if(is_binary(repo_url), do: repo_url, else: ""),
      ci: ci,
      # `auto_merge` is not expressible on a repo with zero required
      # checks — there is nothing for it to wait for.
      # `validate_strategy/1` refuses to STORE that combination, but a raw
      # write can still produce it, and the gate must not record a CI wait
      # that cannot happen.
      auto_merge: ci == "required" and Map.get(config, "auto_merge", false) == true,
      merge_method: Map.get(config, "merge_method", "squash")
    }
  end

  defp repo_gate(other, strategy_config),
    do: repo_gate(%{"repo_url" => other}, strategy_config)

  # `branch` is the same value for every gate on one stage — the task pushes
  # ONE branch and opens a PR from it in each repository. Recorded per-gate
  # rather than once per stage because the row the consumer reads is the
  # VALIDATION: `DeployMergeReconciler.candidates/0` selects validations and
  # `gate_repo/1` reads `evaluation_payload`. A stage-level home would need a
  # second lookup on a table the sweeper does not otherwise touch.
  # ## `"branch_tip_sha"` — WHICH TREE the gate was minted for
  #
  # `"branch"` says which branch to watch. It does not say which WORK, and
  # `gh pr list --head` looks backwards over all time, so a branch that
  # already shipped answers every later poll with the same historical merge.
  # Stage 1 of task 01a06d6d narrowed that with an ordering check — the merge
  # must postdate the stage — but ordering is a proxy: a force-push followed
  # by a PR merging seconds after the stage opens satisfies it and still ships
  # a tree nobody reviewed.
  #
  # This records the sha the branch stood at WHEN THE GATE WAS MINTED, which
  # is the commit the review stages passed on. `DeployMergeReconciler.poll/7`
  # requires it to equal the merged PR's `headRefOid`. That equality is the
  # discriminator, and it is deliberately NOT a git ancestry test: main
  # squash-merges here, so `merge-base --is-ancestor <branch tip> main` is
  # false even for a branch that shipped correctly, while the same test
  # against the cited merge commit is true for any commit that ever merged —
  # including the stale PR that caused this ticket. Both directions lie, in
  # opposite directions. Comparing two branch tips asks git nothing.
  #
  # Per-repo lookup, from a map keyed by canonical slug: one branch NAME
  # lands in N repositories as N unrelated refs with N unrelated tips (see
  # `BranchProvisioner.branch_tip_shas/3`). A stage-wide sha would match one
  # repository and hang the others.
  #
  # `nil` is written, not omitted, when the tip could not be resolved — a
  # `gh` that flaked, a branch nobody pushed yet, a repository we cannot
  # read. The reconciler treats nil and absent identically (fall through to
  # the ordering check), so this is a record of "we looked and got nothing"
  # rather than a second meaning; the key's presence keeps a minted-today
  # gate distinguishable from a genuinely legacy one at a glance.
  defp repo_validation(gate, branch, tips) do
    %{
      kind: "pr_merged",
      evaluation_payload: %{
        "repo" => gate.slug,
        "repo_url" => gate.repo_url,
        "branch" => branch,
        "branch_tip_sha" => Map.get(tips, gate.slug),
        "ci" => gate.ci,
        "auto_merge" => gate.auto_merge,
        "merge_method" => gate.merge_method
      }
    }
  end

  # ONE repository is one repository however the set was arrived at. Since
  # `PlanEngine` resolves through `Tasks.resolve_deploy_strategy_with_repos/1`,
  # every ordinary task — one that declares no repo set at all — now arrives
  # here carrying a one-entry `"repos"` list synthesized from
  # `project.repo_url`. Without this clause the enumerating renderer below
  # would be the only one anything reaches, and the single-repo wording would
  # render solely for repo-LESS projects: a behavioural change for the 99%
  # case, which the plan for this work forbids.
  #
  # It is also just worse text. "This deploy covers 1 repository" and "one
  # merged PR out of 1 is a partial deploy" describe a plural situation that
  # is not happening; the per-repo breakdown restates what the single-repo
  # paragraph already said, at greater length.
  #
  # Must precede the general clause — pattern matching is ordered.
  defp pr_merge_description(config, [_single]), do: pr_merge_description(config)

  defp pr_merge_description(config, entries) do
    require_review = Map.get(config, "require_review_approval", false)
    count = length(entries)

    parts =
      [
        "Deploy via PR merge flow.",
        "Push the task branch and open a PR against the default branch of every " <>
          "repository this task lands in.",
        "This deploy covers #{count} #{pluralize_repo(count)}: #{repo_list(entries)}.",
        "One pr_merged validation is tracked per repository (auto-evaluated by the " <>
          "GitHub pull_request.closed webhook). The stage completes only when EVERY " <>
          "one of them has merged — one merged PR out of #{count} is a partial deploy " <>
          "and is reported as such: one gate passed, the rest still pending.",
        if(require_review,
          do: "PR review approval is required.",
          else: "PR review approval is not required."
        )
      ] ++ Enum.map(entries, &repo_sentence/1)

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp pluralize_repo(1), do: "repository"
  defp pluralize_repo(_), do: "repositories"

  defp repo_list(entries), do: entries |> Enum.map(&repo_label/1) |> Enum.join(", ")

  defp repo_label(%{slug: slug}) when is_binary(slug), do: slug
  defp repo_label(%{repo_url: ""}), do: "<unnamed repository>"
  defp repo_label(%{repo_url: repo_url}), do: repo_url

  # The unresolvable case, said out loud in the dispatch text the deployer
  # reads. A gate whose repo identity is nil cannot be satisfied by any
  # webhook; the task will sit in `deploying` until a human fixes the
  # declaration. That is the intended failure — but it must not be a
  # silent one.
  defp repo_sentence(%{slug: nil} = gate) do
    "#{repo_label(gate)} did not resolve to a GitHub owner/name — its pr_merged gate " <>
      "cannot be matched by any webhook and this deploy will not complete until the " <>
      "repository declaration is corrected."
  end

  # `ci: "none"` is NOT `require_ci_pass: false`. It means the repository
  # has no required checks at all, so GitHub reports `mergeStateStatus:
  # CLEAN` — "nothing blocks the merge", not "checks passed". Verified on
  # both bridge repos: neither has a GitHub webhook or a protected `main`.
  defp repo_sentence(%{ci: "none"} = gate) do
    "#{repo_label(gate)} has no required status checks — a CLEAN merge state means " <>
      "zero checks ran, not checks passed. This repo is merged by hand; a human must " <>
      "look at it."
  end

  defp repo_sentence(%{auto_merge: true} = gate) do
    "#{repo_label(gate)}: CI is required and enforced by branch protection; auto-merge " <>
      "is enabled (merge method: #{gate.merge_method})."
  end

  defp repo_sentence(gate) do
    "#{repo_label(gate)}: CI is required and enforced by branch protection; auto-merge " <>
      "is disabled — a human merges the PR via GitHub."
  end

  defp pr_merge_description(config) do
    auto_merge = Map.get(config, "auto_merge", false)
    require_review = Map.get(config, "require_review_approval", false)
    merge_method = Map.get(config, "merge_method", "squash")

    parts = [
      "Deploy via PR merge flow.",
      "Push the task branch and open a PR against the default branch.",
      "Stage completes when the PR is merged " <>
        "(pr_merged validation, auto-evaluated by the GitHub pull_request.closed webhook).",
      "CI is enforced by GitHub branch protection / auto-merge wait-for-CI " <>
        "before the merge is allowed; no separate CI gate is tracked here.",
      if(require_review,
        do: "PR review approval is required.",
        else: "PR review approval is not required."
      ),
      if(auto_merge,
        do:
          "Auto-merge is enabled — PR will be merged automatically when CI passes " <>
            "(merge method: #{merge_method}).",
        else: "Auto-merge is disabled — a human merges the PR via GitHub."
      )
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp docker_deploy_description(config) do
    parts = [
      "Deploy via Docker.",
      "CI must pass (ci_passed validation, auto-evaluated by webhook).",
      "Execute the deployment (pull image, compose up, health check).",
      "test_pass validation covers deploy execution and health check."
    ]

    host = Map.get(config, "host")
    image = Map.get(config, "image")

    extra = [
      if(host, do: "Target host: #{host}.", else: nil),
      if(image, do: "Image: #{image}.", else: nil)
    ]

    (parts ++ extra) |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp fly_description(config) do
    app = Map.get(config, "app")

    parts = [
      "Deploy via Fly.io.",
      "CI must pass (ci_passed validation, auto-evaluated by webhook).",
      "Execute fly deploy and verify health check.",
      "test_pass validation covers deploy execution and health check.",
      if(app, do: "Fly app: #{app}.", else: nil)
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp project_files_description(config) do
    project_id = Map.get(config, "project_id")
    folder = Map.get(config, "folder", "Deliverables")
    deliverable_canvas_id = Map.get(config, "deliverable_canvas_id")

    parts = [
      "Deploy the task's deliverable into a project's Files module.",
      "The platform auto-executes the deploy — do NOT push evidence manually.",
      "Deliverable is exported to Markdown from the deliverable canvas and written into the target project's Files.",
      "test_pass is passed by the auto-invoked deploy handler on success (or failed with a reason).",
      if(project_id, do: "Target project ID: #{project_id}.", else: nil),
      "Target folder: #{folder}.",
      if(deliverable_canvas_id,
        do: "Deliverable canvas ID: #{deliverable_canvas_id}.",
        else:
          "No explicit deliverable canvas — the handler falls back to the newest canvas in the task's execution space."
      )
    ]

    parts |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end

  defp skill_driven_description(config, skill_id) do
    parts = [
      "Deploy via skill execution.",
      if(skill_id, do: "Skill ID: #{skill_id}.", else: "No skill ID specified."),
      "The attached skill defines the deploy procedure.",
      "manual_approval confirms successful execution."
    ]

    extra_context = Map.get(config, "context")

    extra = [
      if(extra_context, do: "Additional context: #{extra_context}", else: nil)
    ]

    (parts ++ extra) |> Enum.reject(&is_nil/1) |> Enum.join(" ")
  end
end
