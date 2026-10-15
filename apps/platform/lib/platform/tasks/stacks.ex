defmodule Platform.Tasks.Stacks do
  @moduledoc """
  Persistent context for the Task Stacks domain (ADR 0041).

  Task stacks group co-related tasks that ship together as a single rollup PR.
  Members of a stack reuse the existing `tasks.dependencies` machinery to
  govern in-stack execution order, so members with no inter-dependency can
  be implemented in parallel.

  This module exposes the lifecycle surface for stacks themselves; member
  attachment, DAG validation, dispatch helpers, and rollup-status
  recomputation land in subsequent T2 stages.
  """

  import Ecto.Query

  require Logger

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tenancy.Lifecycle
  alias Platform.Tasks.{Plan, PlanEngine, ReviewRequests, Stack, StackDeployer, Task}
  alias Platform.Tasks.Stage
  alias Platform.Tasks.Stacks.{CommencementGate, DepInference, MemberSet}
  alias Platform.Tasks.Stacks.ShipState

  @slug_regex ~r/^[a-z0-9][a-z0-9-]*$/
  @max_slug_length 60

  # ── CRUD ─────────────────────────────────────────────────────────────────

  @doc """
  Create a new stack.

  Validates via `Stack.changeset/2`. Caller is responsible for supplying a
  `rollup_branch` consistent with `rollup_branch_name/1` (typically the
  stack's slug); future stages may auto-derive it.
  """
  @spec create_stack(map()) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t() | :project_archived}
  def create_stack(attrs) when is_map(attrs) do
    project_id = attrs[:project_id] || attrs["project_id"]

    with :ok <- Lifecycle.ensure_project_writable(project_id) do
      %Stack{}
      |> Stack.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Fetch a stack by id. Returns the struct or nil."
  @spec get_stack(binary()) :: Stack.t() | nil
  def get_stack(id) when is_binary(id) do
    # `stack_id` is a raw MCP tool argument at seven tool_surface.ex sites.
    # Platform.UUID.valid?/1, not a bare Ecto.UUID.cast/1 — a bare cast
    # accepts any 16-byte binary and the raise lands inside Repo regardless.
    if Platform.UUID.valid?(id), do: Repo.get(Stack, id), else: nil
  end

  @doc "Fetch a stack by id, raising `Ecto.NoResultsError` if absent."
  @spec get_stack!(binary()) :: Stack.t()
  def get_stack!(id) when is_binary(id) do
    # Documented contract is `Ecto.NoResultsError` when absent, so a malformed
    # id raises THAT and not `Ecto.Query.CastError`.
    if Platform.UUID.valid?(id) do
      Repo.get!(Stack, id)
    else
      raise Ecto.NoResultsError, queryable: Stack
    end
  end

  @doc """
  Look up a non-abandoned stack by its rollup-branch name.

  Used by the GitHub webhook controller (T6) to detect whether a merged
  PR's head branch corresponds to a stack rollup branch, so the
  `pr_merged` validation can be fanned out across all member tasks.
  Abandoned stacks are excluded; if a stale stack/<slug> branch survives
  in the repo, its webhook should fall through to the no-op path rather
  than re-pass member validations.

  Returns the `%Stack{}` or `nil`. `nil` for any non-binary input so
  callers don't have to pre-filter `head_branch == nil`.
  """
  @spec get_stack_by_rollup_branch(String.t() | nil) :: Stack.t() | nil
  def get_stack_by_rollup_branch(rollup_branch) when is_binary(rollup_branch) do
    Stack
    |> where([s], s.rollup_branch == ^rollup_branch and s.status != "abandoned")
    |> limit(1)
    |> Repo.one()
  end

  def get_stack_by_rollup_branch(_), do: nil

  @doc """
  Resolve a `%Stack{}` from a GitHub `pull_request` webhook payload map,
  trying multiple lookup strategies in order until one hits.

  Companion to `get_stack_by_rollup_branch/1` — this is the defensive,
  self-healing entry point the webhook controller uses so a rollup PR
  merge cascades to member tasks even when
  `StackDeployer.maybe_open_stack_pr/1` failed to sync the stack row
  (operator shepherded the PR manually, historical stack row was created
  before `metadata.rollup_pr` stamping landed, etc.).

  Strategies tried in order:

    1. **rollup_branch match** — `stacks.rollup_branch == pr["head"]["ref"]`.
       Preserves existing behavior; happy path when
       `StackDeployer.maybe_open_stack_pr/1` populated the row correctly.

    2. **PR-number match** — `metadata #>> '{rollup_pr,number}' == pr["number"]`.
       Catches stacks whose `rollup_branch` field is stale or NULL but
       whose `metadata.rollup_pr.number` was stamped (either by
       StackDeployer or by an operator-repair path).

    3. **Slug-derived match** — when `pr["head"]["ref"]` matches
       `stack/<slug>` (per `rollup_branch_name/1`), extract the slug and
       look up `stacks.slug == extracted`. Catches historical stacks
       whose `rollup_branch` was never set at create time but whose
       branch convention still identifies them.

  Abandoned stacks are excluded from every strategy — an abandoned stack
  should never re-trigger a member fan-out even if its rollup branch is
  somehow still open in the repo.

  Returns `%Stack{}` when any strategy matches, `nil` when none do. Use
  `get_stack_for_pull_request_with_strategy/1` when the caller needs to
  log which strategy fired (webhook observability).
  """
  @spec get_stack_for_pull_request(map() | nil) :: Stack.t() | nil
  def get_stack_for_pull_request(pr) do
    case get_stack_for_pull_request_with_strategy(pr) do
      {:ok, %Stack{} = stack, _strategy} -> stack
      nil -> nil
    end
  end

  @doc """
  Same lookup as `get_stack_for_pull_request/1` but tags which strategy
  produced the hit.

  Returns `{:ok, %Stack{}, :rollup_branch | :pr_number | :slug}` on
  match, `nil` otherwise. The webhook controller uses the tag to log
  fallback-strategy hits so we can quantify how often
  `StackDeployer.maybe_open_stack_pr/1` under-stamps stack rows in
  production.
  """
  @spec get_stack_for_pull_request_with_strategy(map() | nil) ::
          {:ok, Stack.t(), :rollup_branch | :pr_number | :slug} | nil
  def get_stack_for_pull_request_with_strategy(pr) when is_map(pr) do
    head_ref = get_in(pr, ["head", "ref"])
    number = pr["number"]

    with nil <- match_by_rollup_branch(head_ref),
         nil <- match_by_pr_number(number),
         nil <- match_by_slug(head_ref) do
      nil
    end
  end

  def get_stack_for_pull_request_with_strategy(_), do: nil

  defp match_by_rollup_branch(head_ref) when is_binary(head_ref) do
    case get_stack_by_rollup_branch(head_ref) do
      %Stack{} = stack -> {:ok, stack, :rollup_branch}
      nil -> nil
    end
  end

  defp match_by_rollup_branch(_), do: nil

  defp match_by_pr_number(number) when is_integer(number) and number > 0 do
    stack =
      Stack
      |> where(
        [s],
        fragment("(?->'rollup_pr'->>'number')::int", s.metadata) == ^number and
          s.status != "abandoned"
      )
      |> limit(1)
      |> Repo.one()

    case stack do
      %Stack{} = s -> {:ok, s, :pr_number}
      nil -> nil
    end
  end

  defp match_by_pr_number(_), do: nil

  defp match_by_slug(head_ref) when is_binary(head_ref) do
    case Regex.run(~r/^stack\/([a-z0-9][a-z0-9-]*)$/, head_ref) do
      [_, slug] ->
        stack =
          Stack
          |> where([s], s.slug == ^slug and s.status != "abandoned")
          |> limit(1)
          |> Repo.one()

        case stack do
          %Stack{} = s -> {:ok, s, :slug}
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp match_by_slug(_), do: nil

  @doc """
  List stacks, optionally filtered by `:project_id`, `:status`, and/or
  `:sponsor_user_id`.

  Results are ordered by `inserted_at` descending so the most recent stacks
  come first. The `:sponsor` association is preloaded so LiveView / MCP
  callers don't lazy-load per card (ADR 0042 Decision 8).
  """
  @spec list_stacks(map()) :: [Stack.t()]
  def list_stacks(filters \\ %{}) when is_map(filters) do
    filters
    |> list_stacks_query()
    |> preload(:sponsor)
    |> Repo.all()
  end

  @doc """
  One page of `list_stacks/1`, in the same total order, over the same
  filters (task 01a05394-8300 stage 4 — `stack_list` pagination).

  `page_opts` requires `:limit`; `:offset` defaults to 0. Shares its query
  builder with `list_stacks/1` and `count_stacks/1` so the page and the
  `total` beside it can never describe two different sets.
  """
  @spec list_stacks_page(map(), keyword()) :: [Stack.t()]
  def list_stacks_page(filters, page_opts) when is_map(filters) and is_list(page_opts) do
    limit = Keyword.fetch!(page_opts, :limit)
    offset = Keyword.get(page_opts, :offset, 0)

    filters
    |> list_stacks_query()
    |> limit(^limit)
    |> offset(^offset)
    |> preload(:sponsor)
    |> Repo.all()
  end

  @doc """
  How many stacks `list_stacks/1` would return for `filters`, without
  loading them. A `SELECT count(*)` over the same filters — what makes
  `stack_list`'s `has_more` a fact rather than a restatement of the page
  size (see `Platform.Tasks.count_tasks/1` for the boundary argument).
  """
  @spec count_stacks(map()) :: non_neg_integer()
  def count_stacks(filters) when is_map(filters) do
    filters
    |> list_stacks_query()
    |> exclude(:order_by)
    |> Repo.aggregate(:count, :id)
  end

  # Shared filter + order builder for `list_stacks/1`, `list_stacks_page/2`
  # and `count_stacks/1`. `desc: s.id` is the tiebreaker that makes the
  # order TOTAL: stack ids are UUIDv7, so it agrees with `inserted_at` and
  # only decides the ties the timestamp leaves open. Without it Postgres may
  # return equal-key rows in a different order between two executions, and
  # two consecutive pages can skip one row and repeat another with no error.
  defp list_stacks_query(filters) when is_map(filters) do
    Stack
    |> filter_by_project(Map.get(filters, :project_id))
    |> filter_by_status(Map.get(filters, :status))
    |> filter_by_sponsor(Map.get(filters, :sponsor_user_id))
    # Optional `:access_scope` (task 01a1386d-e528 stage 3): absent is the
    # unchanged query. See `Platform.Tasks.scope_by/3`.
    |> Tasks.maybe_scope_by(Map.get(filters, :access_scope), :stack)
    |> order_by([s], desc: s.inserted_at, desc: s.id)
  end

  defp filter_by_project(query, nil), do: query

  defp filter_by_project(query, project_id) when is_binary(project_id) do
    where(query, [s], s.project_id == ^project_id)
  end

  defp filter_by_status(query, nil), do: query

  defp filter_by_status(query, status) when is_binary(status) do
    where(query, [s], s.status == ^status)
  end

  # `:sponsor_user_id` filter mirrors the tasks-side sponsor pill (ADR 0042):
  # nil is passthrough (unfiltered), a binary UUID narrows to only stacks
  # whose sponsor_user_id equals the given id. NULL rows (unsponsored
  # stacks) are excluded by the equality — nil never equals a user id, so
  # the "sponsored by me" toggle correctly hides unsponsored work.
  defp filter_by_sponsor(query, nil), do: query

  defp filter_by_sponsor(query, sponsor_user_id) when is_binary(sponsor_user_id) do
    where(query, [s], s.sponsor_user_id == ^sponsor_user_id)
  end

  @doc "Update a stack via `Stack.changeset/2`."
  @spec update_stack(Stack.t(), map()) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def update_stack(%Stack{} = stack, attrs) when is_map(attrs) do
    stack
    |> Stack.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Terminal transition for the rollup-PR merge path (T6 stage 2).

  Marks `stack` as `done` and records the rollup-merge summary into
  `stack.metadata["rollup_merge"]`. Existing metadata keys are
  preserved (deep merge at the top level; the `rollup_merge` subtree
  is replaced wholesale because each rollup-PR merge produces a single
  canonical summary).

  Expected `attrs` shape:

      %{
        passed_member_ids: [task_id, ...],
        anomalies: [%{"task_id" => id, "reason" => "...", "recorded_at" => iso8601}, ...],
        merge_commit_sha: sha,
        merged_at: %DateTime{} | iso8601_string
      }

  When `passed_member_ids` is empty (every member was an anomaly), the
  resulting `metadata["rollup_merge"]["degraded"]` flag is set to
  `true` and the caller is expected to emit an ERROR log alongside.
  The stack still transitions to `done` so the rollup-PR's deploy
  surface accurately reflects what happened on GitHub; the degraded
  flag signals that no member validations were actually flipped here
  and operator triage is warranted.

  Idempotency: a stack already at `done` with `metadata["rollup_merge"]`
  populated is left untouched; the function returns `{:ok, stack}`
  with the existing metadata so a replayed webhook does NOT clobber
  the original history.
  """
  @spec complete_rollup_merge(Stack.t(), %{
          optional(:passed_member_ids) => [String.t()],
          optional(:anomalies) => [map()],
          optional(:merge_commit_sha) => String.t() | nil,
          optional(:merged_at) => DateTime.t() | String.t() | nil
        }) :: {:ok, Stack.t()} | {:error, Ecto.Changeset.t()}
  def complete_rollup_merge(%Stack{} = stack, attrs) when is_map(attrs) do
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    if stack.status == "done" and Map.has_key?(base_meta, "rollup_merge") do
      {:ok, stack}
    else
      passed = Map.get(attrs, :passed_member_ids, [])
      anomalies = Map.get(attrs, :anomalies, [])
      sha = Map.get(attrs, :merge_commit_sha)
      merged_at = format_merged_at(Map.get(attrs, :merged_at))

      rollup_merge =
        %{
          "merged_at" => merged_at,
          "merge_commit_sha" => sha,
          "members_passed" => passed,
          "anomalies" => anomalies
        }
        |> maybe_set_degraded(passed)

      new_meta = Map.put(base_meta, "rollup_merge", rollup_merge)

      stack
      |> Stack.changeset(%{status: "done", metadata: new_meta})
      |> Repo.update()
    end
  end

  defp maybe_set_degraded(rollup_merge, []), do: Map.put(rollup_merge, "degraded", true)
  defp maybe_set_degraded(rollup_merge, _passed), do: rollup_merge

  defp format_merged_at(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_merged_at(str) when is_binary(str), do: str
  defp format_merged_at(_), do: nil

  @doc """
  Status cascade for `stack_start`: transition a `forming` stack to
  `in_progress` and fan its members out per ADR 0041 §"Status cascade —
  entering a stack".

  Behavior:

    * Stack must be at `forming` to start — any other status returns
      `{:error, :invalid_stack_status}`.
    * Compute `executable_members/1` (level-0 roots in the in-stack DAG).
    * Transition every root currently at `backlog` to `in_progress` via
      `Tasks.transition_task/2`. Roots already past `backlog` are left
      alone — the cascade is additive, not destructive.
    * Transition every non-root member currently at `backlog` to
      `stack_pending` via `Tasks.transition_task/2`. Same backlog-only
      filter so we never overwrite committed work.
    * Flip the stack-level status from `forming` to `in_progress`.
    * BEFORE any of the above, synchronously ensure the stack's rollup
      branch is live on origin (task 01a05392 stage 1). When it cannot be
      made to exist, returns
      `{:error, {:rollup_branch_unavailable, reason}}`, promotes NO member
      and leaves the stack at `forming` so the call is retryable.

  Returns `{:ok, %{stack: stack, started: roots, parked: pending}}` on
  success. Per-member transition failures (e.g. a root with no
  approved plan) are surfaced in the returned shape as
  `{:partial, %{stack: stack, started: ok_roots, parked: ok_pending,
  errors: errors}}` so the caller can choose to halt-and-fix or
  proceed.

  ADR 0042 Decision 4: refuses upfront with
  `{:error, :stack_plans_pending, %{stack_id, waiting_on}}` when any
  member is still missing an approved plan. The stack status is NOT
  flipped and NO members are cascaded — partial cascades while plans
  are still landing would leave the stack in an inconsistent half-open
  state.
  """
  @spec start_stack(Stack.t() | binary()) ::
          {:ok, %{stack: Stack.t(), started: [Task.t()], parked: [Task.t()]}}
          | {:partial,
             %{
               stack: Stack.t(),
               started: [Task.t()],
               parked: [Task.t()],
               errors: [%{task_id: String.t(), target_status: String.t(), reason: term()}]
             }}
          | {:error, {:rollup_branch_unavailable, term()}}
          | {:error, :invalid_stack_status | :stack_not_found | term()}
          | {:error, :stack_plans_pending, %{stack_id: String.t(), waiting_on: [String.t()]}}
  def start_stack(%Stack{status: status}) when status != "forming",
    do: {:error, :invalid_stack_status}

  def start_stack(%Stack{} = stack) do
    with :ok <- require_stack_members_not_quarantined(stack) do
      do_start_stack_gate(stack)
    end
  end

  def start_stack(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> start_stack(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  defp do_start_stack_gate(%Stack{} = stack) do
    # ADR 0042 Decision 4: the commencement gate short-circuits the cascade
    # entirely when any member is still missing an approved plan. We check
    # BEFORE mutating anything so the stack is left untouched — a partial
    # cascade over a mostly-ready stack would leak `stack_pending` /
    # `in_progress` members from a stack that never actually opened.
    if CommencementGate.plans_ready?(stack) do
      do_start_stack(stack)
    else
      {:error, :stack_plans_pending,
       %{stack_id: stack.id, waiting_on: CommencementGate.waiting_on(stack.id)}}
    end
  end

  defp do_start_stack(%Stack{} = stack) do
    with :ok <- require_stack_members_not_quarantined(stack) do
      do_start_stack_allowed(stack)
    end
  end

  defp do_start_stack_allowed(%Stack{} = stack) do
    # ADR 0045 Decision 2 (task 01a05392 stage 1): the rollup branch MUST be
    # live on origin BEFORE any member is promoted to `in_progress`, because
    # the HeartbeatScheduler cuts a member branch from `origin/<rollup_branch>`
    # only when `stack.metadata["rollup_branch_ready"]` is stamped, and
    # silently falls back to `origin/<default_branch>` otherwise. Kicking the
    # create off asynchronously (the previous
    # `StackDeployer.handle_stack_transition/3` call that stood here) raced the
    # root cascade: a root dispatched before the push landed started on the
    # DEFAULT branch and never saw its siblings — the exact property the rollup
    # exists to provide.
    #
    # So: run `ensure_rollup_branch/1` SYNCHRONOUSLY (it is the documented
    # idempotent delegate, short-circuiting with `:already_exists` when
    # `handle_stack_created/1` already made the branch at `stack_create` time,
    # so the common path is a cheap existence check rather than a fresh clone).
    # A git failure now fails `start_stack/1` outright instead of degrading
    # quietly — a stack whose members start on `main` has already lost the
    # property the rollup exists for, so refusing to start is strictly better
    # than starting wrong.
    #
    # The ensure runs BEFORE the `forming -> in_progress` flip, NOT after it.
    # A failure that left the stack `in_progress` with every root still
    # `backlog` would wedge it permanently: `rollup_status_for` computes
    # `forming`, `Stack.changeset`'s `guard_no_forming_regression` silently
    # drops the write back, and `start_stack/1` refuses anything that is not
    # `forming` — so a transient git failure would be unrecoverable. Ensuring
    # first leaves a failed start on a still-`forming` stack, which is exactly
    # retryable. `ensure_rollup_branch/1` is happy against a `forming` stack —
    # `handle_stack_created/1` already calls it in that state.
    #
    # Deliberately NOT inside a `Repo.transaction` here: the call performs a
    # clone/push and takes its own per-stack advisory lock internally, and
    # pinning a pool connection across a network round-trip is how a slow
    # remote becomes a pool outage.
    case StackDeployer.ensure_rollup_branch(stack) do
      {:ok, _create_result} ->
        do_start_stack_cascade(stack)

      # A project with no `repo_url` has no git surface AT ALL: there is no
      # rollup branch to guarantee, no member branch to mis-parent, and the
      # HeartbeatScheduler suppresses the whole git-workflow block for such a
      # task anyway (`deploy_repos_present?/1`). Refusing to start would be
      # refusing over a property that cannot be violated. The failure this
      # gate exists for is a REAL repo whose rollup push has not landed.
      {:error, :no_repo_url} ->
        Logger.info(
          "[Stacks.start_stack] stack #{stack.id} project has no repo_url; " <>
            "no rollup branch to ensure, commencing anyway"
        )

        do_start_stack_cascade(stack)

      {:error, reason} ->
        Logger.warning(
          "[Stacks.start_stack] stack #{stack.id} rollup branch #{stack.rollup_branch} " <>
            "unavailable (#{inspect(reason)}); NO member promoted, stack left forming"
        )

        {:error, {:rollup_branch_unavailable, reason}}
    end
  end

  defp do_start_stack_cascade(%Stack{} = stack) do
    # Re-read the stack so the `rollup_branch_ready` stamp that
    # `stamp_rollup_branch_ready/2` just wrote is present on the struct the
    # cascade (and every dispatch derived from it) sees. The in-memory struct
    # we were handed predates that write and cannot witness it.
    stack = Repo.get(Stack, stack.id) || stack

    # ADR 0042 Decision 4: flip the stack to `in_progress` BEFORE cascading
    # members. The commencement gate (`CommencementGate.open?/1`) enforced
    # inside `transition_task_status/2` reads `stack.status` and refuses
    # unless it's `in_progress`, so the stack must be opened first for the
    # cascade's `member → in_progress` transitions to pass the guard.
    # Previously the stack was flipped after the cascade, but the existing
    # `:partial` semantics already flip the stack even when cascade errors
    # surface, so the observable invariant is unchanged.
    case Stack.changeset(stack, %{status: "in_progress"}) |> Repo.update() do
      {:ok, updated} ->
        members = members(updated)
        roots = executable_members(updated)
        root_ids = MapSet.new(roots, & &1.id)

        {started, root_errors} =
          Enum.reduce(roots, {[], []}, fn member, {ok, errors} ->
            cascade_member(member, "in_progress", ok, errors)
          end)

        non_roots = Enum.reject(members, &MapSet.member?(root_ids, &1.id))

        {parked, pending_errors} =
          Enum.reduce(non_roots, {[], []}, fn member, {ok, errors} ->
            cascade_member(member, "stack_pending", ok, errors)
          end)

        result = %{
          stack: updated,
          started: Enum.reverse(started),
          parked: Enum.reverse(parked)
        }

        case root_errors ++ pending_errors do
          [] -> {:ok, result}
          errors -> {:partial, Map.put(result, :errors, Enum.reverse(errors))}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Gap 3 self-heal (task 019f921d): idempotently commence a `forming` stack
  that is actually ready, so a stack can NEVER stay stuck in `forming` with
  every member plan approved — the state that closed `CommencementGate` for
  all seven Inbox members and forced hand-reconciliation.

  When `stack.status == "forming"` AND `CommencementGate.plans_ready?/1`,
  runs the same commence path as `start_stack/1` (the `do_start_stack/1`
  flip + root/non-root cascade). No-op for any other status, or when plans
  are not ready. Unlike `start_stack/1`, this is log-and-swallow (mirrors
  `sweep_stack_dependents/1`): a cascade failure never propagates to the
  caller, which is a broadcast handler or the periodic reconcile tick.

  Wired into (a) the last-plan-approval broadcast path
  (`Tasks.approve_plan/3`, `:stack_gate_opened`) and (b) the periodic
  reconcile (`TaskRouterWatcher`), so a `forming`-but-ready stack is driven
  open from both an event and a timer.

  Returns the `do_start_stack/1` result on a real commence, or `:noop`.
  """
  @spec commence_if_ready(Stack.t() | binary()) ::
          {:ok, map()} | {:partial, map()} | {:error, term()} | :noop
  def commence_if_ready(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> commence_if_ready(stack)
      nil -> :noop
    end
  end

  def commence_if_ready(%Stack{status: "forming"} = stack) do
    if CommencementGate.plans_ready?(stack) do
      Logger.info("[Stacks.commence_if_ready] stack #{stack.id} is forming-but-ready; commencing")

      do_start_stack(stack)
    else
      :noop
    end
  rescue
    e ->
      Logger.warning(
        "[Stacks.commence_if_ready] raised for stack #{stack.id}: #{Exception.message(e)}"
      )

      :noop
  catch
    :exit, reason ->
      Logger.warning(
        "[Stacks.commence_if_ready] exited for stack #{stack.id}: #{inspect(reason)}"
      )

      :noop
  end

  def commence_if_ready(%Stack{}), do: :noop

  # Statuses whose members can be parked at `stack_pending` behind a
  # re-closed gate. `"gated"` is carried over from
  # `@promotable_stack_statuses` for parity; `Platform.Tasks.Stack` never
  # writes it, so that branch is unreachable today (task 01a05393 stage 5).
  @redrivable_stack_statuses ~w(in_progress gated)

  @doc """
  Re-drive the commencement gate for a stack that has ALREADY commenced
  (task 01a05393 stage 5, defect A part 2).

  `commence_if_ready/1` only ever opens a `forming` stack. Once a stack is
  `in_progress`, a late joiner added through `add_task_with_report/3` with
  no approved plan re-closes `CommencementGate` for every member, and the
  ONLY thing that used to reopen it was the 5-minute
  `sweep_stack_pending_members/0` tick. This function is the event-side
  reopen: called from `Tasks.approve_plan/3` post-commit, it promotes every
  `stack_pending` member of THIS stack whose in-stack deps have landed
  (`try_promote/1`, in `stack_position` order), the moment the last
  outstanding plan is approved.

    * `forming` → delegates to `commence_if_ready/1` unchanged.
    * `in_progress` / `gated` → if `CommencementGate.plans_ready?/1`,
      `{:ok, %{promoted: [task_id]}}` (possibly empty: a member whose OWN
      deps have not landed stays parked — the gate reopening is not a
      licence to skip the DAG); else `:noop`.
    * anything else → `:noop`.

  Must run OUTSIDE the caller's transaction: `try_promote/1` goes through
  `Tasks.transition_task/2`, whose inner rollback on a closed gate poisons
  an enclosing transaction (stage 3's lesson), and the `{:task_updated, _}`
  broadcasts it fires must not be observable before the approval commits.
  Log-and-swallow like `commence_if_ready/1`: a failed re-drive never
  surfaces to the approval that triggered it.
  """
  @spec redrive_gate(Stack.t() | binary()) ::
          {:ok, map()} | {:partial, map()} | {:error, term()} | :noop
  def redrive_gate(stack_id) when is_binary(stack_id) do
    case get_stack(stack_id) do
      %Stack{} = stack -> redrive_gate(stack)
      nil -> :noop
    end
  end

  def redrive_gate(%Stack{status: "forming"} = stack), do: commence_if_ready(stack)

  def redrive_gate(%Stack{status: status} = stack) when status in @redrivable_stack_statuses do
    if CommencementGate.plans_ready?(stack) do
      promoted =
        Task
        |> where([t], t.stack_id == ^stack.id)
        |> where([t], t.status == "stack_pending")
        |> where([t], is_nil(t.deleted_at))
        |> order_by([t], asc: t.stack_position, asc: t.inserted_at)
        |> Repo.all()
        |> Enum.reduce([], fn member, acc ->
          case safe_try_promote(member) do
            {:ok, updated} -> [updated.id | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      Logger.info(
        "[Stacks.redrive_gate] stack #{stack.id} (#{status}) gate is open; " <>
          "promoted #{length(promoted)} stack_pending member(s): #{inspect(promoted)}"
      )

      {:ok, %{promoted: promoted}}
    else
      :noop
    end
  rescue
    e ->
      Logger.warning(
        "[Stacks.redrive_gate] raised for stack #{stack.id}: #{Exception.message(e)}"
      )

      :noop
  catch
    :exit, reason ->
      Logger.warning("[Stacks.redrive_gate] exited for stack #{stack.id}: #{inspect(reason)}")

      :noop
  end

  def redrive_gate(%Stack{}), do: :noop

  @doc """
  Gap 3 + Gap 4 periodic reconcile (task 019f921d): the timer-side backstop
  for the two fire-and-forget lifecycle gaps. Finds every non-terminal
  stack and:

    * commences it if it is `forming`-but-ready (`commence_if_ready/1`), and
    * re-fires the rollup-PR open for any stack stuck at `deploying` with no
      `metadata["rollup_pr"]` (`reconcile_deploying_stacks/0`), and
    * promotes any member still parked at `stack_pending` whose in-stack deps
      have since cleared (`sweep_stack_pending_members/0`), and
    * polls GitHub for any `deploying` stack whose numbered rollup PR merged
      without the webhook ever arriving (`reconcile_merged_rollups/0`, task
      01a05394); the `rollup_merges:` key of the summary carries its
      `checked` / `completed` / `unmerged` / `errored` counts.

  Invoked from `TaskRouterWatcher`'s 5-minute reconcile tick. Log-and-swallow
  throughout: a single bad stack never aborts the sweep. Returns a summary
  map for the caller's reconcile log line.
  """
  @spec reconcile_stack_lifecycle() :: %{
          commenced: non_neg_integer(),
          pr_reopened: non_neg_integer(),
          promoted: non_neg_integer(),
          rollup_merges: %{
            checked: non_neg_integer(),
            completed: non_neg_integer(),
            unmerged: non_neg_integer(),
            errored: non_neg_integer()
          }
        }
  def reconcile_stack_lifecycle do
    commenced =
      Stack
      |> where([s], s.status == "forming")
      |> Repo.all()
      |> Enum.reduce(0, fn stack, acc ->
        case commence_if_ready(stack) do
          {:ok, _} -> acc + 1
          {:partial, _} -> acc + 1
          _ -> acc
        end
      end)

    pr_reopened = reconcile_deploying_stacks()
    promoted = sweep_stack_pending_members()
    rollup_merges = reconcile_merged_rollups()

    %{
      commenced: commenced,
      pr_reopened: pr_reopened,
      promoted: promoted,
      rollup_merges: rollup_merges
    }
  end

  # Stack statuses whose members can legitimately be sitting at
  # `stack_pending` waiting on an in-stack dependency. Terminal and
  # pre-commencement-failure statuses are excluded deliberately.
  @promotable_stack_statuses ["in_progress", "gated", "forming"]

  @doc """
  Late-precondition promotion sweep (task 019fbe9e): promote every member
  still parked at `stack_pending` whose in-stack dependencies have since
  cleared the unblock threshold.

  Why a SWEEP and not another cascade: the gate-open event fires exactly
  once (`detect_gate_open_transition/2` is guarded by
  `pre_update_plan_already_counted?/1`), so a promotion hung off that event
  cannot serve a precondition that becomes true LATER. `commence_if_ready/1`
  only looks at `forming` stacks and `reconcile_deploying_stacks/0` only at
  `deploying` ones — nothing re-derived `stack_pending` membership of an
  already-`in_progress` stack. This sweep re-derives it from current state on
  every tick, so it covers both start-up and mid-life.

  Idempotency mechanism (named, not hand-waved): promotion goes through the
  EXISTING `try_promote/1`, whose head matches
  `%Task{status: "stack_pending"}` and whose catch-all clause
  `def try_promote(%Task{}), do: :noop` leaves any member already at
  `in_progress`/`in_review`/`done` completely untouched — no write, so no
  `updated_at` churn. The member query ALSO filters `status == "stack_pending"`
  so that a concurrent tick cannot widen the candidate set.

  Note for anyone testing this: the query filter and the function-head guard
  are REDUNDANT with each other AND with a third guard underneath both —
  `Tasks.transition_task/2` rejects an identity transition, because
  `@valid_task_transitions["in_progress"]` does not contain `"in_progress"`.
  Mutating either of the first two guards individually, or both together, is
  therefore behaviourally invisible: the innermost rejection still refuses the
  write. Idempotency here is over-determined, not untested — but no
  behavioural assertion can distinguish the three layers, so do not read a
  green test as evidence that any ONE of them is load-bearing.

  Each per-member promotion is wrapped so one failure never aborts the sweep,
  mirroring the reduce-and-drop shape in `sweep_stack_dependents/1`.

  Returns the count of members actually promoted on this pass.
  """
  @spec sweep_stack_pending_members() :: non_neg_integer()
  def sweep_stack_pending_members do
    stack_ids =
      Stack
      |> where([s], s.status in ^@promotable_stack_statuses)
      |> select([s], s.id)
      |> Repo.all()

    case stack_ids do
      [] ->
        0

      ids ->
        Task
        |> where([t], t.stack_id in ^ids)
        |> where([t], t.status == "stack_pending")
        |> where([t], is_nil(t.deleted_at))
        |> Repo.all()
        |> Enum.reduce(0, fn member, acc ->
          case safe_try_promote(member) do
            {:ok, _updated} -> acc + 1
            _ -> acc
          end
        end)
    end
  end

  defp safe_try_promote(%Task{} = member) do
    try_promote(member)
  rescue
    e ->
      Logger.warning(
        "[Stacks.sweep_stack_pending_members] try_promote raised for task " <>
          "#{member.id}: #{Exception.message(e)}"
      )

      :error
  catch
    :exit, reason ->
      Logger.warning(
        "[Stacks.sweep_stack_pending_members] try_promote exited for task " <>
          "#{member.id}: #{inspect(reason)}"
      )

      :error
  end

  @doc """
  Gap 4 durable rollup-PR-open reconcile (task 019f921d): re-fire
  `StackDeployer.maybe_open_stack_pr/1` for every stack stuck at
  `deploying` with no `metadata["rollup_pr"]` — the fire-and-forget
  open that never landed for the Inbox stack. Safe to re-run because the
  deployer's gate is idempotent (`pr_already_opened?/1` short-circuits once
  `metadata["rollup_pr"]` is stamped). Returns the count of stacks whose PR
  actually opened on this pass.
  """
  @spec reconcile_deploying_stacks() :: non_neg_integer()
  def reconcile_deploying_stacks do
    Stack
    |> where([s], s.status == "deploying")
    |> Repo.all()
    |> Enum.reject(&rollup_pr_stamped?/1)
    |> Enum.reduce(0, fn stack, acc ->
      case safe_reopen_stack_pr(stack) do
        {:ok, %{status: :opened}} -> acc + 1
        _ -> acc
      end
    end)
  end

  defp rollup_pr_stamped?(%Stack{metadata: meta}) when is_map(meta) do
    case Map.get(meta, "rollup_pr") do
      %{} = pr -> Map.has_key?(pr, "number") or Map.get(pr, "status") == "opening"
      _ -> false
    end
  end

  defp rollup_pr_stamped?(_), do: false

  defp safe_reopen_stack_pr(%Stack{} = stack) do
    Logger.info(
      "[Stacks.reconcile_deploying_stacks] stack #{stack.id} is deploying with no " <>
        "rollup_pr; re-firing maybe_open_stack_pr"
    )

    StackDeployer.maybe_open_stack_pr(stack)
  rescue
    e ->
      Logger.warning(
        "[Stacks.reconcile_deploying_stacks] maybe_open_stack_pr raised for stack " <>
          "#{stack.id}: #{Exception.message(e)}"
      )

      :error
  catch
    :exit, reason ->
      Logger.warning(
        "[Stacks.reconcile_deploying_stacks] maybe_open_stack_pr exited for stack " <>
          "#{stack.id}: #{inspect(reason)}"
      )

      :error
  end

  @doc """
  Rollup-merge backstop poll (task 01a05394 stage 2): the reconciliation
  path behind the GitHub webhook.

  The webhook (`RollupWebhookProcessor.process_stack_merged_pr/4`, reached
  from `GithubWebhookController` on `pull_request` `closed`+`merged`) is the
  FAST path and is unchanged. But `deploying` is a state nothing retries: a
  stack whose rollup PR merged while the delivery was missed sits there
  forever, and an observer cannot tell "still waiting for a merge" from
  "stuck". This poll asks the git runner for GitHub's current merge state of
  every `deploying` stack that HAS a numbered `metadata["rollup_pr"]` — the
  exact complement of `reconcile_deploying_stacks/0`, which handles the
  stacks with NO stamped PR — and, on `merged: true`, routes through the
  SAME replay-aware entry point the webhook uses.

  Observability: every stack checked gets
  `metadata["rollup_merge_watch"]` stamped with `last_checked_at`, a
  monotonically bumped `checks` count, `last_result` in
  `"unmerged" | "merged" | "error"`, and `last_error` (`nil` unless
  `"error"`). A poll that ran and found the PR still open is `"unmerged"`;
  a poll that could not answer (runner error, missing callback, project
  without `repo_url`, or a raise inside the completion path) is `"error"`.
  Those two are distinguishable both in the stored stamp and in the
  returned summary — `unmerged` is never counted in `completed`.

  The stamp is a plain `update_stack/2` outside any transaction. Completion
  broadcasting is owned by `RollupWebhookProcessor` /
  `StackDeployer.handle_rollup_pr_merged/2`; nothing is broadcast here.
  Log-and-swallow per stack: one bad stack never aborts the sweep.
  """
  @spec reconcile_merged_rollups() :: %{
          checked: non_neg_integer(),
          completed: non_neg_integer(),
          unmerged: non_neg_integer(),
          errored: non_neg_integer()
        }
  def reconcile_merged_rollups do
    Stack
    |> where([s], s.status == "deploying")
    |> Repo.all()
    |> Enum.filter(&is_integer(rollup_pr_number(&1)))
    |> Enum.reduce(%{checked: 0, completed: 0, unmerged: 0, errored: 0}, fn stack, acc ->
      outcome = safe_reconcile_merged_rollup(stack)
      _ = stamp_rollup_merge_watch(stack, outcome)

      acc = %{acc | checked: acc.checked + 1}

      case outcome do
        :completed -> %{acc | completed: acc.completed + 1}
        :unmerged -> %{acc | unmerged: acc.unmerged + 1}
        {:error, _reason} -> %{acc | errored: acc.errored + 1}
      end
    end)
  end

  defp rollup_pr_number(%Stack{metadata: %{"rollup_pr" => %{"number" => number}}}), do: number
  defp rollup_pr_number(_), do: nil

  # One stack's merge check. Returns `:completed`, `:unmerged`, or
  # `{:error, reason}`; never raises — mirrors `safe_reopen_stack_pr/1`.
  defp safe_reconcile_merged_rollup(%Stack{} = stack) do
    with {:ok, repo_url} <- rollup_repo_url(stack),
         {:ok, state} <- call_pr_merge_state(stack, repo_url) do
      complete_if_merged(stack, state)
    end
  rescue
    e ->
      Logger.warning(
        "[Stacks.reconcile_merged_rollups] merge check raised for stack " <>
          "#{stack.id}: #{Exception.message(e)}"
      )

      {:error, {:raised, Exception.message(e)}}
  catch
    :exit, reason ->
      Logger.warning(
        "[Stacks.reconcile_merged_rollups] merge check exited for stack " <>
          "#{stack.id}: #{inspect(reason)}"
      )

      {:error, {:exit, reason}}
  end

  defp rollup_repo_url(%Stack{} = stack) do
    case Tasks.get_project(stack.project_id) do
      %{repo_url: url} when is_binary(url) and url != "" -> {:ok, url}
      nil -> {:error, :project_not_found}
      _ -> {:error, :no_repo_url}
    end
  end

  # Mirrors `StackDeployer.call_open_pr/3`: `pr_merge_state/1` is an
  # optional `GitRunner` callback, so a runner without it is a recorded
  # error, not a crash and not a silent "unmerged".
  defp call_pr_merge_state(%Stack{} = stack, repo_url) do
    runner = StackDeployer.git_runner()

    args = %{
      repo_url: repo_url,
      pr_number: rollup_pr_number(stack),
      project_id: stack.project_id,
      stack_id: stack.id
    }

    if Code.ensure_loaded?(runner) and function_exported?(runner, :pr_merge_state, 1) do
      case runner.pr_merge_state(args) do
        {:ok, %{merged: merged} = state} when is_boolean(merged) -> {:ok, state}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_runner_reply, other}}
      end
    else
      {:error, {:runner_missing_callback, :pr_merge_state}}
    end
  end

  defp complete_if_merged(%Stack{}, %{merged: false}), do: :unmerged

  defp complete_if_merged(%Stack{} = stack, %{merged: true} = state) do
    number = rollup_pr_number(stack)
    stamped_url = get_in(stack.metadata, ["rollup_pr", "url"])

    # Synthetic `pr` map in the webhook payload's shape — the SAME entry
    # point the webhook uses, which is already replay-aware.
    pr = %{
      "number" => number,
      "html_url" => Map.get(state, :url) || stamped_url,
      "merge_commit_sha" => Map.get(state, :merge_commit_sha)
    }

    merged_at = Map.get(state, :merged_at) || DateTime.to_iso8601(DateTime.utc_now())

    Logger.info(
      "[Stacks.reconcile_merged_rollups] rollup PR ##{number} for stack #{stack.id} " <>
        "is merged on GitHub but the stack is still deploying (webhook missed); " <>
        "routing through process_stack_merged_pr"
    )

    # Re-read before completing. `stack` is the sweep's candidate snapshot,
    # taken BEFORE the origin round-trip; a webhook that lands in that
    # window has already flipped the row to `done` + stamped
    # `rollup_merge`. The processor's replay guard reads `status` and
    # `metadata` off the struct it is given, so handing it the snapshot
    # would re-complete on top of the webhook's stamp (task 01a05394
    # stage 3 caught exactly that: the poll's sha overwrote the webhook's).
    case get_stack(stack.id) do
      nil ->
        {:error, :stack_not_found}

      %Stack{} = fresh ->
        case Platform.Tasks.RollupWebhookProcessor.process_stack_merged_pr(
               fresh,
               pr,
               merged_at,
               nil
             ) do
          :ok -> :completed
          other -> {:error, {:process_stack_merged_pr, other}}
        end
    end
  end

  # Per-stack watch stamp. Re-reads the row first: on `:completed` the
  # completion path has just rewritten `metadata` (`rollup_merge`) and
  # `status`, and stamping over the stale struct would clobber that.
  defp stamp_rollup_merge_watch(%Stack{id: id}, outcome) do
    case get_stack(id) do
      nil ->
        :noop

      %Stack{} = fresh ->
        base_meta = if is_map(fresh.metadata), do: fresh.metadata, else: %{}
        prev = Map.get(base_meta, "rollup_merge_watch") || %{}
        prev_checks = if is_integer(prev["checks"]), do: prev["checks"], else: 0

        {result, error} =
          case outcome do
            :completed -> {"merged", nil}
            :unmerged -> {"unmerged", nil}
            {:error, reason} -> {"error", inspect(reason)}
          end

        watch = %{
          "last_checked_at" => DateTime.to_iso8601(DateTime.utc_now()),
          "checks" => prev_checks + 1,
          "last_result" => result,
          "last_error" => error
        }

        update_stack(fresh, %{metadata: Map.put(base_meta, "rollup_merge_watch", watch)})
    end
  rescue
    e ->
      Logger.warning(
        "[Stacks.reconcile_merged_rollups] watch stamp raised for stack #{id}: " <>
          Exception.message(e)
      )

      :error
  end

  # ADR 0041 Status cascade — entering a stack.
  #
  # Members at `backlog` are dragged forward to whatever target the
  # caller passes — `in_progress` (roots via `start_stack/1`),
  # `stack_pending` (non-roots via `start_stack/1`), or `planning`
  # (wave-gated dispatch via `start_planning/1`).
  #
  # Additionally, roots targeted at `in_progress` accept `stack_pending`
  # as a valid source status: `stack_pending` roots arrive there when
  # `task_create` side effects or an operator `task_update` already
  # flipped the member out of `backlog` before `start_stack/1` ran, and
  # the state machine allows `stack_pending → in_progress` (see
  # `Tasks.@allowed_transitions`). Without this second clause the
  # cascade would leave those roots stranded — silently swallowing the
  # router dispatch downstream (incident 019f5e29). The transitioned
  # roots are folded into `started:` alongside the `backlog → in_progress`
  # promotions so operators see what actually happened.
  #
  # Anything else — a member already past the target (`planning`,
  # `in_progress`, `in_review`, …) or a non-root already at
  # `stack_pending` — is left alone: no cascade write, no reported
  # transition. The wildcard clause is idempotent by design.
  defp cascade_member(%Task{status: "backlog"} = member, target, ok, errors) do
    do_cascade_member(member, target, ok, errors)
  end

  defp cascade_member(%Task{status: "stack_pending"} = member, "in_progress" = target, ok, errors) do
    do_cascade_member(member, target, ok, errors)
  end

  defp cascade_member(_member, _target, ok, errors), do: {ok, errors}

  defp do_cascade_member(member, target, ok, errors) do
    case Tasks.transition_task(member, target) do
      {:ok, updated} ->
        {[updated | ok], errors}

      {:error, reason} ->
        {ok, [%{task_id: member.id, target_status: target, reason: reason} | errors]}
    end
  end

  @doc """
  Stack-level "Start Planning": drive members into the `planning`
  lifecycle using wave-gated dispatch (ADR 0045 / stack v2).

  Wave-gated dispatch replaces the previous all-at-once cascade. The
  topological DAG built from `tasks.dependencies` (agent-inferred and/or
  user-authored) is split into "waves" — level 0 is the roots (no
  in-stack deps), level N contains members whose in-stack deps all land
  in waves 0..N-1. See `planning_waves/1` for the level structure.

  The mode key on the parent stack governs how many waves fan out per
  call:

    * `stack.auto_plan == false` (default): dispatch **wave 0 only**.
      Downstream waves advance when their upstream members' plans clear
      review — either the operator approves via `Tasks.approve_plan/3`,
      which fires `maybe_advance_stack_planning/1` and re-enters this
      module through `advance_planning_waves/1`, or an integrator calls
      `advance_planning_waves/1` directly.
    * `stack.auto_plan == true`: **every** wave fans out in a single
      pass. Each wave still emits its own `:wave_dispatched` telemetry
      event (`wave_index: 0..N-1`, in order), so downstream observers
      see the same event contract as manual mode — just N events in one
      call instead of one now plus N-1 later. Plans still submit
      individually; `auto_accept_plan` (below, resolved by
      `Tasks.maybe_auto_approve/1`) is the flag that also auto-approves
      each plan on submit.

  ## Composition with the dep-inference planner

  Before wave computation, `start_planning/1` calls the same
  `DepInference.infer_edges/2` + persist path that member 1 landed
  (see below). Inferred edges land through `add_dependency_edge/4`, so
  they inherit the DAG validation, cross-stack guard, and rollback
  semantics of any hand-authored edge. Idempotent: if any member
  already carries an in-stack `dependencies` entry, inference is skipped
  entirely to respect the override and avoid duplicate LLM spend.

  ## Idempotency guard

  If **any** member is past `backlog` (planning, stack_pending,
  in_progress, in_review, deploying, done, or blocked), planning has
  already been kicked off for this stack. The function returns
  `{:noop, :already_in_flight}` **without** re-running dep inference or
  telemetry so a double-click on the UI action doesn't produce a
  duplicate `dep_inference` event. A `Logger.info` line records the
  short-circuit.

  ## Cycle / cross-stack guard

  If `planning_waves/1` returns `{:error, :cycle, path}` or
  `{:error, :cross_stack_dep, payload}`, the error is passed through
  unchanged and NO members transition. Wave-gated dispatch is
  meaningless on an invalid DAG; the caller decides how to surface it.

  ## Dep-inference behaviour

    * `try_infer_with_retry/2` calls `DepInference.infer_edges/2` and
      retries once on `{:error, :parse_failed}` or `{:error,
      :adapter_failed}`; up to 2 adapter calls per attempt.
    * Returned edges are written sequentially through
      `add_dependency_edge/4`. If any write returns `{:error, :cycle, _}`
      the already-committed inference edges are reverted via
      `remove_dependency_edge/4` and inference is retried ONCE. A second
      cycle logs a `[Stacks.start_planning]` warning and falls through to
      the cascade with `edges_authored: 0, edges_skipped_reason: :cycle`.
    * Terminal `:parse_failed` / `:adapter_failed` after retry logs a
      warning, sets `edges_authored: 0`, `edges_skipped_reason: reason`,
      and lets the cascade run.

  ## Telemetry

    * `[:platform, :stacks, :dep_inference, :computed | :failed]` —
      emitted after the dep-inference stage (unchanged from member 1).
    * `[:platform, :stacks, :planning, :started]` — emitted exactly
      **once** per dispatching invocation, immediately after the DAG is
      validated and before any wave fans out.
      Measurements: `%{member_count}` (total stack members).
      Metadata: `%{stack_id, mode: :manual | :auto, waves_total}`.
      Skipped on the `:already_in_flight`, `:cycle`, and
      `:cross_stack_dep` short-circuits — those fire `:noop` instead.
    * `[:platform, :stacks, :planning, :wave_dispatched]` — emitted
      once per wave that this call dispatches.
      Measurements: `%{member_count}` (members promoted in this wave).
      Metadata: `%{stack_id, wave_index}`.
      Manual mode fires it exactly once (wave 0); auto mode fires it N
      times (wave_index 0..N-1) in order.
    * `[:platform, :stacks, :planning, :unassigned]` — emitted once per
      dispatching invocation when at least one member was refused for
      lack of a dispatchable planning assignee. Measurements:
      `%{member_count}` (refused members). Metadata:
      `%{stack_id, member_ids}`. Paired with a `Logger.warning`. Note
      `:wave_dispatched`'s `member_count` counts only members actually
      transitioned — a wave whose members were all refused reports 0.
    * `[:platform, :stacks, :planning, :noop]` — emitted when the entry
      short-circuits without dispatching. Measurements: `%{}`. Metadata:
      `%{stack_id, reason: :already_in_flight | :cycle | :cross_stack_dep}`.
    * `[:platform, :stacks, :planning, :advanced]` — emitted by
      `advance_planning_waves/1` when a wave is promoted from `backlog`
      into `planning`. Measurements: `%{member_count}`. Metadata:
      `%{stack_id, wave_index}`. Sibling of `:wave_dispatched` — the
      latter continues to fire from advance for backwards compatibility;
      `:advanced` lets observers distinguish the initial start from a
      later approval-hook promotion without regex-matching the wave
      index.

  ## Persistence deviation from ADR

  The ADR describes a conceptual `stack_dependencies` shape; the actual
  storage is the JSONB `tasks.dependencies` column already used by the
  broader edge-mutation surface. This module reuses that path and does
  NOT introduce a new table — a future refactor can migrate if needed.

  ## Return shape

    * `{:ok, %{stack, planning, unassigned, edges_authored,
       edges_skipped_reason, waves_total, mode}}` — success. `planning` is
      the list of members this call transitioned to `planning`.
      `unassigned` is the list of members this call REFUSED to transition
      because `dispatchable_planning_assignee?/2` found no agent-typed
      planning assignee for them (per-phase, top-level, or stack-level);
      they stay at `backlog`. The key is always present (`[]` when none),
      so callers need no `Map.get` default. Auto mode gates every wave
      this way; the manual head gates wave 0 the same way (later waves are
      gated in `advance_planning_waves/1`).
      `waves_total` is the total
      number of waves in the stack's DAG (informational; drives the
      progress UI). `mode` is `:manual | :auto`.
    * `{:partial, %{..., errors}}` — cascade partial success; the
      inferred edges are NOT rolled back to match the pre-existing
      partial semantics of the wider cascade family.
    * `{:noop, :already_in_flight}` — idempotency short-circuit.
    * `{:error, :cycle, [Task.t()]}` /
      `{:error, :cross_stack_dep, %{...}}` — invalid DAG; no
      side effects.
    * `{:error, :stack_not_found}` — unknown id.
  """
  @spec start_planning(Stack.t() | binary()) ::
          {:ok,
           %{
             stack: Stack.t(),
             planning: [Task.t()],
             unassigned: [Task.t()],
             edges_authored: non_neg_integer(),
             edges_skipped_reason: atom() | nil,
             waves_total: non_neg_integer(),
             mode: :manual | :auto
           }}
          | {:partial,
             %{
               stack: Stack.t(),
               planning: [Task.t()],
               unassigned: [Task.t()],
               edges_authored: non_neg_integer(),
               edges_skipped_reason: atom() | nil,
               waves_total: non_neg_integer(),
               mode: :manual | :auto,
               errors: [%{task_id: String.t(), target_status: String.t(), reason: term()}]
             }}
          | {:noop, :already_in_flight}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_not_found | term()}
  def start_planning(%Stack{} = stack) do
    members = members(stack)

    with :ok <- require_members_not_quarantined(members) do
      do_start_planning_gate(stack, members)
    end
  end

  def start_planning(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> start_planning(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  defp do_start_planning_gate(%Stack{} = stack, members) do
    if any_member_past_backlog?(members) do
      Logger.info("[Stacks.start_planning] noop for stack=#{stack.id}: already_in_flight")
      emit_planning_noop_telemetry(stack.id, :already_in_flight)

      {:noop, :already_in_flight}
    else
      do_start_planning(stack, members)
    end
  end

  # ── start_planning inner path ──────────────────────────────────────────
  #
  # Split out of the public head so the idempotency short-circuit avoids
  # (a) firing a duplicate `dep_inference` telemetry event, and (b) a
  # duplicate LLM adapter call.
  defp do_start_planning(%Stack{} = stack, members) do
    start_time = System.monotonic_time(:millisecond)

    # Compose with member 1: the dep-inference planner. `infer_and_persist_edges/2`
    # invokes `DepInference.infer_edges/2` (or no-ops when a user override is
    # already present). The `function_exported?/3` guard is a belt-and-braces
    # against future refactors that might extract this into a peer module —
    # today it's inline, so the call is direct.
    {edges_authored, edges_skipped_reason, retry_count} = infer_and_persist_edges(stack, members)
    duration_ms = System.monotonic_time(:millisecond) - start_time

    emit_dep_inference_telemetry(
      stack,
      edges_authored,
      edges_skipped_reason,
      retry_count,
      duration_ms
    )

    # Re-read members so downstream wave computation sees any freshly-written
    # dep edges. Not strictly required for the cascade math (it only
    # inspects `status`), but keeps the returned struct consistent
    # with the post-inference DB state.
    members_for_cascade = if edges_authored > 0, do: members(stack), else: members

    case planning_waves(stack) do
      {:error, :cycle, _path} = err ->
        Logger.info("[Stacks.start_planning] noop for stack=#{stack.id}: cycle")
        emit_planning_noop_telemetry(stack.id, :cycle)
        err

      {:error, :cross_stack_dep, _payload} = err ->
        Logger.info("[Stacks.start_planning] noop for stack=#{stack.id}: cross_stack_dep")
        emit_planning_noop_telemetry(stack.id, :cross_stack_dep)
        err

      {:ok, waves} ->
        mode = if stack.auto_plan, do: :auto, else: :manual

        emit_planning_started_telemetry(
          stack.id,
          mode,
          length(waves),
          length(members_for_cascade)
        )

        dispatch_waves(stack, members_for_cascade, waves, edges_authored, edges_skipped_reason)
    end
  end

  # `any_member_past_backlog?/1` — idempotency check. Members at
  # `backlog` are still eligible for wave dispatch; members at
  # `cancelled` are terminal skips and do not block a fresh dispatch.
  # Everything else (planning, stack_pending, in_progress, in_review,
  # deploying, done, blocked) is treated as "planning already kicked off"
  # for this stack.
  defp any_member_past_backlog?(members) do
    Enum.any?(members, fn %Task{status: status} ->
      status not in ["backlog", "cancelled"]
    end)
  end

  # Manual vs auto branch. Wave 0 dispatch in manual; all-at-once in
  # auto (stage 4 stub — this stage preserves the legacy shape so the
  # plan-approval hook can be exercised end-to-end while stage 4 is
  # still pending).
  defp dispatch_waves(%Stack{auto_plan: true} = stack, members, waves, edges_authored, reason) do
    # Auto mode: fan out EVERY wave in a single pass — no gating on plan
    # approval. Downstream planners still receive `parent_plans` context
    # (empty on the first invocation because no upstream plan is approved
    # yet; a subsequent `advance_planning_waves/1` no-ops because every
    # member has already left `backlog`). Emit one
    # `[:platform, :stacks, :planning, :wave_dispatched]` event per wave
    # with `wave_index: 0..N-1` so telemetry consumers see the same
    # contract as manual mode — just N events fired in one call instead
    # of a single wave-0 event followed by later N-1 advance events.
    #
    # Before any member of a wave transitions, the wave is partitioned on
    # `dispatchable_planning_assignee?/2`. `Tasks.transition_task/2` will
    # happily move a member with no resolvable agent planner into
    # `planning` with `assignee_id: nil`, after which
    # `TaskRouterWatcher.should_run?/1` refuses to start a router and the
    # member is reported as dispatched while nobody is ever called. Such
    # members are NOT transitioned (status stays `backlog`) and are
    # returned under `unassigned:` instead — hard failure over quiet
    # degradation.
    member_by_id = Map.new(members, &{&1.id, &1})

    {reversed_dispatched, errors, reversed_unassigned} =
      waves
      |> Enum.with_index()
      |> Enum.reduce({[], [], []}, fn {wave_members, wave_index},
                                      {ok_acc, err_acc, unassigned_acc} ->
        current_wave =
          Enum.map(wave_members, fn wave_member ->
            Map.get(member_by_id, wave_member.id, wave_member)
          end)

        {dispatchable, wave_unassigned} = partition_wave_by_assignee(current_wave, stack)

        {wave_dispatched, wave_errors} =
          Enum.reduce(dispatchable, {[], []}, fn member, {ok, errs} ->
            member
            |> stamp_stack_planning_assignee(stack)
            |> cascade_member("planning", ok, errs)
          end)

        wave_dispatched = Enum.reverse(wave_dispatched)

        :telemetry.execute(
          [:platform, :stacks, :planning, :wave_dispatched],
          %{member_count: length(wave_dispatched)},
          %{stack_id: stack.id, wave_index: wave_index}
        )

        {Enum.reverse(wave_dispatched, ok_acc), wave_errors ++ err_acc,
         Enum.reverse(wave_unassigned, unassigned_acc)}
      end)

    dispatched = Enum.reverse(reversed_dispatched)
    unassigned = Enum.reverse(reversed_unassigned)

    finalize_dispatch(stack, dispatched, errors, unassigned, waves, edges_authored, reason, :auto)
  end

  defp dispatch_waves(%Stack{} = stack, members, waves, edges_authored, reason) do
    # Manual mode: dispatch ONLY wave 0. Downstream waves advance via
    # `advance_planning_waves/1` when each upstream member's plan lands
    # `approved` (see `Tasks.approve_plan/3` → `maybe_advance_stack_planning/1`).
    #
    # Same gate as the auto head: wave 0 is partitioned on
    # `dispatchable_planning_assignee?/2` before anyone transitions.
    # Members with no resolvable agent planner stay at `backlog` and are
    # returned under `unassigned:`; the rest are stamped with the
    # stack-level default (when that is what resolved them) and
    # transitioned. Later waves get the same treatment in
    # `advance_specific_wave/3`.
    member_by_id = Map.new(members, &{&1.id, &1})

    # `waves` was built against the freshly-read DAG, but member structs
    # it holds carry statuses as of the DAG query. Prefer the `members`
    # list we just read for cascade decisions so the `backlog` guard
    # reflects the current DB state.
    wave0 =
      (List.first(waves) || [])
      |> Enum.map(fn wave_member -> Map.get(member_by_id, wave_member.id, wave_member) end)

    {dispatchable, unassigned} = partition_wave_by_assignee(wave0, stack)

    {dispatched, errors} =
      Enum.reduce(dispatchable, {[], []}, fn member, {ok, errs} ->
        member
        |> stamp_stack_planning_assignee(stack)
        |> cascade_member("planning", ok, errs)
      end)

    dispatched = Enum.reverse(dispatched)

    :telemetry.execute(
      [:platform, :stacks, :planning, :wave_dispatched],
      %{member_count: length(dispatched)},
      %{stack_id: stack.id, wave_index: 0}
    )

    finalize_dispatch(
      stack,
      dispatched,
      errors,
      unassigned,
      waves,
      edges_authored,
      reason,
      :manual
    )
  end

  defp finalize_dispatch(
         stack,
         dispatched,
         errors,
         unassigned,
         waves,
         edges_authored,
         reason,
         mode
       ) do
    report_unassigned(stack, unassigned)

    result = %{
      stack: stack,
      planning: dispatched,
      unassigned: unassigned,
      edges_authored: edges_authored,
      edges_skipped_reason: reason,
      waves_total: length(waves),
      mode: mode
    }

    case errors do
      [] -> {:ok, result}
      errs -> {:partial, Map.put(result, :errors, Enum.reverse(errs))}
    end
  end

  # Split one wave's members into `{dispatchable, unassigned}` using the
  # stage-1 resolver (per-phase entry -> top-level assignee -> stack-level
  # planning default; agent-typed with a non-nil id). Order within each
  # partition is preserved. Pure — no writes.
  defp partition_wave_by_assignee(wave_members, %Stack{} = stack) do
    Enum.split_with(wave_members, &dispatchable_planning_assignee?(&1, stack))
  end

  # `Tasks.transition_task/2` derives `assignee_id` from the member's own
  # `phase_assignees` / top-level assignee only — it never consults the
  # stack-level default. A member that is dispatchable ONLY through the
  # stack fallback would therefore still land in `planning` with a nil
  # `assignee_id`. Stamp the resolved pair onto the member's planning
  # entry first so the transition actually points a router at it. No-op
  # when the member already resolves on its own.
  defp stamp_stack_planning_assignee(%Task{} = member, %Stack{} = stack) do
    case Tasks.assignee_for_phase(member, "planning") do
      {nil, nil} ->
        {id, type} = resolve_planning_assignee(member, stack)

        case Tasks.set_phase_assignees(member, %{
               "planning" => %{"assignee_id" => id, "assignee_type" => type}
             }) do
          {:ok, stamped} -> stamped
          {:error, _} -> member
        end

      _ ->
        member
    end
  end

  defp report_unassigned(_stack, []), do: :ok

  defp report_unassigned(%Stack{id: stack_id}, unassigned) do
    ids = Enum.map(unassigned, & &1.id)

    Logger.warning(
      "[Stacks.start_planning] stack=#{stack_id} members with no dispatchable planning assignee: #{Enum.join(ids, ", ")}"
    )

    :telemetry.execute(
      [:platform, :stacks, :planning, :unassigned],
      %{member_count: length(ids)},
      %{stack_id: stack_id, member_ids: ids}
    )
  end

  @doc """
  Advance a manual-mode stack's planning cascade one wave at a time.

  Called from `Tasks.approve_plan/3` post-commit (see
  `maybe_advance_stack_planning/1`) so approving the last member of the
  highest currently-approved wave immediately dispatches the next
  wave's members into `planning`. Safe to call from operator tools,
  cron sweeps, or manual iex sessions — the function is fully idempotent.

  ## Algorithm

    1. Compute `planning_waves/1`. Pass through cycle / cross-stack-dep
       errors unchanged; on `:stack_not_found` return the tuple.
    2. Find the highest wave N where **every** member has an
       `approved`/`completed` plan (via `Tasks.current_plan/1`).
    3. If wave N+1 exists AND any of its members is still at `backlog`,
       partition the wave on `dispatchable_planning_assignee?/2`.
       Members with a resolvable agent planner transition
       `backlog → planning` via `cascade_member/4` (stack-default-only
       members are stamped first so `assignee_id` is set); the rest are
       refused and stay at `backlog`. Emit
       `[:platform, :stacks, :planning, :wave_dispatched]` and
       `[:platform, :stacks, :planning, :advanced]` with `wave_index: N+1`
       and `member_count` = members actually transitioned (0 when the
       whole wave was refused), plus `:unassigned` + a `Logger.warning`
       when at least one member was refused.
    4. Return `{:ok, %{stack, dispatched, unassigned, wave_index}}` when
       a wave was considered (`unassigned` is always present, `[]` when
       none) or `{:ok, :noop, reason}` when nothing changed. A wave whose
       members are all unassigned and all still at `backlog` is NOT a
       no-op: it returns `dispatched: []` with every member under
       `unassigned`.

  ## No-op reasons

    * `:no_next_wave` — the highest fully-approved wave IS the last
      wave (or the stack is empty).
    * `:next_wave_already_dispatched` — wave N+1 exists but every
      member is already past `backlog`.
    * `:upstream_incomplete` — wave 0 (or wave N) is not yet fully
      approved; the caller re-enters when the next approval lands.
  """
  @spec advance_planning_waves(Stack.t() | binary()) ::
          {:ok,
           %{
             stack: Stack.t(),
             dispatched: [Task.t()],
             unassigned: [Task.t()],
             wave_index: non_neg_integer()
           }}
          | {:ok, :noop, :no_next_wave | :next_wave_already_dispatched | :upstream_incomplete}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_not_found}
  def advance_planning_waves(%Stack{} = stack) do
    with :ok <- require_stack_members_not_quarantined(stack) do
      do_advance_planning_waves(stack)
    end
  end

  def advance_planning_waves(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> advance_planning_waves(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  defp do_advance_planning_waves(%Stack{} = stack) do
    case planning_waves(stack) do
      {:error, _reason, _detail} = err ->
        err

      {:ok, []} ->
        {:ok, :noop, :no_next_wave}

      {:ok, waves} ->
        approved_wave_indices =
          waves
          |> Enum.with_index()
          |> Enum.filter(fn {wave, _idx} -> wave_fully_approved?(wave) end)
          |> Enum.map(fn {_wave, idx} -> idx end)

        highest_approved = List.last(approved_wave_indices)

        next_index =
          case highest_approved do
            nil -> if wave_fully_approved?(List.first(waves)), do: 1, else: 0
            n -> n + 1
          end

        cond do
          highest_approved == nil and next_index == 0 ->
            # Wave 0 not yet fully approved — nothing to advance.
            {:ok, :noop, :upstream_incomplete}

          next_index >= length(waves) ->
            {:ok, :noop, :no_next_wave}

          true ->
            advance_specific_wave(stack, Enum.at(waves, next_index), next_index)
        end
    end
  end

  defp advance_specific_wave(stack, wave_members, wave_index) do
    # Re-read the wave members so `cascade_member/4`'s `backlog` guard
    # sees the current DB state — the `planning_waves/1` result may be
    # a few tens of ms stale by the time this fires from a post-commit
    # hook.
    fresh_members =
      Enum.map(wave_members, fn %Task{id: id} ->
        Repo.get(Task, id) || %Task{id: id, status: "unknown"}
      end)

    if Enum.all?(fresh_members, &(&1.status != "backlog")) do
      {:ok, :noop, :next_wave_already_dispatched}
    else
      # Same gate as `dispatch_waves/5`: only members with a resolvable
      # agent planner transition. The rest stay at `backlog` and come
      # back under `unassigned:` with the `:unassigned` warning +
      # telemetry. Note this runs AFTER the already-dispatched
      # short-circuit above, so a wave that is entirely unassigned and
      # entirely at `backlog` is NOT a no-op: it is reported as advanced
      # with `dispatched: []` and every member listed as refused.
      {dispatchable, unassigned} = partition_wave_by_assignee(fresh_members, stack)

      {dispatched, _errs} =
        Enum.reduce(dispatchable, {[], []}, fn member, {ok, errs} ->
          member
          |> stamp_stack_planning_assignee(stack)
          |> cascade_member("planning", ok, errs)
        end)

      dispatched = Enum.reverse(dispatched)
      report_unassigned(stack, unassigned)

      :telemetry.execute(
        [:platform, :stacks, :planning, :wave_dispatched],
        %{member_count: length(dispatched)},
        %{stack_id: stack.id, wave_index: wave_index}
      )

      # Stack v2 stage 6: distinguish advance-driven promotions from the
      # initial start_planning dispatch. Both fire :wave_dispatched
      # (backwards-compatible); only advance_planning_waves fires
      # :advanced. Downstream observers that need to count "how many
      # promotions happened after the initial start" attach to
      # :advanced without regex-parsing wave indices.
      :telemetry.execute(
        [:platform, :stacks, :planning, :advanced],
        %{member_count: length(dispatched)},
        %{stack_id: stack.id, wave_index: wave_index}
      )

      # Stage 4 backstop: audit reserved slots AFTER the wave has been
      # dispatched, purely as an observability signal. This is
      # deliberately log-only — a collision here means the reservation
      # machinery was bypassed (detection-regex miss, hand-authored
      # plan, executor ignoring the prompt), and blocking the wave on a
      # backstop would turn a CI-visible problem into a silently stuck
      # stack. Loud beats stuck.
      audit_migration_slots_for_log(stack)

      {:ok,
       %{stack: stack, dispatched: dispatched, unassigned: unassigned, wave_index: wave_index}}
    end
  end

  # Never allowed to affect wave dispatch: the audit runs after the
  # dispatch decision is final, and any failure inside it is swallowed.
  defp audit_migration_slots_for_log(%Stack{} = stack) do
    case audit_migration_slots(stack) do
      {:error, :collision, offenders} ->
        Logger.error(
          "[Stacks] migration slot collision detected in stack=#{stack.id}: " <>
            "#{inspect(offenders)}"
        )

        :telemetry.execute(
          [:platform, :stacks, :migration_slot, :collision],
          %{count: length(offenders)},
          %{stack_id: stack.id, offenders: offenders}
        )

      _ ->
        :ok
    end
  rescue
    error ->
      Logger.warning(
        "[Stacks] migration slot audit raised for stack=#{stack.id}: #{inspect(error)}"
      )

      :ok
  end

  # A wave is "fully approved" when every member's `current_plan/1`
  # returns an approved/completed plan.
  defp wave_fully_approved?([]), do: true

  defp wave_fully_approved?(members) do
    Enum.all?(members, fn %Task{id: id} ->
      not is_nil(Tasks.current_plan(id))
    end)
  end

  # ── Dep inference helpers ─────────────────────────────────────────────

  # Returns `{edges_authored, edges_skipped_reason, retry_count}`.
  #   * `{n, nil, r}` — inference ran, n edges committed, r retries used
  #   * `{0, :user_override_present, 0}` — pre-existing in-stack edge, skipped
  #   * `{0, :cycle | :parse_failed | :adapter_failed | :empty_response, r}`
  #     — inference (and retry) failed terminally; cascade still proceeds.
  defp infer_and_persist_edges(_stack, []), do: {0, nil, 0}

  defp infer_and_persist_edges(%Stack{} = stack, members) do
    if any_in_stack_edge_present?(members, stack.id) do
      {0, :user_override_present, 0}
    else
      attempt_inference(stack, members, 0)
    end
  end

  # `attempt` counter guards the single-shot cycle retry. `0` = first
  # attempt, `1` = retry after cycle. Returns
  # `{edges_authored, reason_or_nil, cumulative_retry_count}`.
  defp attempt_inference(stack, members, attempt) do
    case try_infer_with_retry(stack, members) do
      {:ok, edges, adapter_retries} ->
        case commit_edges(stack, edges) do
          {:ok, count} ->
            {count, nil, adapter_retries + attempt}

          {:error, :cycle} when attempt == 0 ->
            Logger.warning(
              "[Stacks.start_planning] cycle detected in inferred edges (stack #{stack.id}); retrying once"
            )

            attempt_inference(stack, members, 1)

          {:error, :cycle} ->
            Logger.warning(
              "[Stacks.start_planning] cycle detected on retry (stack #{stack.id}); dropping inferred edges"
            )

            {0, :cycle, adapter_retries + attempt}
        end

      {:error, reason, adapter_retries} ->
        Logger.warning(
          "[Stacks.start_planning] dep inference terminal failure (stack #{stack.id}, reason=#{reason})"
        )

        {0, reason, adapter_retries + attempt}
    end
  end

  # `DepInference.infer_edges/2` plus a single retry on parse/adapter
  # failure. Empty-response and terminal errors bubble up as-is.
  # Returns `{:ok, edges, retries}` / `{:error, reason, retries}` where
  # `retries` is 0 when the first call succeeded / bubbled, 1 when a
  # single retry fired.
  defp try_infer_with_retry(stack, members) do
    case DepInference.infer_edges(stack, members) do
      {:ok, edges} ->
        {:ok, edges, 0}

      {:error, reason} when reason in [:parse_failed, :adapter_failed] ->
        case DepInference.infer_edges(stack, members) do
          {:ok, edges} -> {:ok, edges, 1}
          {:error, reason2} -> {:error, reason2, 1}
        end

      {:error, reason} ->
        {:error, reason, 0}
    end
  end

  # Sequentially write edges via `add_dependency_edge/4`. On the first
  # `{:error, :cycle, _}`, revert already-committed inference edges via
  # `remove_dependency_edge/4` and return `{:error, :cycle}` so the
  # caller can retry inference. Non-cycle write errors (duplicate edge,
  # cross-stack dep, etc.) are logged and skipped — the caller's edge
  # count reflects only what actually landed.
  defp commit_edges(stack, edges) do
    Enum.reduce_while(edges, {:ok, 0, []}, fn edge, {:ok, count, committed} ->
      case add_dependency_edge(stack, edge.from_task_id, edge.to_task_id) do
        {:ok, _} ->
          {:cont, {:ok, count + 1, [edge | committed]}}

        {:error, :cycle, _path} ->
          revert_edges(stack, committed)
          {:halt, {:error, :cycle}}

        {:error, other} ->
          Logger.warning(
            "[Stacks.start_planning] skipping inferred edge #{edge.from_task_id}->#{edge.to_task_id}: #{inspect(other)}"
          )

          {:cont, {:ok, count, committed}}

        {:error, other, _payload} ->
          Logger.warning(
            "[Stacks.start_planning] skipping inferred edge #{edge.from_task_id}->#{edge.to_task_id}: #{inspect(other)}"
          )

          {:cont, {:ok, count, committed}}
      end
    end)
    |> case do
      {:ok, count, _committed} -> {:ok, count}
      {:error, :cycle} -> {:error, :cycle}
    end
  end

  defp revert_edges(stack, edges) do
    Enum.each(edges, fn edge ->
      _ = remove_dependency_edge(stack, edge.from_task_id, edge.to_task_id)
    end)
  end

  # Fire dep-inference telemetry after the inference/persist stage
  # finishes. Downstream aggregation (Prometheus, LiveDashboard) can
  # subscribe to `[:platform, :stacks, *]` globs; we deliberately do NOT
  # attach a handler here — telemetry is fire-and-forget at emit time.
  #
  # Two events:
  #   * `:computed` — inference ran (successfully OR was skipped due to
  #     a pre-existing user override). Measurements include `edges_count`
  #     and `duration_ms`; metadata carries `source` = `:agent` for a
  #     real inference call, `:user_override_skip` for the idempotency
  #     short-circuit.
  #   * `:failed` — terminal failure after any retry: :cycle,
  #     :parse_failed, :adapter_failed, :empty_response. Measurements
  #     carry `duration_ms`; metadata carries the terminal `reason`.
  defp emit_dep_inference_telemetry(stack, edges_authored, reason, retry_count, duration_ms) do
    case reason do
      nil ->
        :telemetry.execute(
          [:platform, :stacks, :dep_inference, :computed],
          %{edges_count: edges_authored, duration_ms: duration_ms},
          %{stack_id: stack.id, retry_count: retry_count, source: :agent}
        )

      :user_override_present ->
        :telemetry.execute(
          [:platform, :stacks, :dep_inference, :computed],
          %{edges_count: 0, duration_ms: duration_ms},
          %{stack_id: stack.id, retry_count: 0, source: :user_override_skip}
        )

      terminal ->
        :telemetry.execute(
          [:platform, :stacks, :dep_inference, :failed],
          %{duration_ms: duration_ms},
          %{stack_id: stack.id, reason: terminal, retry_count: retry_count}
        )
    end
  end

  # Stack v2 stage 6 — planning-lifecycle telemetry helpers.
  #
  # `:started` fires exactly once per dispatching `start_planning/1`
  # call, immediately after DAG validation and before the first wave
  # fans out. `member_count` is the total member count (all-mode); a
  # per-wave count still lives on `:wave_dispatched`.
  defp emit_planning_started_telemetry(stack_id, mode, waves_total, member_count) do
    :telemetry.execute(
      [:platform, :stacks, :planning, :started],
      %{member_count: member_count},
      %{stack_id: stack_id, mode: mode, waves_total: waves_total}
    )
  end

  # `:noop` fires when `start_planning/1` short-circuits without
  # dispatching a wave — the idempotency guard (`:already_in_flight`),
  # or the cycle / cross-stack DAG guards.
  defp emit_planning_noop_telemetry(stack_id, reason) do
    :telemetry.execute(
      [:platform, :stacks, :planning, :noop],
      %{},
      %{stack_id: stack_id, reason: reason}
    )
  end

  # Returns true if any member already has a `dependencies` entry whose
  # `task_id` is another same-stack member's id — the signal that
  # something (user, prior invocation) has already authored an in-stack
  # edge and inference should be skipped for idempotency.
  @spec any_in_stack_edge_present?([Task.t()], binary()) :: boolean()
  defp any_in_stack_edge_present?(members, _stack_id) do
    member_ids = MapSet.new(members, & &1.id)

    Enum.any?(members, fn %Task{id: id, dependencies: deps} ->
      deps
      |> List.wrap()
      |> Enum.any?(fn
        %{"task_id" => task_id} when is_binary(task_id) ->
          task_id != id and MapSet.member?(member_ids, task_id)

        _ ->
          false
      end)
    end)
  end

  @doc """
  Terminal transition: mark a stack `abandoned`, record the reason, and
  release every live member.

  Per ADR 0041 (Lifecycle / Rollback / abandon) and the product ruling on
  task 01a05393 (Moore, 2026-08-30 18:35): membership (`stack_id` and
  `stack_position`) is cleared ONLY on members this sweep demotes. Members
  whose status is kept also keep their membership:

  | member                                             | status     | membership |
  |----------------------------------------------------|------------|------------|
  | landed on rollup (`member_landed_on_rollup?/1`)    | untouched  | kept       |
  | `done` / `cancelled` / `in_review` w/o stamp, `blocked` | untouched | kept   |
  | `stack_pending` / `planning` / `backlog`           | `backlog`  | cleared    |
  | `in_progress`                                      | `blocked`  | cleared    |

  Why: the members whose work reached the rollup are the only durable record
  of what that branch contains; nulling their `stack_id` would make
  `stack_get` on the abandoned stack return no members. Demoted members go
  back to the solo pipeline and must not be re-swept or re-gated, so clearing
  is correct there.

  `in_progress -> blocked` is the ticket's "the executor must stop" ask,
  expressed in the EXISTING `@valid_task_transitions` vocabulary rather than
  a new blocker subsystem. Both `stack_pending -> backlog` and
  `planning -> backlog` are in that map (`Platform.Tasks`, `@valid_task_transitions`)
  — verified, not assumed. A member already AT `backlog` is left alone,
  because an identity transition is refused by that same map.

  Soft-deleted members are excluded (`is_nil(deleted_at)`): they are already
  invisible to `members/1`, and touching them would resurrect state no caller
  can see.

  The per-member sweep runs AFTER the stack row commits, and is
  reduce-and-drop: one member failing to transition never aborts the sweep
  over the others, and never rolls back the `abandoned` write. Running it
  post-commit also keeps `recompute_stack_status/1` — which
  `transition_task/2` fires as a status hook — from observing a pre-commit
  stack row.

  `recompute_stack_status/1` is deliberately NOT called from this path: the
  stack is already terminal and recompute would fight the `abandoned` write.

  Refuses a `done` stack with `{:error, :invalid_stack_status}` — the same
  term `start_stack/1` returns — without touching the row. Abandoning shipped
  work would flip `done` to `abandoned` and re-run the member sweep over
  tasks that already landed; the caller who wants one member out of a
  finished stack has `eject_task/2`.
  """
  @spec abandon_stack(Stack.t(), String.t() | nil) ::
          {:ok, Stack.t()} | {:error, :invalid_stack_status | Ecto.Changeset.t()}
  def abandon_stack(stack, reason \\ nil)

  def abandon_stack(%Stack{status: "done"}, _reason), do: {:error, :invalid_stack_status}

  def abandon_stack(%Stack{} = stack, reason) do
    attrs = %{status: "abandoned", description: abandon_description(stack, reason)}

    result =
      Repo.transaction(fn ->
        case stack |> Stack.changeset(attrs) |> Repo.update() do
          {:ok, abandoned} -> abandoned
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, %Stack{} = abandoned} ->
        _released = abandon_members(abandoned)
        {:ok, abandoned}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Release every live member of a now-abandoned stack. Query shape mirrors
  # `pending_members/1`; the reducer mirrors `sweep_stack_pending_members/0`
  # so one raising or refusing member never strands the rest.
  #
  # Returns the count of members whose membership clear succeeded.
  @spec abandon_members(Stack.t()) :: non_neg_integer()
  defp abandon_members(%Stack{id: stack_id}) do
    Task
    |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
    |> Repo.all()
    |> Enum.reduce(0, fn member, acc ->
      case safe_abandon_member(member) do
        {:ok, _updated} -> acc + 1
        _ -> acc
      end
    end)
  end

  defp safe_abandon_member(%Task{} = member) do
    abandon_member(member)
  rescue
    e ->
      Logger.warning(
        "[Stacks.abandon_stack] releasing member #{member.id} raised: " <>
          Exception.message(e)
      )

      :error
  end

  # Route the member's status, and clear its membership ONLY on the demote
  # path. A `:keep_status` member (landed on the rollup, unstamped
  # done/cancelled/in_review, blocked) keeps `stack_id` / `stack_position`
  # so the abandoned stack still lists what reached its branch. On the
  # demote path the clear runs even when the transition was refused, so an
  # invalid-transition refusal can never leave a demoted task pointing at an
  # abandoned stack.
  defp abandon_member(%Task{} = member) do
    case abandon_member_target(member) do
      {:transition, target} when target != member.status ->
        routed =
          case Tasks.transition_task(member, target) do
            {:ok, updated} ->
              updated

            {:error, reason} ->
              Logger.warning(
                "[Stacks.abandon_stack] member #{member.id} refused " <>
                  "#{member.status} -> #{target}: #{inspect(reason)}; " <>
                  "clearing membership anyway"
              )

              member
          end

        Tasks.update_task(routed, %{stack_id: nil, stack_position: nil})

      _ ->
        {:ok, member}
    end
  end

  # The routing decision, isolated so it is one matchable expression.
  # See the routing table in `abandon_stack/2`'s @doc.
  @spec abandon_member_target(Task.t()) :: :keep_status | {:transition, String.t()}
  defp abandon_member_target(%Task{} = member) do
    cond do
      member_landed_on_rollup?(member) -> :keep_status
      member.status in ["stack_pending", "planning", "backlog"] -> {:transition, "backlog"}
      member.status == "in_progress" -> {:transition, "blocked"}
      true -> :keep_status
    end
  end

  defp abandon_description(%Stack{description: existing}, nil), do: existing

  defp abandon_description(%Stack{description: nil}, reason) when is_binary(reason),
    do: "Abandoned: #{reason}"

  defp abandon_description(%Stack{description: existing}, reason) when is_binary(reason),
    do: "#{existing}\n\nAbandoned: #{reason}"

  @doc """
  Terminal transition: mark a stack `done`.

  Only allowed when every *live* member task is already `done`. The natural
  close for a stack whose work has fully shipped — including the manual-ship
  lane where members merged via individual PRs rather than the rollup branch,
  which `recompute_stack_status/1` doesn't recognize as completion.

  Soft-deleted members do not count. They are already absent from `members/1`,
  so counting them here would block on a task no caller can see, name or reach.

  Returns `{:error, :members_not_done, %{pending: [%{id, title, status}]}}`
  when any member is still in flight. Returns `{:error, changeset}` on a
  schema-level write failure. Returns `{:ok, stack}` on success.

  Refuses an `abandoned` stack with `{:error, :invalid_stack_status}` — the
  same term `start_stack/1` returns — before the member check runs and
  without touching the row. `abandoned` is terminal; `abandon_stack/2` has
  already released the members, so "every member is done" can be true of a
  stack nobody shipped.
  """
  @spec complete_stack(Stack.t(), String.t() | nil) ::
          {:ok, Stack.t()}
          | {:error, :members_not_done, %{pending: [map()]}}
          | {:error, :invalid_stack_status | Ecto.Changeset.t()}
  def complete_stack(stack, note \\ nil)

  def complete_stack(%Stack{status: "abandoned"}, _note), do: {:error, :invalid_stack_status}

  def complete_stack(%Stack{} = stack, note) do
    case pending_members(stack.id) do
      [] ->
        attrs = %{status: "done", description: complete_description(stack, note)}

        stack
        |> Stack.changeset(attrs)
        |> Repo.update()

      [_ | _] = pending ->
        {:error, :members_not_done, %{pending: pending}}
    end
  end

  # The `is_nil(t.deleted_at)` clause is load-bearing and matches `members/1`
  # at the bottom of this module. Deletion is soft everywhere
  # (`Tasks.soft_delete_task/1` is the only delete path a task has), so a
  # deleted member keeps both its `stack_id` and its non-`done` status. Without
  # the filter this query counts a row that no read surface will ever show
  # again, and the stack can never satisfy "every member is done" — permanently,
  # since `stack_update` cannot set status and `eject_task/2` needs an id the
  # caller has no way to learn. Stack `019fd80f-531e-7dab-ab61-c26c2e4748ba`
  # froze in `deploying` exactly this way, with all four surviving members done
  # and a gap at stack_position 3 as the only visible trace.
  defp pending_members(stack_id) do
    Task
    |> where(
      [t],
      t.stack_id == ^stack_id and t.status not in ^MemberSet.excluded_statuses() and
        is_nil(t.deleted_at)
    )
    |> select([t], %{id: t.id, title: t.title, status: t.status})
    |> Repo.all()
  end

  defp complete_description(%Stack{description: existing}, nil), do: existing

  defp complete_description(%Stack{description: nil}, note) when is_binary(note),
    do: "Completed: #{note}"

  defp complete_description(%Stack{description: existing}, note) when is_binary(note),
    do: "#{existing}\n\nCompleted: #{note}"

  # ── Membership ───────────────────────────────────────────────────────────

  @doc """
  Attach a task to a stack as a new member.

  Loads the stack and task fresh inside a transaction. Rejects with
  `{:error, :already_in_stack}` if the task is already attached to any
  stack. Computes the next `stack_position` as `max(existing) + 1`
  (starting at 1) and writes via `Platform.Tasks.update_task/2` so the
  existing changeset + broadcast pipeline runs.

  After the write, runs `validate_dag/1` against the augmented member
  set; on `:cycle` or `:cross_stack_dep` the transaction is rolled back
  and the error tuple is returned unchanged. On success, calls
  `recompute_stack_status/1` and returns `{:ok, task}`.

  ## Stack-level assignment inheritance (ADR 0041)

  If the stack has a stack-level `phase_assignees` map AND the joining
  task is NOT individually overridden (`task.metadata["assignee_override"]`
  is not `true`), the stack default is applied to the new member via
  `Platform.Tasks.set_phase_assignees/2` inside this transaction (after
  the `stack_id` write, before `recompute_stack_status/1`). A task that
  carries its own `assignee_override` flag keeps its own assignment.

  ## Adding to a stack that has already commenced (task 01a05393 stage 4)

  A stack whose status is `done` or `abandoned` refuses new members with
  `{:error, :stack_terminal, %{stack_status: status}}`.

  A stack whose status is anything other than `forming` has already
  commenced. A member added at that point arrives with no plan, so
  `CommencementGate.plans_ready?/1` goes false for the WHOLE stack and
  every sibling's `open?/1` re-closes until the newcomer's plan is
  approved. Rather than leave the newcomer at `backlog` (where the
  dispatcher would try to route it as if it were a solo task), it is
  parked at `stack_pending` in the same `Tasks.update_task/2` write, and
  `add_task_with_report/3` returns a warning naming the consequence.
  `add_task/2` and `add_task/3` keep the bare `{:ok, task}` contract;
  callers that want the warning use `add_task_with_report/3`.

  The status write goes through `Tasks.update_task/2`, whose
  `Task.changeset/2` casts `:status` with only an inclusion check (no
  transition table), so the direct `backlog -> stack_pending` write is
  accepted; the same edge is also listed in
  `Platform.Tasks.valid_task_transitions/0` for the guarded path.
  """
  @spec add_task(Stack.t() | binary(), Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error, :already_in_stack | :stack_not_found | :task_not_found | term()}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_terminal, %{stack_status: String.t()}}
  def add_task(stack_or_id, task_or_id), do: add_task(stack_or_id, task_or_id, [])

  @doc """
  `add_task/2` with an `opts` keyword list. See `add_task_with_report/3`
  for the accepted options. Returns the same `{:ok, task}` shape as
  `add_task/2`, dropping the report.
  """
  @spec add_task(Stack.t() | binary(), Task.t() | binary(), keyword()) ::
          {:ok, Task.t()}
          | {:error, :already_in_stack | :stack_not_found | :task_not_found | term()}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_terminal, %{stack_status: String.t()}}
  def add_task(stack_or_id, task_or_id, opts) when is_list(opts) do
    case add_task_with_report(stack_or_id, task_or_id, opts) do
      {:ok, %Task{} = task, _report} -> {:ok, task}
      other -> other
    end
  end

  @typedoc """
  What `add_task_with_report/3` says about the commencement gate after
  the add.

    * `gate_closed` — `true` only when the stack had already commenced
      and the newcomer was parked at `stack_pending`; the gate is closed
      for every sibling until the newcomer's plan is approved. `false`
      on a `forming` stack (the gate was never open, nothing changed).
    * `waiting_on` — `CommencementGate.waiting_on/1` for the stack after
      the write when `gate_closed` is `true`; `[]` otherwise.
    * `warning` — a sentence naming the consequence when `gate_closed`
      is `true`; `nil` otherwise.
  """
  @type add_task_report :: %{
          warning: String.t() | nil,
          gate_closed: boolean(),
          waiting_on: [String.t()]
        }

  @doc """
  `add_task/3` that also reports the effect on the commencement gate.

  Returns `{:ok, task, report}` where `report` is an `t:add_task_report/0`.
  Errors are the same as `add_task/2`.

  `opts` is currently reserved (no keys are read); it exists so the
  arity is stable when stage 5 of task 01a05393 adds the re-drive.
  """
  @spec add_task_with_report(Stack.t() | binary(), Task.t() | binary(), keyword()) ::
          {:ok, Task.t(), add_task_report()}
          | {:error, :already_in_stack | :stack_not_found | :task_not_found | term()}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_terminal, %{stack_status: String.t()}}
  def add_task_with_report(stack_or_id, task_or_id, opts \\ []) when is_list(opts) do
    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_stack_accepts_members(stack),
             {:ok, %Task{} = task} <- load_task(task_or_id),
             :ok <- ensure_not_in_stack(task),
             position = next_stack_position(stack.id),
             attrs = add_task_attrs(stack, position),
             {:ok, attached_task} <- Tasks.update_task(task, attrs),
             {:ok, updated_task} <- maybe_inherit_stack_assignees(stack, attached_task),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          {updated_task, add_task_report(stack, updated_task)}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    # `validate_dag/1`'s richer 3-tuple errors are stuffed into a
    # 2-tuple shape on the way into `Repo.rollback/1` so the `with`
    # chain stays uniform; unpack them here so callers see the
    # original `{:error, :cycle, path}` / `{:error, :cross_stack_dep,
    # payload}` shape without wrapping. `:stack_terminal` rides the
    # same bridge.
    case txn do
      {:ok, {task, report}} -> {:ok, task, report}
      {:error, {:cycle, path}} -> {:error, :cycle, path}
      {:error, {:cross_stack_dep, payload}} -> {:error, :cross_stack_dep, payload}
      {:error, {:stack_terminal, payload}} -> {:error, :stack_terminal, payload}
      other -> other
    end
  end

  @stack_terminal_statuses ~w(done abandoned)

  defp ensure_stack_accepts_members(%Stack{status: status})
       when status in @stack_terminal_statuses,
       do: {:error, {:stack_terminal, %{stack_status: status}}}

  defp ensure_stack_accepts_members(%Stack{}), do: :ok

  # A `forming` stack has not commenced: the newcomer stays at its own
  # status (normally `backlog`) and goes through planning with the rest.
  # Any other status means the stack has commenced, and the newcomer is
  # parked at `stack_pending` in the same write as the membership.
  defp add_task_attrs(%Stack{status: "forming"} = stack, position),
    do: %{stack_id: stack.id, stack_position: position}

  defp add_task_attrs(%Stack{} = stack, position),
    do: %{stack_id: stack.id, stack_position: position, status: "stack_pending"}

  defp add_task_report(%Stack{status: "forming"}, %Task{}),
    do: %{warning: nil, gate_closed: false, waiting_on: []}

  defp add_task_report(%Stack{} = stack, %Task{} = task) do
    waiting_on = CommencementGate.waiting_on(stack)

    %{
      warning:
        "Stack #{stack.id} had already commenced (status #{stack.status}). " <>
          "Task #{task.id} joined with no approved plan, so the stack's commencement gate " <>
          "is closed for EVERY member until this task's plan is approved: no sibling can be " <>
          "promoted from stack_pending to in_progress while CommencementGate.waiting_on/1 " <>
          "is non-empty (currently #{length(waiting_on)} member(s)). The new task was parked " <>
          "at stack_pending, which the task router does not treat as active, so it is " <>
          "invisible to dispatch until it is promoted.",
      gate_closed: true,
      waiting_on: waiting_on
    }
  end

  # Bridge `validate_dag/1`'s 3-tuple errors into the `with` chain's
  # 2-tuple convention so they roll back the transaction. Unwrapped
  # back into the original 3-tuple after `Repo.transaction/1` returns.
  defp normalize_dag_result({:ok, levels}), do: {:ok, levels}
  defp normalize_dag_result({:error, :cycle, path}), do: {:error, {:cycle, path}}

  defp normalize_dag_result({:error, :cross_stack_dep, payload}),
    do: {:error, {:cross_stack_dep, payload}}

  @doc """
  Detach a task from its stack.

  Returns `{:error, :not_in_stack}` when the task's `stack_id` does not
  match the supplied stack. Before clearing, computes which other
  members of the stack depend on this task (in-stack edges only) and
  refuses with `{:error, {:has_dependents, [%{id, title}]}}` if any
  exist.

  On a clean eject, clears `stack_id` and `stack_position` via
  `Platform.Tasks.update_task/2`. Per ADR 0041, the member's `status` is
  left as-is — the caller decides what to do with it — with ONE
  exception: a member at `stack_pending` is transitioned to `backlog`
  first (via `Platform.Tasks.transition_task/2`). `stack_pending` is a
  status only the stack's own promotion sweep can leave, and
  `sweep_stack_pending_members/0` scans members by `stack_id`; clearing
  the id would put the task somewhere no sweep and no watcher will ever
  pick it up again. Every other status (including `in_progress`,
  `blocked`, `done`) is untouched. After the write, calls
  `recompute_stack_status/1` and returns `{:ok, task}`.
  """
  @spec eject_task(Stack.t() | binary(), Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error,
             :not_in_stack
             | :stack_not_found
             | :task_not_found
             | {:has_dependents, [%{id: String.t(), title: String.t()}]}
             | term()}
  def eject_task(stack_or_id, task_or_id) do
    Repo.transaction(fn ->
      with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
           {:ok, %Task{} = task} <- load_task(task_or_id),
           :ok <- ensure_in_stack(stack, task),
           :ok <- ensure_no_in_stack_dependents(stack, task),
           {:ok, task} <- demote_if_stack_pending(task),
           {:ok, updated_task} <-
             Tasks.update_task(task, %{stack_id: nil, stack_position: nil}),
           {:ok, _stack} <- recompute_stack_status(stack) do
        updated_task
      else
        # `eject_task` predates the 3-tuple `:not_in_stack` shape and its
        # callers (incl. existing tests + the `stack_eject` MCP envelope at
        # tool_surface.ex:2776) match on the bare 2-tuple. Collapse here so
        # the new shape stays scoped to the dependency-edge surfaces.
        {:error, :not_in_stack, _task_id} -> Repo.rollback(:not_in_stack)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The one status-scoped exception to "eject leaves status as-is". A
  # `stack_pending` member with no `stack_id` is parked forever: the
  # promotion sweep cannot see it and `TaskRouterWatcher` never treats the
  # status as active. `stack_pending -> backlog` is in
  # `Platform.Tasks`' `@valid_task_transitions`. Every other status falls
  # through untouched — the decision is this single head, nothing wider.
  @spec demote_if_stack_pending(Task.t()) :: {:ok, Task.t()} | {:error, term()}
  defp demote_if_stack_pending(%Task{status: "stack_pending"} = task),
    do: Tasks.transition_task(task, "backlog")

  defp demote_if_stack_pending(%Task{} = task), do: {:ok, task}

  @doc """
  Add an in-stack dependency edge from `from_task_id` to `to_task_id`.

  Mirrors the `add_task/2` shape: loads the stack and both endpoint tasks
  fresh inside a `Repo.transaction`, runs membership/self guards
  up-front, delegates to `Platform.Tasks.add_dependency/3` (stage 1 of
  this skill) for the JSONB read-modify-write, then runs
  `validate_dag/1` against the now-augmented edge set so multi-hop
  cycles get caught and the dep write is rolled back atomically when
  they're found.

  `opts` accepts `:kind` (default `"blocks"`).

  ## Up-front guards

    * `{:error, :stack_not_found}` — the stack id has no row
    * `{:error, :task_not_found}` — either endpoint id has no row
    * `{:error, :self_edge}` — `from_task_id == to_task_id`
    * `{:error, :not_in_stack, offending_task_id}` — one endpoint's
      `stack_id` does not match the supplied stack id (covers both "not
      in any stack" and "member of a different stack" — `validate_dag/1`
      would also flag cross-stack deps, but the explicit membership
      check is a cleaner up-front signal for an explicitly stack-scoped
      tool). The id of the offending endpoint is threaded out so MCP
      callers can render it in error envelopes without a follow-up
      lookup.

  ## Errors bubbled from stage 1 unchanged

    * `{:error, :duplicate_edge}` — the same `(to_task_id, kind)` pair
      already exists on `from_task`
    * `{:error, :self_edge}` — same condition as the up-front guard,
      defensively repeated by `Tasks.add_dependency/3`

  ## Errors from DAG validation (transaction rolled back)

    * `{:error, :cycle, path}` — the new edge introduces a cycle in the
      in-stack subgraph; the dep write is undone before returning.
    * `{:error, :dependent_already_started, %{task_id, status}}` — the
      dependent (`from_task_id`) is already at `in_progress`, `in_review`,
      `deploying` or `done`. A member that has already started cannot
      retroactively acquire a predecessor: nothing in the engine would
      enforce the new edge (the promote gate only looks at `stack_pending`
      members), so the edge would be advisory at best and misleading at
      worst. `backlog`, `planning`, `stack_pending`, `blocked` and
      `cancelled` dependents are still accepted — for a `stack_pending`
      dependent the edge simply adds one more unmet dep.

  Returns `{:ok, %{from_task_id, to_task_id, kind, executable_now}}` on
  success, where `executable_now` is the recomputed
  `executable_members/1` id list so callers don't need a follow-up
  `stack_get` to see the new ready set.
  """
  @spec add_dependency_edge(Stack.t() | binary(), binary(), binary(), keyword()) ::
          {:ok,
           %{
             from_task_id: binary(),
             to_task_id: binary(),
             kind: String.t(),
             executable_now: [binary()]
           }}
          | {:error, :stack_not_found | :task_not_found | :self_edge}
          | {:error, :not_in_stack, binary()}
          | {:error, :duplicate_edge}
          | {:error, :cycle, [Task.t()]}
          | {:error, :dependent_already_started, %{task_id: binary(), status: String.t()}}
          | {:error, term()}
  def add_dependency_edge(stack_or_id, from_task_id, to_task_id, opts \\ [])
      when is_binary(from_task_id) and is_binary(to_task_id) do
    kind = Keyword.get(opts, :kind, "blocks")

    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_distinct_endpoints(from_task_id, to_task_id),
             {:ok, %Task{} = from_task} <- load_task(from_task_id),
             {:ok, %Task{} = to_task} <- load_task(to_task_id),
             :ok <- ensure_in_stack(stack, from_task),
             :ok <- ensure_in_stack(stack, to_task),
             :ok <- ensure_dependent_not_started(from_task),
             {:ok, _updated_from} <- Tasks.add_dependency(from_task, to_task_id, kind),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          %{
            from_task_id: from_task_id,
            to_task_id: to_task_id,
            kind: kind,
            executable_now: stack |> executable_members() |> Enum.map(& &1.id)
          }
        else
          {:error, :not_in_stack, task_id} ->
            Repo.rollback({:not_in_stack, task_id})

          {:error, :dependent_already_started, payload} ->
            Repo.rollback({:dependent_already_started, payload})

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case txn do
      {:error, {:cycle, path}} ->
        {:error, :cycle, path}

      {:error, {:cross_stack_dep, payload}} ->
        {:error, :cross_stack_dep, payload}

      {:error, {:not_in_stack, task_id}} ->
        {:error, :not_in_stack, task_id}

      {:error, {:dependent_already_started, payload}} ->
        {:error, :dependent_already_started, payload}

      other ->
        other
    end
  end

  @started_dependent_statuses ~w(in_progress in_review deploying done)

  defp ensure_dependent_not_started(%Task{status: status} = task)
       when status in @started_dependent_statuses,
       do: {:error, :dependent_already_started, %{task_id: task.id, status: status}}

  defp ensure_dependent_not_started(%Task{}), do: :ok

  @doc """
  Remove an in-stack dependency edge from `from_task_id` to `to_task_id`.

  Mirrors `add_dependency_edge/4` — same membership/self guards,
  delegates to `Platform.Tasks.remove_dependency/3` for the JSONB
  read-modify-write, and runs `validate_dag/1` defensively (removal
  cannot create a cycle, but the cheap re-validation keeps the
  recomputed-status path identical to the add side).

  `opts` accepts `:kind` (default `"blocks"`).

  Returns `{:error, :not_an_edge}` when no `(to_task_id, kind)` entry
  exists on `from_task` (so callers can disambiguate an idempotent
  re-remove from a successful one). All other guards match the add
  side.

  Once the edge removal has COMMITTED, the freed dependent (`from_task_id`)
  is reloaded and handed to `try_promote/1` synchronously in this same
  call, so a `stack_pending` member whose last unmet predecessor was just
  removed moves to `in_progress` here rather than waiting for the periodic
  `sweep_stack_pending_members/0`. The promoted ids are returned under
  `promoted` (`[]` when nothing moved).

  The promote runs AFTER `Repo.transaction/1` returns, not inside the fn,
  for two reasons. First, `Tasks.transition_task/2` wraps the
  `in_progress` flip in its own transaction and `Repo.rollback/1`s on a
  refused gate (`:stack_plans_pending`, `:no_approved_plan`); Ecto nests
  transactions without savepoints, so that inner rollback would poison the
  outer one and undo the edge removal — the opposite of what a refused
  promote must do. Second, the transition broadcasts `{:task_updated, task}`
  as soon as its own transaction commits; running it after ours has
  committed makes that broadcast post-commit for the edge removal as well,
  so no subscriber can read pre-commit state and no re-broadcast is needed.

  Returns `{:ok, %{from_task_id, to_task_id, kind, executable_now, promoted}}`
  on success.
  """
  @spec remove_dependency_edge(Stack.t() | binary(), binary(), binary(), keyword()) ::
          {:ok,
           %{
             from_task_id: binary(),
             to_task_id: binary(),
             kind: String.t(),
             executable_now: [binary()],
             promoted: [binary()]
           }}
          | {:error, :stack_not_found | :task_not_found | :self_edge}
          | {:error, :not_in_stack, binary()}
          | {:error, :not_an_edge}
          | {:error, term()}
  def remove_dependency_edge(stack_or_id, from_task_id, to_task_id, opts \\ [])
      when is_binary(from_task_id) and is_binary(to_task_id) do
    kind = Keyword.get(opts, :kind, "blocks")

    txn =
      Repo.transaction(fn ->
        with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
             :ok <- ensure_distinct_endpoints(from_task_id, to_task_id),
             {:ok, %Task{} = from_task} <- load_task(from_task_id),
             {:ok, %Task{} = to_task} <- load_task(to_task_id),
             :ok <- ensure_in_stack(stack, from_task),
             :ok <- ensure_in_stack(stack, to_task),
             {:ok, _updated_from} <- Tasks.remove_dependency(from_task, to_task_id, kind),
             {:ok, _levels} <- normalize_dag_result(validate_dag(stack)),
             {:ok, _stack} <- recompute_stack_status(stack) do
          %{
            from_task_id: from_task_id,
            to_task_id: to_task_id,
            kind: kind,
            executable_now: stack |> executable_members() |> Enum.map(& &1.id)
          }
        else
          {:error, :not_in_stack, task_id} -> Repo.rollback({:not_in_stack, task_id})
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case txn do
      {:ok, result} ->
        # Post-commit on purpose — see the moduledoc above: a refused
        # promote rolls back its own transaction, which would take the
        # edge removal with it if we were still inside ours.
        promoted = promote_freed_dependent(from_task_id)
        {:ok, Map.put(result, :promoted, Enum.map(promoted, & &1.id))}

      {:error, {:cycle, path}} ->
        {:error, :cycle, path}

      {:error, {:cross_stack_dep, payload}} ->
        {:error, :cross_stack_dep, payload}

      {:error, {:not_in_stack, task_id}} ->
        {:error, :not_in_stack, task_id}

      other ->
        other
    end
  end

  # Reload the dependent whose edge was just removed (`Tasks.remove_dependency/3`
  # wrote a fresh row) and try to promote it — `try_promote/1`'s id clause
  # does the reload. Every non-`{:ok, _}` outcome is swallowed on purpose:
  # the edge removal has already committed and the member simply stays
  # where it was, exactly as it would have before the sweep reached it.
  defp promote_freed_dependent(task_id) when is_binary(task_id) do
    case try_promote(task_id) do
      {:ok, %Task{} = promoted} ->
        [promoted]

      :noop ->
        []

      {:error, reason} ->
        log_freed_promote_failure(task_id, reason)
        []

      {:error, reason, _details} ->
        log_freed_promote_failure(task_id, reason)
        []
    end
  end

  defp log_freed_promote_failure(task_id, reason) do
    Logger.info(
      "[Stacks.remove_dependency_edge] freed member #{task_id} not promoted: " <>
        inspect(reason)
    )
  end

  defp ensure_distinct_endpoints(id, id) when is_binary(id), do: {:error, :self_edge}
  defp ensure_distinct_endpoints(_from, _to), do: :ok

  @doc """
  List the (non-deleted) members of a stack, ordered by `stack_position` asc.
  """
  @spec members(Stack.t() | binary()) :: [Task.t()]
  def members(%Stack{id: stack_id}), do: members(stack_id)

  def members(stack_id) when is_binary(stack_id) do
    Task
    |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
    |> order_by([t], asc: t.stack_position)
    |> Repo.all()
  end

  @doc """
  List all open (pending) review requests across every member of a stack.

  Composes over `members/1` and reuses
  `Platform.Tasks.ReviewRequests.list_pending_for_task/1` so the per-task
  scoping rules (status `"pending"`, items preloaded) stay in one place.
  Resolved requests and tasks not in the stack are excluded by
  construction.

  Returns a flat list of `%ReviewRequest{}` structs ordered by
  `inserted_at` descending (newest first), matching the per-task ordering
  from `list_pending_for_task/1`.
  """
  @spec list_open_review_requests(Stack.t() | binary()) :: [
          Platform.Tasks.ReviewRequest.t()
        ]
  def list_open_review_requests(%Stack{id: stack_id}),
    do: list_open_review_requests(stack_id)

  def list_open_review_requests(stack_id) when is_binary(stack_id) do
    stack_id
    |> members()
    |> Enum.flat_map(&ReviewRequests.list_pending_for_task(&1.id))
    |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
  end

  @doc """
  Count open (pending) review requests across every member of a stack.

  Convenience wrapper around `list_open_review_requests/1` for callers
  (e.g. the stack-detail chrome pill) that only need a number.
  """
  @spec count_pending_reviews(Stack.t() | binary()) :: non_neg_integer()
  def count_pending_reviews(stack), do: length(list_open_review_requests(stack))

  @doc """
  List stacks with the precomputed board-card display data the kanban view
  needs to render a collapsed stack card and its inline expansion (ADR 0041
  §"UI surface — Board view"; T7 stage 1).

  Returns a list of `{%Stack{}, board_data}` tuples ordered by
  `updated_at` descending. `board_data` is a map with:

    * `:members` — list of member task structs ordered by `stack_position`
      ascending. Each member is a regular `%Task{}` (no extra preloads;
      the existing detail-panel flow handles deep loads).
    * `:member_count` — `length(members)`.
    * `:dep_edge_count` — count of dependency edges among members
      restricted to the in-stack subgraph (deps from a member pointing
      at another member of the same stack). Self-edges are dropped
      defensively.
    * `:ready_count` — members whose status is in `~w(in_review
      deploying done)`, matching ADR 0041's "ready" threshold for the
      `3/4 ready` rollup-progress text.

  Filters mirror `list_stacks/1` (`:project_id`, `:status`,
  `:sponsor_user_id`). Excluded statuses (`abandoned`) are NOT filtered
  here — callers may want to show abandoned stacks for audit; the
  tasks-live board passes through the same project filter the task list
  uses and accepts whatever statuses the backing data carries.

  The `:sponsor` association is preloaded on the stacks query so the
  board can render the sponsor avatar without a follow-up query per
  card. Applying the sponsor filter BEFORE the member fetch means the
  per-stack member fetch is naturally scoped — narrowing to a single
  sponsor also narrows the second-query cost.

  Implementation note: two-query fetch (stacks, then all member tasks
  for those stacks) followed by an in-memory group_by. The kanban
  board typically renders single-digit stack counts per project, so
  N+1 over `members/1` would also be acceptable, but the two-query
  form keeps the page-load cost flat as project size grows.
  """
  @spec list_stacks_with_members(map() | keyword()) :: [{Stack.t(), map()}]
  def list_stacks_with_members(filters \\ %{})

  def list_stacks_with_members(filters) when is_list(filters) do
    list_stacks_with_members(Map.new(filters))
  end

  def list_stacks_with_members(filters) when is_map(filters) do
    stacks =
      Stack
      |> filter_by_project(Map.get(filters, :project_id))
      |> filter_by_status(Map.get(filters, :status))
      |> filter_by_sponsor(Map.get(filters, :sponsor_user_id))
      |> Tasks.maybe_scope_by(Map.get(filters, :access_scope), :stack)
      |> order_by([s], desc: s.updated_at)
      |> preload(:sponsor)
      |> Repo.all()

    case stacks do
      [] ->
        []

      stacks ->
        stack_ids = Enum.map(stacks, & &1.id)

        # `:plans` preload is required by Tasks.needs_human_action_reason/2's
        # `:plan_pending_review` branch (task 019e2c25 stage 4 — mobile
        # stack-member badge). Members are otherwise rendered against the
        # board's `@review_counts` map, but the plan-pending-review check
        # reads `task.plans` directly (predicate returns false when not
        # preloaded rather than triggering a lazy query). Adding the
        # preload here keeps the board view (only caller) consistent with
        # the desktop stack-detail panel, which already preloads `:plans`
        # via `load_stack_member_panel_data/1` in TasksLive.
        kind = Map.get(filters, :kind)
        origin = Map.get(filters, :origin)

        members_by_stack =
          Task
          |> where([t], t.stack_id in ^stack_ids and is_nil(t.deleted_at))
          |> filter_members_by_kind(kind)
          |> filter_members_by_origin(origin)
          # A visible stack can hold a member in a project the scope may not
          # read (a stack's project and its members' projects can differ), so
          # the members are scoped too, or their titles would leak.
          |> Tasks.maybe_scope_by(Map.get(filters, :access_scope), :task)
          |> order_by([t], asc: t.stack_position)
          |> preload(:plans)
          |> Repo.all()
          |> Enum.group_by(& &1.stack_id)

        stacks
        |> Enum.map(fn stack ->
          members = Map.get(members_by_stack, stack.id, [])
          {stack, build_board_data(members)}
        end)
        |> maybe_drop_stacks_without_kind_members(kind || origin)
    end
  end

  # External Feedback lane (task 01a11ec3 stage 4): the persisted origin
  # column, exactly as the kind filter above uses the persisted kind.
  defp filter_members_by_origin(query, nil), do: query
  defp filter_members_by_origin(query, origin), do: where(query, [t], t.origin == ^origin)

  defp filter_members_by_kind(query, nil), do: query
  defp filter_members_by_kind(query, kind), do: where(query, [t], t.kind == ^kind)

  defp maybe_drop_stacks_without_kind_members(entries, nil), do: entries

  defp maybe_drop_stacks_without_kind_members(entries, _kind) do
    Enum.reject(entries, fn {_stack, board_data} -> board_data.member_count == 0 end)
  end

  # Public-ish (private) helper exposed for tests that want to build the
  # board-data map from a hand-seeded member list without touching the DB.
  @doc false
  def build_board_data(members) when is_list(members) do
    member_ids_set = MapSet.new(members, & &1.id)

    dep_edge_count =
      Enum.reduce(members, 0, fn %Task{id: from_id} = m, acc ->
        in_stack_deps =
          m
          |> Tasks.dependency_task_ids()
          |> Enum.reject(&(&1 == from_id))
          |> Enum.filter(&MapSet.member?(member_ids_set, &1))
          |> Enum.uniq()

        acc + length(in_stack_deps)
      end)

    ready_count = Enum.count(members, &(&1.status in ~w(in_review deploying done)))

    %{
      members: members,
      member_count: length(members),
      dep_edge_count: dep_edge_count,
      ready_count: ready_count
    }
  end

  # ── DAG validation / status recompute ────────────────────────────────────

  @doc """
  Validate the in-stack dependency DAG and return execution levels.

  Loads all current members of the stack, derives the dependency edges
  among them (dropping self-references and cross-stack-to-non-stack
  edges per ADR 0041 §"DAG validation"), then runs Kahn's topological
  sort over the in-stack subgraph.

  Returns:

    * `{:ok, levels}` — `levels` is a list of lists of `%Task{}`. Each
      inner list is a "level" of members runnable in parallel; level 0
      members have no in-stack predecessors, level 1 members depend
      only on level 0, and so on.
    * `{:error, :cycle, path}` — the in-stack subgraph contains a
      dependency cycle. `path` is a best-effort list of `%Task{}` along
      one offending cycle (recovered by walking back-edges through the
      residue Kahn could not drain).
    * `{:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}` —
      member `from` declares a dependency on `to_id`, which itself
      belongs to a different (non-nil) stack. Cross-stack edges are
      rejected at v1 because two stacks must be independently
      shippable.
  """
  @spec validate_dag(Stack.t() | binary()) ::
          {:ok, [[Task.t()]]}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  def validate_dag(%Stack{id: stack_id}), do: validate_dag(stack_id)

  def validate_dag(stack_id) when is_binary(stack_id) do
    members = members(stack_id)

    case build_in_stack_subgraph(members, stack_id) do
      {:ok, edges} ->
        case kahn_levels(members, edges) do
          {:ok, levels} ->
            {:ok, levels}

          {:error, :cycle, residue_ids} ->
            {:error, :cycle, find_cycle(residue_ids, edges, members)}
        end

      {:error, :cross_stack_dep, payload} ->
        {:error, :cross_stack_dep, payload}
    end
  end

  @doc """
  Recompute and persist a stack's rollup status from its members.

  Implements the ADR 0041 §"Status mapping" table:

      done        — all members done
      deploying   — any member deploying, none earlier
      in_review   — all members in_review/deploying/done
      in_progress — any member in_progress
      forming     — any backlog/planning/stack_pending, no member past in_progress

  Stacks already at `abandoned` are terminal and are NEVER auto-recomputed;
  this function returns `{:ok, stack}` for them unchanged. The DB write is
  skipped when the computed status matches the existing status. Members
  whose status falls outside the recognized set are treated conservatively
  as not-yet-past-in_progress.
  """
  @spec recompute_stack_status(Stack.t() | binary()) ::
          {:ok, Stack.t()} | {:error, Ecto.Changeset.t() | :stack_not_found}
  def recompute_stack_status(%Stack{status: "abandoned"} = stack), do: {:ok, stack}

  def recompute_stack_status(%Stack{} = stack) do
    members = members(stack.id)
    new_status = rollup_status_for(members)

    result =
      if new_status == stack.status do
        {:ok, stack}
      else
        stack
        |> Stack.changeset(%{status: new_status})
        |> Repo.update()
      end

    # Piggy-back: any state change that re-rolls up the stack should also
    # re-attempt the rollup PR open. The deployer's `maybe_open_stack_pr/1`
    # is idempotent — it noops when the rollup PR is already open or when
    # not all members are ready — so calling it on every recompute is safe.
    # Failures here are logged but never propagated; the recompute return
    # value is the source of truth for callers.
    case result do
      {:ok, %Stack{} = updated} -> trigger_pr_open(updated)
      _ -> :ok
    end

    result
  end

  def recompute_stack_status(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> recompute_stack_status(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  @doc """
  The operator exit from a conflict-held `blocked` stack (task 01a05393
  stage 4, ADR 0041 §"Rollup-branch merge").

  `Stack.changeset/2` holds a `blocked` stack's status sticky while
  `metadata["conflict"]` is set, and its only escape is a changeset that
  clears the conflict AND moves the status in the SAME write. This
  function builds exactly that one changeset: `metadata` with `"conflict"`
  deleted plus the status recomputed from the members. A two-step clear
  (metadata first, then status) would have its second step dropped by the
  guard, so the combined write is load-bearing, not a convenience.

  After the write commits the existing `recompute_stack_status/1` path is
  re-run on the fresh row — a no-op for the status (already recomputed)
  that re-arms the rollup-PR piggy-back — and `{:stack_updated, stack}` is
  broadcast on the board. Both happen strictly after the `Repo.update`
  returns; nothing observes pre-commit state.

  Returns `{:error, :not_conflicted}` without writing when
  `ShipState.conflict_held?/1` is false, `{:error, :stack_not_found}` for
  an unknown id, and `{:error, %Ecto.Changeset{}}` if the write fails.

  Options:

    * `:broadcast` — emit the `{:stack_updated, stack}` board event
      (default `true`). Callers that broadcast their own envelope pass
      `false` so a single clear produces a single event.
  """
  @spec clear_conflict(Stack.t() | binary(), keyword()) ::
          {:ok, Stack.t()}
          | {:error, :not_conflicted | :stack_not_found | Ecto.Changeset.t()}
  def clear_conflict(subject, opts \\ [])

  def clear_conflict(stack_id, opts) when is_binary(stack_id) and is_list(opts) do
    # Through `get_stack/1` so a raw id is `Platform.UUID.valid?/1`-guarded
    # before it reaches the Repo (repo_lookup_boundary_test inventory).
    case get_stack(stack_id) do
      %Stack{} = stack -> clear_conflict(stack, opts)
      nil -> {:error, :stack_not_found}
    end
  end

  def clear_conflict(%Stack{} = stack, opts) when is_list(opts) do
    # Re-read the row: the caller's struct may predate the conflict being
    # recorded (or cleared) by the deployer.
    stack = Repo.get(Stack, stack.id) || stack

    if ShipState.conflict_held?(stack) do
      metadata = stack.metadata |> ensure_map() |> Map.delete("conflict")
      new_status = rollup_status_for(members(stack.id))

      result =
        stack
        |> Stack.changeset(%{status: new_status, metadata: metadata})
        |> Repo.update()

      case result do
        {:ok, %Stack{} = cleared} ->
          # Post-commit: re-run the canonical recompute (no-op on status,
          # re-arms the rollup-PR piggy-back) and then broadcast.
          final =
            case recompute_stack_status(cleared) do
              {:ok, %Stack{} = recomputed} -> recomputed
              _ -> cleared
            end

          if Keyword.get(opts, :broadcast, true) do
            Tasks.broadcast_board({:stack_updated, final})
          end

          {:ok, final}

        {:error, _} = error ->
          error
      end
    else
      {:error, :not_conflicted}
    end
  end

  defp ensure_map(metadata) when is_map(metadata), do: metadata
  defp ensure_map(_), do: %{}

  # Wrap `StackDeployer.maybe_open_stack_pr/1` so a deployer crash or
  # `{:error, _}` return is logged but never propagates back into the
  # recompute return value. The deployer's gate is internally idempotent
  # (`:already_open` / `:not_ready`), so re-firing on every recompute is
  # safe.
  defp trigger_pr_open(%Stack{} = stack) do
    try do
      case StackDeployer.maybe_open_stack_pr(stack) do
        {:ok, _outcome} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Stacks] recompute_stack_status piggy-back: maybe_open_stack_pr " <>
              "failed for stack #{stack.id}: #{inspect(reason)}"
          )

          :ok
      end
    rescue
      e ->
        Logger.warning(
          "[Stacks] recompute_stack_status piggy-back: maybe_open_stack_pr " <>
            "raised for stack #{stack.id}: #{Exception.message(e)}"
        )

        :ok
    end
  end

  # Pure rollup of member statuses → stack rollup status. Empty stack
  # stays at `forming` (no members have advanced past `forming` yet).
  defp rollup_status_for([]), do: "forming"

  defp rollup_status_for(members) do
    # A cancelled member owes nothing, so it must not hold the stack out of
    # `done` / `deploying`. Filtered through the shared `MemberSet`
    # predicate rather than a local status check.
    statuses =
      members
      |> Enum.filter(&MemberSet.counts_as_pending?/1)
      |> Enum.map(& &1.status)

    # Bug #6 (task 019f708f): the previous shape used
    # `Enum.any?(&1 == "deploying")` here, which collapsed a mixed
    # stack like `[deploying, deploying, deploying, stack_pending,
    # stack_pending, stack_pending]` to `"deploying"` — but the
    # commencement gate refuses to promote a stack_pending member
    # unless the stack itself is `"in_progress"`, so the last three
    # members silently deadlocked. Flip the `deploying` arm to
    # `Enum.all?(&1 in ["deploying", "done"])` (symmetric with the
    # `in_review` arm below it), and flip the `in_progress` arm to
    # accept `stack_pending` as an in-progress signal — a stack made
    # up entirely of `stack_pending` members is commenced, not
    # forming.
    cond do
      Enum.all?(statuses, &(&1 == "done")) ->
        "done"

      Enum.all?(statuses, &(&1 in ["deploying", "done"])) ->
        "deploying"

      Enum.all?(statuses, &(&1 in ["in_review", "deploying", "done"])) ->
        "in_review"

      Enum.any?(statuses, &(&1 in ["in_progress", "stack_pending"])) ->
        "in_progress"

      true ->
        "forming"
    end
  end

  # ── Dispatch helpers ─────────────────────────────────────────────────────

  @doc """
  Return the stack members that have no in-stack dependencies — the
  level-0 "roots" of the in-stack DAG.

  Thin wrapper over `validate_dag/1`. If validation fails (cycle or
  cross-stack edge), returns `[]` so callers don't crash on a stack with
  a transient invalid state.
  """
  @spec executable_members(Stack.t() | binary()) :: [Task.t()]
  def executable_members(stack_or_id) do
    case validate_dag(stack_or_id) do
      {:ok, []} -> []
      {:ok, [roots | _]} -> roots
      {:error, _reason, _detail} -> []
    end
  end

  # ── Deploy readiness (Stack v2 stage 2) ────────────────────────────────

  @doc """
  Pure predicate: is the stack ready to deploy as a single rollup PR?

  Distinct from `Platform.Tasks.StackDeployer`'s private
  `all_members_ready?/1`, which additionally requires each member's
  `metadata["merged_into_rollup_at"]` stamp — a downstream signal that
  the member's branch has been merged into the rollup branch. This
  predicate answers the upstream question deploy-side callers actually
  need: has every member finished its validation-set so the stack CAN
  deploy? Keyed on validation-pass counts, not rollup-merge stamps.

  Returns `true` iff ALL of:

    * the stack's own status is not `"deploying"`, `"done"`, `"abandoned"`,
      or `"blocked"` (short-circuit against double-fire, terminal states,
      and a stack halted on an unresolved rollup conflict);
    * `members/1` is non-empty;
    * every member's status is in `["in_review", "deploying"]`;
    * every non-deploy validation on every non-superseded, non-rejected
      plan across every member has `status == "passed"`.

  Deploy-stage validations are excluded via
  `Platform.Tasks.PlanEngine.deploy_stage?/1`. Stack members shouldn't
  ever carry a deploy stage — `Tasks.dispatch_deploy_for_task/1`'s
  atomic-ship guard (stage 1 of this task) blocks the injection — but
  the exclusion is a defensive regression guard against future engine
  changes.

  No writes, no side effects, safe to call from any hot path.
  """
  @spec deploy_ready?(Stack.t() | binary()) :: boolean()
  def deploy_ready?(%Stack{status: status})
      when status in ["deploying", "done", "abandoned", "blocked"],
      do: false

  def deploy_ready?(%Stack{} = stack) do
    case members(stack) do
      [] -> false
      members -> Enum.all?(members, &member_deploy_ready?/1)
    end
  end

  def deploy_ready?(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> deploy_ready?(stack)
      nil -> false
    end
  end

  @doc """
  Return the members that are NOT ready for deploy — the complement of
  the `deploy_ready?/1` gate (modulo the stack-status guard).

  Used for logging + telemetry attribution when the gate remains closed.
  A member appears in the returned list if its status is outside
  `["in_review", "deploying"]` OR if any of its non-deploy validations
  is still not `"passed"`.

  Relationship: `deploy_ready?/1 == true` implies
  `pending_members_for_deploy/1 |> Enum.empty?()`. The reverse implication
  holds only when the stack's own status is not `"deploying"`, `"done"`,
  or `"abandoned"` — the stack-status guard on `deploy_ready?/1` is not
  reflected here because the "who's pending" surface is orthogonal to
  the stack-level short-circuit.

  Returns `[]` for an unknown stack id (mirrors `deploy_ready?/1`'s
  fail-safe behavior).
  """
  @spec pending_members_for_deploy(Stack.t() | binary()) :: [Task.t()]
  def pending_members_for_deploy(%Stack{} = stack) do
    stack
    |> members()
    |> Enum.reject(&member_deploy_ready?/1)
  end

  def pending_members_for_deploy(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> pending_members_for_deploy(stack)
      nil -> []
    end
  end

  # A member is deploy-ready when both:
  #   * its status signals a completed validation set — `in_review` (the
  #     usual case) or `deploying` (mid-rollup-merge, stamped by the
  #     deployer as it walks members through), AND
  #   * every non-deploy validation on every non-superseded plan across
  #     the member has `status == "passed"`.
  defp member_deploy_ready?(%Task{status: status} = task)
       when status in ["in_review", "deploying"] do
    all_non_deploy_validations_passed?(task)
  end

  defp member_deploy_ready?(_task), do: false

  # Load every stage on every non-superseded, non-rejected plan for the
  # task, drop the deploy stages via `PlanEngine.deploy_stage?/1`, and
  # confirm every remaining validation is `passed`. Superseded/rejected
  # plans are excluded because their stale validations should not gate
  # the current deploy — the "live" plan is what matters.
  #
  # Empty-set case is vacuously `true` (a member with no validations at
  # all can never block deploy — matches `Enum.all?/2` on `[]`).
  defp all_non_deploy_validations_passed?(%Task{id: task_id}) do
    from(s in Stage,
      join: p in Plan,
      on: s.plan_id == p.id,
      where: p.task_id == ^task_id and p.status not in ["superseded", "rejected"],
      preload: [:validations]
    )
    |> Repo.all()
    |> Enum.reject(&PlanEngine.deploy_stage?/1)
    |> Enum.flat_map(& &1.validations)
    |> Enum.all?(&(&1.status == "passed"))
  end

  # ── Deploy dispatch (Stack v2 stage 3) ─────────────────────────────────

  @doc """
  Transition a fully-ready stack to `"deploying"` and fire the rollup-PR
  open trigger asynchronously.

  Called from `PlanEngine.maybe_inject_deploy_or_complete/2`'s stacked-task
  branch every time a stack member's plan completes; the atomicity guard
  in this function turns concurrent double-fires (two members completing
  in the same tick) into exactly one `[:platform, :stacks, :deploy,
  :dispatched]` telemetry event and one state transition. Calls from
  members 1..N-1 short-circuit as `:noop` because `deploy_ready?/1`
  returns `false` while any member remains pending.

  Behavior:

    1. Reloads the stack and checks `deploy_ready?/1`. If `false`,
       returns `{:ok, :noop}` — no side effects.
    2. Stamps `metadata["first_deploy_ready_at"]` set-once-if-nil (a
       previously-stamped value survives across recovery retries).
    3. Performs a **compare-and-swap** on `stacks.status` via
       `Repo.update_all` guarded by `status IN
       ("forming", "in_progress", "in_review")`. Postgres serializes
       concurrent writes on the row and the second query re-reads the
       committed `"deploying"` value → 0 rows updated → loser returns
       `:noop`. Exactly one winner per race.
    4. Emits telemetry `[:platform, :stacks, :deploy, :dispatched]`
       with `%{count: 1}` measurements and metadata
       `%{stack_id, member_count, duration_ms_from_first_member_ready}`.
    5. Async-calls `StackDeployer.maybe_open_stack_pr/1` under the same
       `Elixir.Task.Supervisor` used by the deployer's other async
       triggers, mirroring `StackDeployer.trigger_maybe_open_stack_pr/1`.
       `Platform.Tasks.Task` is aliased in this module, so a bare `Task.`
       here means the SCHEMA — the OTP call is spelled `Elixir.Task.`.
       The PR-open body runs inside `run_deploy_pr_open/1`, which
       rescues every exception: an async PR-open failure is logged and
       NEVER propagates to this function's return value. The dispatch
       result reflects the state transition only, not the PR outcome.

  Returns:

    * `{:ok, :dispatched}` — the stack was transitioned to `"deploying"`
      on this call and the PR-open trigger fired.
    * `{:ok, :noop}` — the stack was not ready OR another concurrent
      caller won the transition race.
    * `{:error, :stack_not_found}` — the stack id doesn't resolve.
  """
  @spec dispatch_stack_deploy(Stack.t() | binary()) ::
          {:ok, :dispatched | :noop} | {:error, :stack_not_found}
  def dispatch_stack_deploy(%Stack{id: id}) when is_binary(id) do
    dispatch_stack_deploy(id)
  end

  def dispatch_stack_deploy(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      nil ->
        {:error, :stack_not_found}

      %Stack{} = stack ->
        if deploy_ready?(stack) do
          try_dispatch(stack)
        else
          {:ok, :noop}
        end
    end
  end

  def dispatch_stack_deploy(_), do: {:error, :stack_not_found}

  # Atomic transition to "deploying" via compare-and-swap on stacks.status.
  # The guarded WHERE ensures exactly one concurrent caller wins the race.
  defp try_dispatch(%Stack{} = stack) do
    now = DateTime.utc_now()
    now_iso = DateTime.to_iso8601(now)
    base_meta = if is_map(stack.metadata), do: stack.metadata, else: %{}

    first_ready_iso =
      case Map.get(base_meta, "first_deploy_ready_at") do
        iso when is_binary(iso) -> iso
        _ -> now_iso
      end

    new_meta = Map.put(base_meta, "first_deploy_ready_at", first_ready_iso)

    {count, _} =
      from(s in Stack,
        where:
          s.id == ^stack.id and
            s.status in ["forming", "in_progress", "in_review"],
        update: [
          set: [
            status: "deploying",
            metadata: ^new_meta,
            updated_at: ^now
          ]
        ]
      )
      |> Repo.update_all([])

    case count do
      1 ->
        updated_stack = Repo.get!(Stack, stack.id)
        member_count = length(members(updated_stack))
        duration_ms = deploy_ready_duration_ms(first_ready_iso, now)

        emit_deploy_dispatched_telemetry(updated_stack, member_count, duration_ms)
        trigger_stack_deploy_pr_open(updated_stack.id)

        Logger.info(
          "[Stacks] dispatch_stack_deploy stack #{updated_stack.id}: transitioned to " <>
            "deploying (member_count=#{member_count}, duration_ms=#{duration_ms})"
        )

        {:ok, :dispatched}

      0 ->
        {:ok, :noop}
    end
  end

  defp deploy_ready_duration_ms(first_ready_iso, %DateTime{} = now) do
    case DateTime.from_iso8601(first_ready_iso) do
      {:ok, %DateTime{} = ready_at, _} -> DateTime.diff(now, ready_at, :millisecond)
      _ -> 0
    end
  end

  defp emit_deploy_dispatched_telemetry(%Stack{id: stack_id}, member_count, duration_ms) do
    :telemetry.execute(
      [:platform, :stacks, :deploy, :dispatched],
      %{
        count: 1,
        duration_ms_from_first_member_ready: duration_ms
      },
      %{
        stack_id: stack_id,
        member_count: member_count,
        duration_ms_from_first_member_ready: duration_ms
      }
    )

    :ok
  end

  # Mirrors `StackDeployer.trigger_maybe_open_stack_pr/1` — same
  # `Elixir.Task.Supervisor` + `async: true|false` config knobs so tests can
  # observe the runner call synchronously via
  # `Application.put_env(:platform, :stack_deployer, async: false)`.
  #
  # `Platform.Tasks.Task` is aliased at line 22, so a bare `Task.` in this
  # module means the SCHEMA — the OTP call below must be written out as
  # `Elixir.Task.Supervisor` or it resolves to the nonexistent
  # `Platform.Tasks.Task.Supervisor`.
  #
  # Returns the spawned `Elixir.Task` struct from the async branch (mirroring
  # `StackDeployer.handle_member_transition/3`) so callers — in practice the
  # test suite — can await completion instead of polling. The only production
  # caller discards it. The sync branch returns `:ok`.
  defp trigger_stack_deploy_pr_open(stack_id) when is_binary(stack_id) do
    if stack_deployer_async?() do
      Elixir.Task.Supervisor.async_nolink(stack_deployer_task_supervisor(), fn ->
        run_deploy_pr_open(stack_id)
      end)
    else
      run_deploy_pr_open(stack_id)
    end
  end

  # `Elixir.Task.Supervisor.async_nolink/2` discards the child's crash — nobody
  # links, nobody awaits — so an exception raised by
  # `StackDeployer.maybe_open_stack_pr/1` (git conflict, network, disk) would
  # strand the stack in `deploying` with nothing in the log. Same shape as
  # `StackDeployer.attempt_member_merge/1`, and called from BOTH branches of
  # `trigger_stack_deploy_pr_open/1` so `async: false` and `async: true` behave
  # identically.
  #
  # The `DBConnection.OwnershipError` clause must come FIRST: under
  # `async: true` in the test env the spawned child sits outside the DataCase
  # sandbox owner chain, so a teardown race releases the connection out from
  # under it. That is a test-harness artifact, not a deploy failure, and it is
  # logged at warning rather than error so it cannot be mistaken for one.
  defp run_deploy_pr_open(stack_id) when is_binary(stack_id) do
    log_deploy_pr_open(stack_id, StackDeployer.maybe_open_stack_pr(stack_id))
    :ok
  rescue
    DBConnection.OwnershipError ->
      Logger.warning(
        "[Stacks] dispatch_stack_deploy stack #{stack_id} PR-open skipped: " <>
          "sandbox connection released"
      )

      :ok

    e ->
      Logger.error(
        "[Stacks] dispatch_stack_deploy stack #{stack_id} PR-open raised: " <>
          "#{Exception.message(e)}\n" <> Exception.format(:error, e, __STACKTRACE__)
      )

      :ok
  end

  defp log_deploy_pr_open(stack_id, {:ok, outcome}) do
    Logger.info(
      "[Stacks] dispatch_stack_deploy stack #{stack_id} PR-open outcome: #{inspect(outcome)}"
    )

    :ok
  end

  defp log_deploy_pr_open(stack_id, {:error, reason}) do
    Logger.warning(
      "[Stacks] dispatch_stack_deploy stack #{stack_id} PR-open failed: #{inspect(reason)}"
    )

    :ok
  end

  defp stack_deployer_config do
    Application.get_env(:platform, :stack_deployer, [])
  end

  defp stack_deployer_async? do
    Keyword.get(stack_deployer_config(), :async, true)
  end

  defp stack_deployer_task_supervisor do
    Keyword.get(stack_deployer_config(), :task_supervisor, Platform.TaskSupervisor)
  end

  @doc """
  Detect whether a just-completed plan approval was the transition point
  that opened the stack-v2 commencement gate (ADR 0042 Decision 4).

  Called from inside `Platform.Tasks.approve_plan/3`'s transaction,
  AFTER the plan write. The `task` is the member whose plan was just
  approved; `pre_update_plan` is that plan as it looked immediately
  before the write (i.e. `status: "pending_review"` in the normal call
  path).

  Returns:

    * `{:opened, stack, executable_ids}` — the gate flipped closed →
      open on this approval. `executable_ids` is the list of member ids
      that are level-0 roots of the in-stack DAG (the members that are
      now callable via `task_start` / `transition_task_status/2`).
      Non-root members remain at `stack_pending` until an explicit
      transition — the gate broadcast is a signal, not an auto-advance.

    * `:noop` — the task doesn't belong to a stack, the stack is
      missing, `plans_ready?/1` is still false, or the pre-approval plan
      was already counted as approved (so this call was a re-approval
      that didn't change the gate).

  ## The "was closed before" check

  `plans_ready?/1` collapses to "every member's latest plan is in
  `["approved", "completed"]`". The only member whose latest-plan
  status changed inside this txn is the one owning `pre_update_plan`
  (older siblings that get auto-superseded only slide from `approved`
  → `rejected`, so the LATEST plan for those tasks — which is still
  this newly-approved plan — is unaffected). So the pre-write gate
  state is equivalent to the post-write state, minus this task's
  contribution, plus this task's pre-approval contribution:

    * If `pre_update_plan.status in ["approved", "completed"]`, this
      task was already counted as approved before → post-write ready
      status equals pre-write ready status → no transition happened
      here even if the gate is currently open.

    * Otherwise, this task went from "not counted" to "counted", so
      a post-write `plans_ready? = true` means the gate JUST opened.
  """
  @spec detect_gate_open_transition(Task.t(), Plan.t()) ::
          {:opened, Stack.t(), [String.t()]} | :noop
  def detect_gate_open_transition(task, pre_update_plan)

  def detect_gate_open_transition(%Task{stack_id: nil}, _pre_update_plan), do: :noop

  def detect_gate_open_transition(%Task{stack_id: stack_id}, %Plan{} = pre_update_plan)
      when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      nil ->
        :noop

      %Stack{} = stack ->
        if CommencementGate.plans_ready?(stack) and
             not pre_update_plan_already_counted?(pre_update_plan) do
          executable_ids = stack |> executable_members() |> Enum.map(& &1.id)
          emit_gate_opened_telemetry(stack.id, executable_ids)
          {:opened, stack, executable_ids}
        else
          :noop
        end
    end
  end

  # Telemetry emission for the closed→open transition. Fires exactly
  # once per stack per opening because `detect_gate_open_transition/2`
  # is gated by `pre_update_plan_already_counted?/1` — a re-approval that
  # lands after the gate is already open returns `:noop` without touching
  # this helper. Mirrors `:telemetry.execute/3` shape from
  # `PlanEngine` / `StackDeployer`.
  defp emit_gate_opened_telemetry(stack_id, executable_ids) do
    :telemetry.execute(
      [:platform, :stacks, :commencement, :gate_opened],
      %{executable_count: length(executable_ids)},
      %{stack_id: stack_id, executable_task_ids: executable_ids}
    )
  end

  # A plan whose pre-write status was already in the "approved" set means
  # `plans_ready?/1`'s DISTINCT-ON-latest query counted this task as ready
  # BEFORE this approval too — so today's write did not change the gate
  # boolean even if it's currently `true`.
  defp pre_update_plan_already_counted?(%Plan{status: status}),
    do: status in ~w(approved completed)

  # ── Terminal cascade (Stack v2 stage 5) ────────────────────────────────

  @doc """
  Cascade every stack member that hasn't landed at `"done"` to `"done"`.

  Called from `StackDeployer.handle_rollup_pr_merged/1` as a safety net
  after the rollup PR has merged. On the canonical happy path the T6
  webhook fan-out (`GithubWebhookController.process_stack_merged_pr/4`
  at `github_webhook_controller.ex:505`) has already flipped each
  member to `done` via its per-task `pr_merged` validation — this
  helper is then a no-op (every member is already `done`).

  The fallback path fires when a member is at `in_review` with no
  `pr_merged` validation (e.g. it never got a per-task deploy stage —
  the exact case for stack members, which ship via the rollup PR).
  Those members are transitioned to `done` directly via
  `Tasks.transition_task/2`. Failed transitions surface in `skipped`
  so callers can log-and-continue rather than crash the whole
  rollup-merge handler.

  Returns `%{cascaded: [Task.t()], skipped: [%{task_id, status,
  reason}]}`. `cascaded` lists members transitioned by THIS call
  (members already at `"done"` are silently omitted from both keys —
  the point of the helper is "make sure everyone is done", not "report
  who was already done"). `skipped` lists members whose transition
  attempt failed for any reason (invalid transition, changeset error,
  etc.).

  Returns `%{cascaded: [], skipped: [%{reason: :stack_not_found}]}` for
  an unknown stack id — the helper never raises.
  """
  @spec cascade_members_to_done(Stack.t() | binary(), :webhook | :backfill) :: %{
          cascaded: [Task.t()],
          skipped: [%{task_id: String.t(), status: String.t(), reason: term()}]
        }
  def cascade_members_to_done(stack_or_id, trigger \\ :webhook)

  def cascade_members_to_done(%Stack{} = stack, trigger)
      when trigger in [:webhook, :backfill] do
    all_members = members(stack)

    # TAIL-stall fix (2026-07-22): never force-complete a member that is still
    # mid-review — one whose current plan carries any pending/running
    # validation (`member_has_open_validations?/1`). The rollup-merge cascade
    # is "make sure everyone READY is done", not "ram every member to done":
    # a member with open validations still owes its own review. It completes
    # on its own afterward — once its last validation passes it advances to
    # `deploying` and self-completes via
    # `complete_no_op_member_if_rollup_merged/1` (the rollup PR is already
    # merged by then). Members with NO validations remain vacuously
    # completable, preserving the fan-out-fallback contract for members that
    # shipped without a per-task deploy stage.
    #
    # Task 01a05393 stage 5: `cancelled` is terminal (no outbound edge in
    # `Tasks.@valid_task_transitions`), and the rollup fan-out now cancels a
    # member that never entered execution. Left in `to_transition` it would
    # fail `-> done` and roll back every sibling's flip — the exact stranded
    # shape this cascade exists to prevent.
    to_transition =
      Enum.reject(
        all_members,
        &(&1.status in ~w(done cancelled) or member_has_open_validations?(&1))
      )

    # Stage 3 (019f5bc4-3521): wrap the per-member reduce in a
    # `Repo.transaction/1` so a single illegal transition rolls back
    # every sibling flip. Prevents the half-done stack we saw when a
    # rollup PR merged but one member had drifted into a status that
    # can't legally reach `done`. On rollback we still return the
    # cascaded/skipped shape (with `cascaded: []`) and still fire the
    # `:cascade_completed` telemetry so dashboards count the failure —
    # per stage 2's idempotency contract, every entry into the cascade
    # helper emits exactly one event.
    transaction_result =
      Repo.transaction(fn ->
        Enum.reduce(to_transition, %{cascaded: [], skipped: []}, fn member, acc ->
          case Tasks.transition_task(member, "done") do
            {:ok, updated} ->
              Logger.warning(
                "[Stacks.cascade_members_to_done] member #{member.id} (status=#{member.status}) " <>
                  "was not flipped to done by the rollup-merge fan-out; transitioned directly. " <>
                  "This usually means the member had no pr_merged validation — expected for " <>
                  "stack members but worth confirming ops didn't lose a webhook."
              )

              %{acc | cascaded: [updated | acc.cascaded]}

            {:error, reason} ->
              Repo.rollback(
                {:member_transition_failed, member.id, %{status: member.status, reason: reason}}
              )

            {:error, reason, _details} ->
              Repo.rollback(
                {:member_transition_failed, member.id, %{status: member.status, reason: reason}}
              )
          end
        end)
      end)

    result =
      case transaction_result do
        {:ok, acc} ->
          %{
            cascaded: Enum.reverse(acc.cascaded),
            skipped: Enum.reverse(acc.skipped)
          }

        {:error, {:member_transition_failed, task_id, %{status: status, reason: reason}}} ->
          Logger.warning(
            "[Stacks.cascade_members_to_done] transaction rolled back for stack #{stack.id}: " <>
              "member #{task_id} (status=#{status}) failed to transition to done " <>
              "(reason=#{inspect(reason)}); all sibling transitions reverted"
          )

          %{
            cascaded: [],
            skipped: [%{task_id: task_id, status: status, reason: reason}]
          }
      end

    emit_cascade_completed_telemetry(stack, all_members, result, trigger)

    result
  end

  def cascade_members_to_done(stack_id, trigger)
      when is_binary(stack_id) and trigger in [:webhook, :backfill] do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack ->
        cascade_members_to_done(stack, trigger)

      nil ->
        # Deliberately no telemetry emission for the unknown-stack branch:
        # there's no stack_id to key dashboards on and the caller learns
        # about it via the returned `:stack_not_found` skip entry.
        %{cascaded: [], skipped: [%{task_id: nil, status: nil, reason: :stack_not_found}]}
    end
  end

  # Fire `[:platform, :stacks, :deploy, :cascade_completed]` after every
  # invocation of `cascade_members_to_done/2` on a real stack. Emits even
  # in the no-op case (nothing to cascade) so dashboards can count how
  # often the cascade helper is entered — the metric shape mirrors
  # `StackDeployer.emit_pr_merged_telemetry/4` (measurements carry
  # `count: 1` + the total member roll; metadata carries the stack
  # identity + cascade-specific counters + the trigger tag).
  #
  # Trigger `:webhook` is the canonical happy path (from
  # `StackDeployer.handle_rollup_pr_merged/1` after the rollup PR closes
  # merged); `:backfill` is the Mix-task recovery path landing in a
  # later stage of task 019f5bc4-3521.
  defp emit_cascade_completed_telemetry(
         %Stack{id: stack_id, rollup_branch: rollup_branch},
         all_members,
         %{cascaded: cascaded, skipped: skipped},
         trigger
       ) do
    :telemetry.execute(
      [:platform, :stacks, :deploy, :cascade_completed],
      %{count: 1, member_count: length(all_members)},
      %{
        stack_id: stack_id,
        rollup_branch: rollup_branch,
        cascaded_count: length(cascaded),
        skipped_count: length(skipped),
        trigger: trigger
      }
    )

    :ok
  end

  @doc """
  Sweep every stack member sitting at `deploying` with a
  `no_op_wait_for_rollup` deploy strategy to `done`.

  ## Why this exists (incident: stack-member lifecycle TAIL stall, 2026-07-22)

  A `no_op_wait_for_rollup` member has no per-member deploy of its own —
  it ships when the stack's single rollup PR merges. `cascade_members_to_done/2`
  already handles this on the FIRST real rollup-merge delivery, but it
  leaks in two ways this helper closes as belt-and-braces:

    * `handle_rollup_pr_merged/2`'s `is_nil(rollup_pr)` branch returns
      `{:ok, stack}` with NO cascade at all (test-seam / manually-flipped
      stacks), and
    * a member that only reaches `deploying` AFTER the merge webhook fired
      (e.g. flipped there by the 15-min `in_review` stall sweep) is never
      revisited by the one-shot cascade — exactly how M5 stranded.

  Unlike `cascade_members_to_done/2` — which rolls the whole transaction
  back if a single member can't legally reach `done` — this helper is
  strictly additive and log-and-swallows a failed transition (mirroring
  `commence_open_gate/1` / `sweep_stack_dependents/1`): a member that can't
  advance is skipped, never a reason to abandon its siblings, and NEVER a
  reason to roll back the triggering rollup-merge. Idempotent: members
  already `done`, not at `deploying`, or resolving to any other strategy
  are skipped. Returns `{:ok, swept}` where `swept` is the list of members
  freshly transitioned to `done` by THIS call.
  """
  @spec sweep_deploying_members_to_done(Stack.t() | binary()) :: {:ok, [Task.t()]}
  def sweep_deploying_members_to_done(%Stack{id: stack_id}),
    do: sweep_deploying_members_to_done(stack_id)

  def sweep_deploying_members_to_done(stack_id) when is_binary(stack_id) do
    candidates =
      stack_id
      |> members()
      |> Enum.filter(&no_op_deploying_member?/1)

    {:ok, swept} =
      Repo.transaction(fn ->
        Enum.reduce(candidates, [], fn member, acc ->
          case Tasks.transition_task(member, "done") do
            {:ok, updated} ->
              [updated | acc]

            other ->
              Logger.warning(
                "[Stacks.sweep_deploying_members_to_done] member #{member.id} " <>
                  "(status=#{member.status}) could not be swept deploying->done: " <>
                  inspect(other)
              )

              acc
          end
        end)
        |> Enum.reverse()
      end)

    {:ok, swept}
  end

  @doc """
  Complete a SINGLE member `deploying -> done` iff its stack's rollup PR is
  already merged and its resolved deploy strategy is `no_op_wait_for_rollup`.

  This is the symmetric per-member trigger for the after-the-merge race:
  a member that only reaches `deploying` AFTER the rollup PR already merged
  (its `metadata["rollup_pr"]["merged_at"]` is stamped) would otherwise wait
  for a webhook that already fired. Called from the `deploying`
  finalize-transition hook so the member self-completes the instant it lands.

  Log-and-swallow, idempotent, never raises: any member that is not a
  `no_op_wait_for_rollup` member at `deploying`, or whose stack's rollup PR
  has not merged yet, yields `:noop`. Returns `{:ok, task}` on a successful
  completion.
  """
  @spec complete_no_op_member_if_rollup_merged(Task.t() | binary()) ::
          {:ok, Task.t()} | :noop
  def complete_no_op_member_if_rollup_merged(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> complete_no_op_member_if_rollup_merged(task)
      nil -> :noop
    end
  end

  def complete_no_op_member_if_rollup_merged(%Task{stack_id: nil}), do: :noop

  def complete_no_op_member_if_rollup_merged(%Task{stack_id: stack_id} = task)
      when is_binary(stack_id) do
    with true <- no_op_deploying_member?(task),
         %Stack{} = stack <- Repo.get(Stack, stack_id),
         true <- rollup_pr_merged?(stack) do
      case Tasks.transition_task(task, "done") do
        {:ok, updated} ->
          Logger.info(
            "[Stacks.complete_no_op_member_if_rollup_merged] member #{task.id} " <>
              "reached deploying after rollup PR merge; self-completed to done"
          )

          {:ok, updated}

        other ->
          Logger.warning(
            "[Stacks.complete_no_op_member_if_rollup_merged] member #{task.id} " <>
              "could not self-complete deploying->done: " <> inspect(other)
          )

          :noop
      end
    else
      _ -> :noop
    end
  end

  def complete_no_op_member_if_rollup_merged(_), do: :noop

  # A member eligible for the deploy-tail sweep: status is `deploying` and
  # its resolved deploy strategy is `no_op_wait_for_rollup` (a stack member
  # with a live rollup branch, per `Tasks.resolve_deploy_strategy/1`).
  defp no_op_deploying_member?(%Task{status: "deploying"} = task) do
    case Tasks.resolve_deploy_strategy(task) do
      %{"type" => "no_op_wait_for_rollup"} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp no_op_deploying_member?(_), do: false

  # True iff the stack's rollup PR has recorded a `merged_at` stamp.
  defp rollup_pr_merged?(%Stack{metadata: meta}) when is_map(meta) do
    case Map.get(meta, "rollup_pr") do
      %{"merged_at" => merged_at} when is_binary(merged_at) and merged_at != "" -> true
      _ -> false
    end
  end

  defp rollup_pr_merged?(_), do: false

  @doc """
  Return the stack members flattened into the order they should be merged
  into the rollup branch — foundational members first.

  On success this is `validate_dag/1`'s level structure flattened in level
  order (level 0 roots, then level 1, …), i.e. a topological ordering of the
  in-stack DAG. Members WITHIN a level are independent (parallel), so we
  sort each level by `stack_position` for a deterministic, creation-ordered
  tiebreak. A stack with members but ZERO declared edges collapses to a
  single level, so the result is exactly `stack_position` (creation) order.

  Fallback semantics: when the DAG is invalid (a dependency cycle or a
  cross-stack edge), `validate_dag/1` returns `{:error, ...}`; we fall back
  to `members/1`, which orders by `stack_position` (creation) order, so this
  function never crashes on a cyclic stack.
  """
  @spec members_in_merge_order(Stack.t() | binary()) :: [Task.t()]
  def members_in_merge_order(stack_or_id) do
    case validate_dag(stack_or_id) do
      {:ok, levels} ->
        Enum.flat_map(levels, fn level ->
          Enum.sort_by(level, & &1.stack_position)
        end)

      {:error, _reason, _detail} ->
        members(stack_or_id)
    end
  end

  @doc """
  Return the stack's planning execution waves — the topological levels of
  its in-stack DAG, roots-first.

  Thin wrapper over `validate_dag/1` that exposes the same level structure
  as a first-class public helper so downstream callers (the wave-gated
  planning cascade in `start_planning/1` and `advance_planning_waves/1`)
  can iterate waves without repeating Kahn's algorithm inline.

  Each inner list is a "wave" — members whose in-stack predecessors are
  satisfied by the union of prior waves. Wave 0 contains the members
  with no in-stack deps (the roots); wave N depends only on members in
  waves 0..N-1. Waves are ordered from foundational to dependent and
  each inner list is already stack-position-sorted by `validate_dag/1`.

  ## Return shape

    * `{:ok, levels}` — `levels` is `[[Task.t()]]`. Empty stack collapses
      to `{:ok, []}` — distinguishable from `{:error, :cycle, ...}` so
      the idempotency guard in `start_planning/1` can safely no-op on
      empty stacks without swallowing cycle errors.
    * `{:error, :cycle, path}` — passed through unchanged from
      `validate_dag/1`; `path` is a best-effort list of `%Task{}` along
      one offending cycle.
    * `{:error, :cross_stack_dep, %{from: from, to_task_id: to_id}}` —
      passed through unchanged from `validate_dag/1`.
    * `{:error, :stack_not_found}` — the string-id branch got an id
      that has no row. Distinct from `{:ok, []}` (empty-but-real
      stack) so callers can surface a proper error envelope.

  ## Naming intent — why a separate function, not just `validate_dag/1`

  Callers use this named entry-point rather than reaching for
  `validate_dag/1` directly so that if the DAG source is later swapped
  — e.g. once the dep-inference planner persists inferred edges into
  `tasks.dependencies` — the swap is a one-liner here and nothing at
  the cascade layer changes. Today `validate_dag/1` already reads
  `tasks.dependencies` via `build_in_stack_subgraph/2`, so inferred
  edges flow through automatically with no code change here.
  """
  @spec planning_waves(Stack.t() | binary()) ::
          {:ok, [[Task.t()]]}
          | {:error, :cycle, [Task.t()]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
          | {:error, :stack_not_found}
  def planning_waves(%Stack{} = stack), do: validate_dag(stack)

  def planning_waves(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> validate_dag(stack)
      nil -> {:error, :stack_not_found}
    end
  end

  @doc """
  Check whether a stack member's in-stack dependencies have all crossed the
  ADR 0041 §"Unblock threshold".

  An in-stack dep clears when its status is one of `in_review`, `deploying`,
  or `done` AND its `metadata["merged_into_rollup_at"]` is set. Returns
  `false` for any task whose `stack_id` is nil (non-members are out of
  scope; cross-stack deps to non-members are handled by the existing
  `done`-only sweep elsewhere). Returns `true` for a member with no
  in-stack deps (vacuously unblocked).

  Cross-stack deps (deps pointing at tasks NOT in this stack) are
  ignored here on purpose — they're gated by the existing
  `done`-threshold sweep.

  This function is the dispatch gate's contract: the dispatcher
  (`Platform.Orchestration.TaskRouterWatcher`) intentionally excludes
  `stack_pending` from its active-status set so a `stack_pending` task
  is invisible to dispatch. `unblocked_in_stack?/1` answers the
  separate question of whether the task is ready to be promoted out of
  `stack_pending` and become visible to the dispatcher — see
  `try_promote/1` below.
  """
  @spec unblocked_in_stack?(Task.t()) :: boolean()
  def unblocked_in_stack?(%Task{stack_id: nil}), do: false

  def unblocked_in_stack?(%Task{stack_id: stack_id} = task) when is_binary(stack_id) do
    member_ids =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], t.id)
      |> Repo.all()
      |> MapSet.new()

    in_stack_dep_ids =
      task
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == task.id))
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(member_ids, &1))

    case in_stack_dep_ids do
      [] ->
        true

      ids ->
        # Widened select to include `:id` so the bug-#2 reachability
        # gate below can log the offending task id when a stamp is
        # fabricated / unreachable.
        deps =
          from(t in Task,
            where: t.id in ^ids,
            select: %{id: t.id, status: t.status, metadata: t.metadata}
          )
          |> Repo.all()

        # If a declared dep id has no row (e.g. soft-deleted out from
        # under us), treat it as unmet — better to stall than to
        # falsely promote.
        # A cancelled dep releases its dependent (`MemberSet.dependency_satisfied?/1`)
        # and has no stamp sha to reach, so it is left out of the
        # reachability list below.
        length(deps) == length(ids) and
          Enum.all?(deps, &MemberSet.dependency_satisfied?/1) and
          all_dep_shas_reachable?(Enum.reject(deps, &(&1.status == "cancelled")), stack_id)
    end
  end

  # Bug #2 (task 019f708f): after `threshold_cleared?/1` confirms a stamp
  # is PRESENT, additionally verify that the stamp's SHA is actually
  # reachable from the current rollup-branch tip. A fabricated stamp
  # (or a merge that was later reverted) would otherwise silently
  # promote a dependent that expects code the rollup does not contain.
  # Only stamps that are map-shaped (`%{"sha" => sha}`) can be
  # verified; bare-string stamps predate bug #3's shape enforcement
  # and are accepted as-is to preserve existing behavior.
  defp all_dep_shas_reachable?(deps, stack_id) do
    with %Stack{rollup_branch: rollup_branch, project_id: project_id} = _stack
         when is_binary(rollup_branch) and rollup_branch != "" <-
           Repo.get(Stack, stack_id),
         {:ok, project} <- fetch_project_for_reachability(project_id),
         {:ok, repo_url} <- fetch_repo_url_for_reachability(project) do
      Enum.all?(deps, &dep_sha_reachable?(&1, repo_url, rollup_branch, project_id, stack_id))
    else
      _ ->
        # Missing stack / project / repo_url ⇒ no ground truth to
        # verify against. Fall back to the stamp-presence check only
        # (preserves pre-bug-#2 behavior for un-repo'd projects and
        # test fixtures without a git runner set up).
        true
    end
  end

  defp fetch_project_for_reachability(project_id) do
    case Tasks.get_project(project_id) do
      nil -> {:error, :project_not_found}
      project -> {:ok, project}
    end
  end

  defp fetch_repo_url_for_reachability(%{repo_url: url}) when is_binary(url) and url != "",
    do: {:ok, url}

  defp fetch_repo_url_for_reachability(_project), do: {:error, :no_repo_url}

  defp dep_sha_reachable?(
         %{metadata: %{"merged_into_rollup_at" => %{"sha" => sha}}, id: dep_id},
         repo_url,
         rollup_branch,
         project_id,
         stack_id
       )
       when is_binary(sha) and sha != "" do
    args = %{
      repo_url: repo_url,
      rollup_branch: rollup_branch,
      sha: sha,
      project_id: project_id,
      stack_id: stack_id
    }

    case StackDeployer.git_runner().sha_reachable?(args) do
      {:ok, true} ->
        true

      {:ok, false} ->
        Logger.warning(
          "[Stacks] threshold_cleared?: stamp sha #{sha} not reachable from " <>
            "#{rollup_branch}; treating as unmerged (offender=#{dep_id})"
        )

        false

      {:error, reason} ->
        Logger.warning(
          "[Stacks] threshold_cleared?: reachability check failed for " <>
            "#{dep_id} (sha=#{sha}, rollup=#{rollup_branch}): #{inspect(reason)} — " <>
            "treating as unmerged"
        )

        false
    end
  end

  # Non-map or missing-sha stamps aren't shape-verifiable yet
  # (bug #3 will enforce). Preserve the pre-bug-#2 permissive behavior:
  # if the stamp is present but not shape-verifiable, we can't check
  # reachability, so accept the stamp as-is.
  defp dep_sha_reachable?(_dep, _repo_url, _rollup_branch, _project_id, _stack_id), do: true

  @doc """
  Single source of truth (task 019f921d Gap 4) for "this member has landed
  on the rollup branch", consumed by BOTH the dep-clearance gate
  (`threshold_cleared?/1`) and the stack-PR-open gate
  (`StackDeployer.member_ready_for_pr?/1`) so the two subsystems cannot
  drift onto different status+stamp-shape contracts — the mismatch that
  rejected a genuinely-`done` member with a bare-string stamp and stranded
  the Inbox stack's rollup PR at `:not_ready`.

  A member has landed when its status is one of
  `in_review`/`deploying`/`done` AND it carries a non-nil
  `merged_into_rollup_at` stamp — the canonical `%{"sha" => sha}` map OR a
  bare ISO8601 string (the promote/sweep + manual-reconciliation shape).

  Deliberately permissive on stamp shape, mirroring the pre-existing
  `threshold_cleared?` contract exactly. The sha git-reachability check is
  layered on TOP by each caller (`member_sha_reachable?/2` /
  `dep_sha_reachable?/5`): a map stamp gets verified, a bare-string stamp
  skips it. It is NOT folded in here, so the "landed" predicate stays a
  cheap pure check and the two gates share one definition.
  """
  @spec member_landed_on_rollup?(Task.t() | map()) :: boolean()
  def member_landed_on_rollup?(%{status: status, metadata: metadata})
      when status in ["in_review", "deploying", "done"] and is_map(metadata) do
    not is_nil(Map.get(metadata, "merged_into_rollup_at"))
  end

  def member_landed_on_rollup?(_), do: false

  @doc """
  Promote a `stack_pending` member to `in_progress` iff its in-stack deps
  have all cleared the ADR 0041 §"Unblock threshold".

  Behavior:

    * Task is not in any stack (`stack_id` nil) → `:noop`.
    * Task is in a stack but not at `stack_pending` → `:noop`.
    * Task is at `stack_pending` and deps NOT cleared → `:noop`.
    * Task is at `stack_pending` and deps cleared → transitions
      `stack_pending` → `in_progress` via `Tasks.transition_task/2`. That
      call emits the standard `{:task_updated, task}` board broadcast which
      `TaskRouterWatcher` already consumes, so the dispatcher picks the
      promoted task up on the next event.

  Returns `{:ok, task}` on a successful transition, `:noop` for any
  case that should leave the task untouched, or `{:error, reason}` if
  the transition itself fails.
  """
  @spec try_promote(Task.t() | binary()) ::
          {:ok, Task.t()} | :noop | {:error, term()} | {:error, term(), map()}
  def try_promote(%Task{stack_id: nil}), do: :noop

  def try_promote(%Task{status: "stack_pending"} = task) do
    with :ok <- Tasks.require_not_quarantined(task) do
      do_try_promote(task)
    end
  end

  def try_promote(%Task{}), do: :noop

  def try_promote(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> try_promote(task)
      nil -> {:error, :task_not_found}
    end
  end

  defp do_try_promote(%Task{} = task) do
    if unblocked_in_stack?(task) do
      # `transition_task/2` returns a 3-tuple
      # `{:error, :stack_plans_pending, %{stack_id, waiting_on}}` when the
      # commencement gate is closed. Matching only the 2-tuple raised
      # CaseClauseError here; inside `remove_dependency_edge/4`'s
      # transaction that crash would have rolled back the edge removal.
      case Tasks.transition_task(task, "in_progress") do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
        {:error, reason, details} -> {:error, reason, details}
      end
    else
      :noop
    end
  end

  defp require_stack_members_not_quarantined(%Stack{} = stack) do
    stack
    |> members()
    |> require_members_not_quarantined()
  end

  defp require_members_not_quarantined(members) when is_list(members) do
    case Enum.find(members, &Tasks.quarantined?/1) do
      nil -> :ok
      %Task{} = task -> Tasks.require_not_quarantined(task)
    end
  end

  @doc """
  Given a stack and a member task that just crossed the unblock threshold
  (its `merged_into_rollup_at` was just stamped), return the list of
  current `stack_pending` members that are now unblocked.

  Pure read-side helper: does NOT mutate. The caller (the sweep) is
  responsible for transitioning the returned members to `in_progress`.
  Members already past `stack_pending` are skipped — only `stack_pending`
  rows can be auto-promoted, since they were the ones blocked.
  """
  @spec unblocked_after(Stack.t() | binary(), Task.t()) :: [Task.t()]
  def unblocked_after(stack_or_id, %Task{id: just_merged_id}) do
    stack_id =
      case stack_or_id do
        %Stack{id: id} -> id
        id when is_binary(id) -> id
      end

    stack_id
    |> members()
    |> Enum.filter(fn %Task{} = member ->
      member.status == "stack_pending" and
        just_merged_id in Tasks.dependency_task_ids(member) and
        unblocked_in_stack?(member)
    end)
  end

  @doc """
  Stack-internal dependent sweep — the second of the two unblock paths
  in the engine.

  Keyed on a stack member's `metadata["merged_into_rollup_at"]` being
  newly set (typically by the deployer when a member's branch is merged
  into the stack rollup branch). Finds every other stack member whose
  status is `stack_pending` and whose dependency list includes the
  just-merged task, then promotes any whose in-stack deps have now all
  cleared the unblock threshold via `try_promote/1`.

  Partition with the existing cross-stack sweep (`tasks.ex` ~L1031,
  `sweep_unblocked_dependents/1`): that sweep matches `status==blocked`
  and uses the `done`-threshold; this sweep matches `status==stack_pending`
  and uses the rollup-merge threshold. They do NOT overlap — distinct
  source-task statuses, distinct candidate-task statuses, distinct
  thresholds.

  Returns `{:ok, promoted}` where `promoted` is the list of `{:ok, task}`
  results from successful promotions (failures are dropped, mirroring
  the existing sweep's permissive behavior). A non-stack-member task or
  a stack member without `merged_into_rollup_at` set is a no-op
  returning `{:ok, []}`.
  """
  @spec sweep_stack_dependents(Task.t()) :: {:ok, [Task.t()]}
  def sweep_stack_dependents(%Task{stack_id: nil}), do: {:ok, []}

  def sweep_stack_dependents(%Task{metadata: metadata}) when not is_map(metadata),
    do: {:ok, []}

  def sweep_stack_dependents(%Task{stack_id: stack_id, metadata: metadata} = task)
      when is_binary(stack_id) do
    if is_nil(Map.get(metadata, "merged_into_rollup_at")) do
      {:ok, []}
    else
      promoted =
        stack_id
        |> unblocked_after(task)
        |> Enum.reduce([], fn member, acc ->
          case try_promote(member) do
            {:ok, updated} -> [updated | acc]
            _ -> acc
          end
        end)
        |> Enum.reverse()

      {:ok, promoted}
    end
  end

  # ── Deploy-tail promotion (TAIL-stall fix, 2026-07-22) ───────────────────

  @doc """
  Whether a stack member at `in_review` is ready to advance to `deploying`.

  The single source of truth for the deploy-tail readiness contract,
  shared by BOTH the event path (`advance_member_to_deploying/1`, fired on
  the last review-stage validation pass) and the timer path
  (`TaskRouterWatcher.sweep_in_review_stalls/0`, the 5-min backstop). A
  member is ready for the `in_review -> deploying` transition when:

    * its branch has been merged into the rollup — `metadata["merged_into_rollup_at"]`
      is stamped (`member_has_merged_into_rollup_at?/1`); AND
    * every validation on every stage of its current approved plan is
      `passed` (`member_review_validations_all_passed?/1`); AND
    * it has no still-pending review request (`member_pending_review_requests?/1`).

  Before this hoist the predicate lived only inside the watcher, reachable
  only on the reconcile tick. Extracting it lets the event path fire the
  exact same gate the instant the last validation passes.

  Distinct from the private `member_deploy_ready?/1` used by
  `deploy_ready?/1`: that gates the STACK-level rollup-PR open (member at
  in_review/deploying with all non-deploy validations passed); THIS gates
  the per-member `in_review -> deploying` transition and additionally
  requires the rollup-merge stamp + no pending review request.
  """
  @spec member_deploy_transition_ready?(Task.t()) :: boolean()
  def member_deploy_transition_ready?(%Task{} = task) do
    member_has_merged_into_rollup_at?(task) and
      member_review_validations_all_passed?(task) and
      not member_pending_review_requests?(task)
  end

  @doc """
  True iff the member's `metadata["merged_into_rollup_at"]` stamp is present.
  """
  @spec member_has_merged_into_rollup_at?(Task.t()) :: boolean()
  def member_has_merged_into_rollup_at?(%Task{metadata: meta}) when is_map(meta),
    do: Map.has_key?(meta, "merged_into_rollup_at")

  def member_has_merged_into_rollup_at?(_task), do: false

  @doc """
  True iff every validation on every stage of the member's current approved
  plan is `passed`. Missing plan / no stages / any-not-passed → false. A plan
  with zero validations is NOT considered passed (we want evidence, not
  silence).
  """
  @spec member_review_validations_all_passed?(Task.t()) :: boolean()
  def member_review_validations_all_passed?(%Task{id: task_id}) do
    case Tasks.current_plan(task_id) do
      %{stages: stages} when is_list(stages) ->
        all_validations =
          Enum.flat_map(stages, fn stage ->
            case stage.validations do
              vs when is_list(vs) -> vs
              _ -> []
            end
          end)

        all_validations != [] and Enum.all?(all_validations, &(&1.status == "passed"))

      _ ->
        false
    end
  end

  @doc """
  True iff the member has at least one pending review request.
  """
  @spec member_pending_review_requests?(Task.t()) :: boolean()
  def member_pending_review_requests?(%Task{id: task_id}) do
    ReviewRequests.list_pending_for_task(task_id) != []
  end

  # True iff the member's current approved plan carries any pending/running
  # validation (review work still outstanding). A member with no current plan
  # or no validations has none open (vacuously false). Used by
  # `cascade_members_to_done/2` to leave mid-review members alone.
  defp member_has_open_validations?(%Task{id: task_id}) do
    case Tasks.current_plan(task_id) do
      %{stages: stages} when is_list(stages) ->
        stages
        |> Enum.flat_map(fn stage ->
          case stage.validations do
            vs when is_list(vs) -> vs
            _ -> []
          end
        end)
        |> Enum.any?(&(&1.status in ["pending", "running"]))

      _ ->
        false
    end
  end

  @doc """
  Advance a stack member `in_review -> deploying` on the triggering event.

  Modeled on `try_promote/1`: the promote-on-event helper for the deploy
  tail. Takes a `%Task{}` or task id. Returns:

    * `{:ok, task}` on a successful `in_review -> deploying` transition;
    * `:noop` when the task is not a stack member, is not at `in_review`,
      or its deploy-ready contract (`member_deploy_ready?/1`) is not yet
      satisfied — the periodic sweep remains the backstop; and
    * `:noop` (log-and-swallow) on any transition error, so a caller inside
      a validation-update transaction is never rolled back by a promote
      failure.

  Uses `Tasks.transition_task/2` so the `deploying` finalize hook runs — a
  member whose rollup PR has ALREADY merged self-completes straight to
  `done` via `complete_no_op_member_if_rollup_merged/1`.
  """
  @spec advance_member_to_deploying(Task.t() | binary()) :: {:ok, Task.t()} | :noop
  def advance_member_to_deploying(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> advance_member_to_deploying(task)
      nil -> :noop
    end
  end

  def advance_member_to_deploying(%Task{stack_id: nil}), do: :noop

  def advance_member_to_deploying(%Task{status: status}) when status != "in_review", do: :noop

  def advance_member_to_deploying(%Task{} = task) do
    if member_deploy_transition_ready?(task) do
      case Tasks.transition_task(task, "deploying") do
        {:ok, updated} ->
          Logger.info(
            "[Stacks.advance_member_to_deploying] member #{task.id} in_review -> deploying"
          )

          {:ok, updated}

        other ->
          Logger.warning(
            "[Stacks.advance_member_to_deploying] member #{task.id} could not advance " <>
              "in_review -> deploying: " <> inspect(other)
          )

          :noop
      end
    else
      :noop
    end
  rescue
    e ->
      Logger.warning(
        "[Stacks.advance_member_to_deploying] raised for member #{task.id}: " <>
          Exception.message(e)
      )

      :noop
  catch
    :exit, reason ->
      Logger.warning(
        "[Stacks.advance_member_to_deploying] exited for member #{task.id}: " <> inspect(reason)
      )

      :noop
  end

  # ── Regression handling (ADR 0041 §"Status divergence handling") ─────────

  # Ordering for regression detection only — higher index == "further
  # along the lifecycle". `stack_pending`/`blocked`/`backlog`/`planning`
  # are intentionally treated as the same conceptual rung; the only
  # comparison that matters is whether the new rung is strictly LOWER
  # than the old rung among the execution-phase statuses.
  @status_progression %{
    "backlog" => 0,
    "planning" => 0,
    "blocked" => 0,
    "stack_pending" => 0,
    "in_progress" => 1,
    "in_review" => 2,
    "deploying" => 3,
    "done" => 4
  }

  @doc """
  Detect whether `prev_status -> new_status` is a regression in the
  ADR 0041 lifecycle order (a backward step among the execution-phase
  rungs).

  Returns `true` for transitions like `in_review -> in_progress`,
  `deploying -> in_review`, `in_progress -> stack_pending`. Returns
  `false` for forward transitions or no-ops.
  """
  @spec regression?(String.t(), String.t()) :: boolean()
  def regression?(prev, new) when is_binary(prev) and is_binary(new) do
    Map.get(@status_progression, new, 0) < Map.get(@status_progression, prev, 0)
  end

  @doc """
  Handle a stack member regressing (status moving backward).

  Per ADR 0041 §"Status divergence handling":

    1. Recompute the stack rollup status. (No-op here — already wired
       into `Tasks.maybe_finalize_transition/3`'s tail via
       `maybe_recompute_stack/1`, so we don't double-recompute.)
    2. For every downstream member (another stack member listing this
       task in its dependencies) currently at `in_progress`:
       - If the downstream has NOT committed work (heuristic: no plan
         stage has reached `status: "passed"`) AND its unblock
         threshold is no longer met → revert it to `stack_pending` via
         `Tasks.transition_task/2`.
       - Otherwise leave its status alone and stamp
         `metadata["stack_dep_regressed_at"]` with the current
         timestamp so the UI / operator can see that an upstream dep
         regressed.

  Cross-stack regressions are silenced: a task without a `stack_id`
  short-circuits with `:ok` (the existing done-threshold sweep is the
  cross-stack path and is NOT modified by this handler).

  Returns `{:ok, %{reverted: [Task.t()], flagged: [Task.t()]}}` on
  success.
  """
  @spec handle_member_regression(Task.t(), String.t()) ::
          :ok | {:ok, %{reverted: [Task.t()], flagged: [Task.t()]}}
  def handle_member_regression(%Task{stack_id: nil}, _prev_status), do: :ok

  def handle_member_regression(%Task{stack_id: stack_id} = task, _prev_status)
      when is_binary(stack_id) do
    members = members(stack_id)
    member_ids = MapSet.new(members, & &1.id)

    downstream =
      members
      |> Enum.reject(&(&1.id == task.id))
      |> Enum.filter(fn member ->
        task.id in (member
                    |> Tasks.dependency_task_ids()
                    |> Enum.filter(&MapSet.member?(member_ids, &1)))
      end)

    Enum.reduce(downstream, {[], []}, fn member, {reverted, flagged} ->
      cond do
        member.status != "in_progress" ->
          {reverted, flagged}

        unblocked_in_stack?(member) ->
          # Threshold still met — no need to revert. Don't flag either,
          # since nothing was actually invalidated.
          {reverted, flagged}

        committed_work?(member) ->
          # Threshold no longer met but work exists — record the regression
          # marker without disrupting the in-flight task.
          case mark_dep_regressed(member) do
            {:ok, updated} -> {reverted, [updated | flagged]}
            _ -> {reverted, flagged}
          end

        true ->
          case Tasks.transition_task(member, "stack_pending") do
            {:ok, updated} -> {[updated | reverted], flagged}
            _ -> {reverted, flagged}
          end
      end
    end)
    |> then(fn {reverted, flagged} ->
      {:ok, %{reverted: Enum.reverse(reverted), flagged: Enum.reverse(flagged)}}
    end)
  end

  # "Committed work" heuristic: any stage on any plan for this task has
  # reached `status: "passed"` (the engine's stage_complete signal).
  defp committed_work?(%Task{id: task_id}) do
    Repo.exists?(
      from(s in Platform.Tasks.Stage,
        join: p in Platform.Tasks.Plan,
        on: s.plan_id == p.id,
        where: p.task_id == ^task_id and s.status == "passed"
      )
    )
  end

  defp mark_dep_regressed(%Task{} = member) do
    metadata = member.metadata || %{}
    stamp = DateTime.utc_now() |> DateTime.to_iso8601()
    merged = Map.put(metadata, "stack_dep_regressed_at", stamp)
    Tasks.update_task(member, %{metadata: merged})
  end

  # ── Membership internals ─────────────────────────────────────────────────

  # Always reload from the DB so callers can hand us potentially-stale
  # structs without false negatives on membership checks.
  defp load_stack(%Stack{id: id}), do: load_stack(id)

  defp load_stack(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      %Stack{} = stack -> {:ok, stack}
      nil -> {:error, :stack_not_found}
    end
  end

  defp load_task(%Task{id: id}), do: load_task(id)

  defp load_task(task_id) when is_binary(task_id) do
    case Repo.get(Task, task_id) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, :task_not_found}
    end
  end

  defp ensure_not_in_stack(%Task{stack_id: nil}), do: :ok
  defp ensure_not_in_stack(%Task{}), do: {:error, :already_in_stack}

  defp ensure_in_stack(%Stack{id: stack_id}, %Task{stack_id: stack_id}), do: :ok
  defp ensure_in_stack(_stack, %Task{id: task_id}), do: {:error, :not_in_stack, task_id}

  defp ensure_no_in_stack_dependents(%Stack{id: stack_id}, %Task{id: task_id}) do
    member_ids =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], t.id)
      |> Repo.all()
      |> MapSet.new()

    dependents =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at) and t.id != ^task_id)
      |> Repo.all()
      |> Enum.filter(fn member ->
        task_id in (member
                    |> Tasks.dependency_task_ids()
                    |> Enum.filter(&MapSet.member?(member_ids, &1)))
      end)
      |> Enum.map(fn %Task{id: id, title: title} -> %{id: id, title: title} end)

    case dependents do
      [] -> :ok
      _ -> {:error, {:has_dependents, dependents}}
    end
  end

  defp next_stack_position(stack_id) when is_binary(stack_id) do
    max_pos =
      Task
      |> where([t], t.stack_id == ^stack_id and is_nil(t.deleted_at))
      |> select([t], max(t.stack_position))
      |> Repo.one()

    (max_pos || 0) + 1
  end

  # ── DAG internals ────────────────────────────────────────────────────────

  # Walk every member's declared dependencies and partition each edge:
  #
  #   * self-edges → silently dropped (matches `unmet_dependencies/1`).
  #   * dep target IS a member of THIS stack → retained as an in-stack edge.
  #   * dep target is some other task whose `stack_id` is non-nil and
  #     differs from this stack → reject as `:cross_stack_dep`.
  #   * dep target is unknown or has no stack → silently dropped per ADR
  #     0041 §"DAG validation" point 3 (allowed cross-stack-to-non-stack).
  #
  # The cross-stack lookup hits the DB exactly once: we batch every
  # not-in-stack dep id and ask Postgres for their `stack_id`s.
  @spec build_in_stack_subgraph([Task.t()], String.t()) ::
          {:ok, [{String.t(), String.t()}]}
          | {:error, :cross_stack_dep, %{from: Task.t(), to_task_id: String.t()}}
  defp build_in_stack_subgraph(members, stack_id) do
    member_ids = MapSet.new(members, & &1.id)

    # First pass: filter self-edges, classify each remaining edge as
    # in-stack vs. external (deferred check).
    {in_stack_edges, external_edges, external_ids} =
      Enum.reduce(members, {[], [], MapSet.new()}, fn %Task{id: from_id} = member,
                                                      {in_acc, ext_acc, ext_ids} ->
        member
        |> Tasks.dependency_task_ids()
        |> Enum.reject(&(&1 == from_id))
        |> Enum.uniq()
        |> Enum.reduce({in_acc, ext_acc, ext_ids}, fn dep_id, {ia, ea, ei} ->
          cond do
            MapSet.member?(member_ids, dep_id) ->
              {[{from_id, dep_id} | ia], ea, ei}

            true ->
              {ia, [{member, dep_id} | ea], MapSet.put(ei, dep_id)}
          end
        end)
      end)

    # Second pass: a single DB hit to resolve `stack_id` for every
    # external dep target. Anything with a non-nil stack_id ≠ ours is
    # a cross-stack edge.
    foreign_stack_by_id =
      case MapSet.size(external_ids) do
        0 ->
          %{}

        _ ->
          ids = MapSet.to_list(external_ids)

          from(t in Task,
            where: t.id in ^ids and not is_nil(t.stack_id) and t.stack_id != ^stack_id,
            select: {t.id, t.stack_id}
          )
          |> Repo.all()
          |> Map.new()
      end

    case Enum.find(external_edges, fn {_member, dep_id} ->
           Map.has_key?(foreign_stack_by_id, dep_id)
         end) do
      nil ->
        {:ok, in_stack_edges}

      {from_member, dep_id} ->
        {:error, :cross_stack_dep, %{from: from_member, to_task_id: dep_id}}
    end
  end

  # Kahn's algorithm over the in-stack subgraph.
  #
  # Edges have shape `{from_id, to_id}` meaning "`from` depends on
  # `to`". Execution flows in the reverse direction: `to` must run
  # first, and `from`'s in-degree counts *outgoing* dep edges (number
  # of in-stack tasks `from` waits on).
  #
  # Each level pops every member whose remaining wait-count is zero,
  # then decrements the wait-count of every member that was depending
  # on a popped node. Continues until the graph drains; if any node
  # remains with a non-zero wait-count, returns `{:error, :cycle, ids}`
  # with the residue id list.
  @spec kahn_levels([Task.t()], [{String.t(), String.t()}]) ::
          {:ok, [[Task.t()]]} | {:error, :cycle, [String.t()]}
  defp kahn_levels(members, edges) do
    by_id = Map.new(members, &{&1.id, &1})

    # in_degree[id] = number of in-stack deps `id` is still waiting on.
    in_degree =
      Enum.reduce(members, %{}, fn %Task{id: id}, acc -> Map.put(acc, id, 0) end)
      |> then(fn acc ->
        Enum.reduce(edges, acc, fn {from_id, _to_id}, a ->
          Map.update(a, from_id, 1, &(&1 + 1))
        end)
      end)

    # reverse_adj[to_id] = ids that depend on `to_id`. When `to_id`
    # pops, decrement each of these.
    reverse_adj =
      Enum.reduce(edges, %{}, fn {from_id, to_id}, acc ->
        Map.update(acc, to_id, [from_id], &[from_id | &1])
      end)

    do_kahn_levels(by_id, in_degree, reverse_adj, [])
  end

  defp do_kahn_levels(by_id, in_degree, _reverse_adj, levels) when map_size(in_degree) == 0 do
    {:ok, Enum.reverse(levels) |> Enum.reject(&(&1 == [])) |> hydrate_levels(by_id)}
  end

  defp do_kahn_levels(by_id, in_degree, reverse_adj, levels) do
    {ready_ids, remaining} =
      Enum.split_with(in_degree, fn {_id, deg} -> deg == 0 end)

    case ready_ids do
      [] ->
        # Nothing has zero in-degree → cycle in the residue.
        {:error, :cycle, Enum.map(remaining, fn {id, _} -> id end)}

      _ ->
        ready_ids = Enum.map(ready_ids, fn {id, _} -> id end)
        remaining = Map.new(remaining)

        next_in_degree =
          Enum.reduce(ready_ids, remaining, fn popped_id, acc ->
            popped_id
            |> then(&Map.get(reverse_adj, &1, []))
            |> Enum.reduce(acc, fn dependent_id, a ->
              case Map.get(a, dependent_id) do
                nil -> a
                deg -> Map.put(a, dependent_id, deg - 1)
              end
            end)
          end)

        do_kahn_levels(by_id, next_in_degree, reverse_adj, [ready_ids | levels])
    end
  end

  defp hydrate_levels(levels, by_id) do
    Enum.map(levels, fn ids -> Enum.map(ids, &Map.fetch!(by_id, &1)) end)
  end

  # Best-effort cycle recovery: starting from any node still in the
  # residue, follow outgoing edges (`from → to`, i.e. the dependency
  # arrow) until we revisit a node. The walk is bounded by the residue
  # size, so a cycle must be hit before we run out of frontier — even
  # for diamond-shaped residues every dep chain bottoms out in a back
  # edge by definition (otherwise Kahn would have drained it).
  #
  # Returns the cycle as a list of `%Task{}` in dependency order.
  @spec find_cycle([String.t()], [{String.t(), String.t()}], [Task.t()]) :: [Task.t()]
  defp find_cycle([], _edges, _members), do: []

  defp find_cycle([start | _] = residue_ids, edges, members) do
    by_id = Map.new(members, &{&1.id, &1})
    residue = MapSet.new(residue_ids)

    # Restrict to edges fully inside the residue so we only walk
    # cycle-relevant arrows.
    adj =
      Enum.reduce(edges, %{}, fn {from_id, to_id}, acc ->
        if MapSet.member?(residue, from_id) and MapSet.member?(residue, to_id) do
          Map.update(acc, from_id, [to_id], &[to_id | &1])
        else
          acc
        end
      end)

    walk_cycle(start, adj, [], MapSet.new())
    |> Enum.map(&Map.get(by_id, &1))
    |> Enum.reject(&is_nil/1)
  end

  # Walks one path through the residue subgraph until it repeats a
  # node, then returns just the cycle (slice from the first occurrence
  # of the repeated node onward). If the path dead-ends (no outgoing
  # adj), returns the visited path as a best-effort.
  defp walk_cycle(node, adj, path, visited) do
    cond do
      MapSet.member?(visited, node) ->
        # Found the cycle — slice `path` from the first occurrence of
        # `node`. `path` is in reverse-walk order (head = most recent).
        ordered = Enum.reverse([node | path])
        idx = Enum.find_index(ordered, &(&1 == node))
        Enum.slice(ordered, idx..-1//1)

      true ->
        case Map.get(adj, node, []) do
          [] -> Enum.reverse([node | path])
          [next | _] -> walk_cycle(next, adj, [node | path], MapSet.put(visited, node))
        end
    end
  end

  # ── Pure helpers ─────────────────────────────────────────────────────────

  @doc """
  Return the normalized stack-level `phase_assignees` map from a stack's
  metadata (ADR 0041 stack-level agent assignment).

  Mirrors `Platform.Tasks.Task.validate_phase_assignees/1`: unknown phase
  keys are dropped, and malformed per-phase entries (anything that is not
  a map with at least an `"assignee_id"`) are dropped. Defaults to `%{}`
  for a stack with no metadata, non-map metadata, or no `"phase_assignees"`
  key. The `@phases` list is reused from `Platform.Tasks.Task` rather than
  redefined here.

  Returned shape: `%{phase => %{"assignee_id" => uuid, "assignee_type" => type}}`.
  """
  @spec stack_phase_assignees(Stack.t() | map() | nil) :: map()
  def stack_phase_assignees(%Stack{metadata: metadata}), do: stack_phase_assignees(metadata)

  def stack_phase_assignees(metadata) when is_map(metadata) do
    case Map.get(metadata, "phase_assignees") do
      pa when is_map(pa) ->
        pa
        |> Map.take(Task.phases())
        |> Enum.flat_map(fn {phase, entry} ->
          case normalize_phase_entry(entry) do
            nil -> []
            normalized -> [{phase, normalized}]
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  def stack_phase_assignees(_), do: %{}

  # A valid per-phase entry is a map carrying a non-nil `"assignee_id"`.
  # `"assignee_type"` defaults to `"agent"` (matching `Tasks.assignee_for_phase/2`).
  defp normalize_phase_entry(%{"assignee_id" => nil}), do: nil

  defp normalize_phase_entry(%{"assignee_id" => id} = entry) when is_binary(id) do
    %{"assignee_id" => id, "assignee_type" => Map.get(entry, "assignee_type") || "agent"}
  end

  defp normalize_phase_entry(_), do: nil

  @doc """
  Return `{assignee_id, assignee_type}` for the stack-level default in the
  given phase, or `{nil, nil}` if no stack-level assignee is configured for
  that phase.

  Mirrors `Platform.Tasks.assignee_for_phase/2`, but reads from the stack's
  `metadata["phase_assignees"]` (via `stack_phase_assignees/1`) instead of a
  task's `phase_assignees`.
  """
  @spec stack_assignee_for_phase(Stack.t() | map() | nil, String.t()) ::
          {String.t() | nil, String.t() | nil}
  def stack_assignee_for_phase(stack_or_metadata, phase) when is_binary(phase) do
    case stack_phase_assignees(stack_or_metadata) |> Map.get(phase) do
      %{"assignee_id" => id, "assignee_type" => type} -> {id, type}
      _ -> {nil, nil}
    end
  end

  @doc """
  Resolve the planning-phase assignee for a stack member.

  Returns `{assignee_id, assignee_type}`, resolved in this order:

    1. `Platform.Tasks.assignee_for_phase(member, "planning")` — which
       already folds in the top-level `assignee_id`/`assignee_type`
       fallback, so this must not be reimplemented here.
    2. `stack_assignee_for_phase(stack, "planning")` — the stack-level
       ADR-0041 default, used only when the task resolves to `{nil, nil}`.
    3. `{nil, nil}` when neither supplies one.
  """
  @spec resolve_planning_assignee(Task.t(), Stack.t() | nil) ::
          {String.t() | nil, String.t() | nil}
  def resolve_planning_assignee(member, stack \\ nil)

  def resolve_planning_assignee(%Task{} = member, stack) do
    case Tasks.assignee_for_phase(member, "planning") do
      {nil, nil} -> stack_assignee_for_phase(stack, "planning")
      pair -> pair
    end
  end

  def resolve_planning_assignee(_, _), do: {nil, nil}

  @doc """
  True only when `resolve_planning_assignee/2` yields an agent-typed
  assignee with a non-nil id.

  Mirrors `Platform.Orchestration.TaskRouterWatcher.should_run?/1`, which
  requires `assignee_type == "agent"` AND a non-nil `assignee_id`: a
  human-typed planning assignee never starts a router, so for cascade
  purposes such a member is as unassigned as one with no assignee at all.
  """
  @spec dispatchable_planning_assignee?(Task.t(), Stack.t() | nil) :: boolean()
  def dispatchable_planning_assignee?(member, stack \\ nil) do
    case resolve_planning_assignee(member, stack) do
      {id, "agent"} when is_binary(id) -> true
      _ -> false
    end
  end

  # ── Stack-level agent assignment (ADR 0041) ──────────────────────────────

  @doc """
  Set the stack-level `phase_assignees` default and percolate it to every
  member that is not individually overridden.

  `attrs_by_phase` is a map keyed by phase (`"planning"` | `"execution"` |
  `"review"`) with values `%{"assignee_id" => id, "assignee_type" => type}`,
  identical to the shape `Platform.Tasks.set_phase_assignees/2` accepts.

  In a single `Repo.transaction`:

    1. The normalized map is merged into `stack.metadata["phase_assignees"]`
       and persisted via `update_stack/2`. Other metadata keys are
       preserved; the `phase_assignees` subtree is merged phase-by-phase so
       a partial update (e.g. only `"execution"`) leaves the other phases
       intact.
    2. For every member returned by `members/1` whose
       `metadata["assignee_override"]` is NOT `true`, the merged
       stack-level map is applied via `Platform.Tasks.set_phase_assignees/2`.
       That reuses the existing changeset + `maybe_apply_phase_assignee`
       re-derivation + board broadcast, so the task router and every read
       path see the new current-phase assignee.

  Members flagged `assignee_override` are skipped entirely — a stack-level
  reassignment must never clobber an individually-assigned member.

  Returns `{:ok, %{stack: stack, percolated: [task], skipped: [task]}}` on
  success, where `percolated` are the members that received the new
  default and `skipped` are the overridden members left untouched.
  """
  @spec set_stack_phase_assignees(Stack.t() | binary(), map()) ::
          {:ok, %{stack: Stack.t(), percolated: [Task.t()], skipped: [Task.t()]}}
          | {:error, :stack_not_found | term()}
  def set_stack_phase_assignees(stack_or_id, attrs_by_phase) when is_map(attrs_by_phase) do
    Repo.transaction(fn ->
      with {:ok, %Stack{} = stack} <- load_stack(stack_or_id),
           merged_map = merge_stack_phase_assignees(stack, attrs_by_phase),
           new_metadata = Map.put(stack.metadata || %{}, "phase_assignees", merged_map),
           {:ok, updated_stack} <- update_stack(stack, %{metadata: new_metadata}) do
        {percolated, skipped} =
          updated_stack
          |> members()
          |> Enum.split_with(&(not member_overridden?(&1)))

        percolated_tasks =
          Enum.map(percolated, fn member ->
            case Tasks.set_phase_assignees(member, merged_map) do
              {:ok, updated} -> updated
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        %{stack: updated_stack, percolated: percolated_tasks, skipped: skipped}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Return the current stack-level `phase_assignees` default merged with a
  partial `attrs_by_phase` update.

  The merge is phase-by-phase: phases present in `attrs_by_phase` replace
  the stored phase entry; phases absent from `attrs_by_phase` are carried
  through from the existing stack-level map. The result is normalized via
  `stack_phase_assignees/1` semantics (unknown keys / malformed entries
  dropped) so the persisted map is always well-formed.
  """
  @spec merge_stack_phase_assignees(Stack.t() | map() | nil, map()) :: map()
  def merge_stack_phase_assignees(stack_or_metadata, attrs_by_phase)
      when is_map(attrs_by_phase) do
    current = stack_phase_assignees(stack_or_metadata)

    incoming =
      attrs_by_phase
      |> Map.new(fn {phase, entry} -> {to_string(phase), entry} end)
      |> Map.take(Task.phases())
      |> Enum.flat_map(fn {phase, entry} ->
        case normalize_phase_entry(entry) do
          nil -> [{phase, :clear}]
          normalized -> [{phase, normalized}]
        end
      end)
      |> Map.new()

    Enum.reduce(incoming, current, fn
      {phase, :clear}, acc -> Map.delete(acc, phase)
      {phase, entry}, acc -> Map.put(acc, phase, entry)
    end)
  end

  @doc """
  Whether a stack member is individually overridden — i.e. its
  `metadata["assignee_override"]` is `true`.

  An overridden member is excluded from stack-level fan-out: its assignment
  was set by hand and stack-level reassignment must not touch it.
  """
  @spec member_overridden?(Task.t() | map() | nil) :: boolean()
  def member_overridden?(%Task{metadata: metadata}), do: member_overridden?(metadata)

  def member_overridden?(metadata) when is_map(metadata),
    do: Map.get(metadata, "assignee_override") == true

  def member_overridden?(_), do: false

  @doc """
  Clear a member's individual override and return it to inheriting the
  stack-level default.

  Unsets `task.metadata["assignee_override"]` and, if the member's stack
  has a stack-level `phase_assignees` map, re-applies that default via
  `Platform.Tasks.set_phase_assignees/2`. Runs in a single transaction.

  Returns `{:ok, task}` (the re-inheriting member), `{:error, :not_in_stack}`
  for a task with no `stack_id`, `{:error, :task_not_found}` /
  `{:error, :stack_not_found}` for missing rows, or `{:error, reason}` if a
  write fails.
  """
  @spec clear_member_override(Task.t() | binary()) ::
          {:ok, Task.t()}
          | {:error, :not_in_stack | :task_not_found | :stack_not_found | term()}
  def clear_member_override(task_or_id) do
    Repo.transaction(fn ->
      with {:ok, %Task{} = task} <- load_task(task_or_id),
           :ok <- ensure_has_stack(task),
           {:ok, %Stack{} = stack} <- load_stack(task.stack_id),
           cleared_metadata = Map.delete(task.metadata || %{}, "assignee_override"),
           {:ok, cleared_task} <- Tasks.update_task(task, %{metadata: cleared_metadata}) do
        stack_map = stack_phase_assignees(stack)

        if stack_map == %{} do
          cleared_task
        else
          case Tasks.set_phase_assignees(cleared_task, stack_map) do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Apply the stack-level default to a freshly-attached member, unless the
  # member is individually overridden or the stack has no stack-level map.
  # Used inside `add_task/2`'s transaction.
  defp maybe_inherit_stack_assignees(%Stack{} = stack, %Task{} = task) do
    stack_map = stack_phase_assignees(stack)

    cond do
      stack_map == %{} -> {:ok, task}
      member_overridden?(task) -> {:ok, task}
      true -> Tasks.set_phase_assignees(task, stack_map)
    end
  end

  defp ensure_has_stack(%Task{stack_id: nil}), do: {:error, :not_in_stack}
  defp ensure_has_stack(%Task{stack_id: stack_id}) when is_binary(stack_id), do: :ok

  @doc """
  Build the canonical rollup-branch name for a slug.

  Mirrors the convention documented in ADR 0041 (Branch model) so callers
  do not assemble the prefix in multiple places.
  """
  @spec rollup_branch_name(String.t()) :: String.t()
  def rollup_branch_name(slug) when is_binary(slug), do: "stack/#{slug}"

  @doc """
  Validate a stack slug.

  Slugs must be lowercase alphanumeric with optional hyphens, must start
  with an alphanumeric character, and must be 60 characters or fewer.
  """
  @spec valid_slug?(any()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    String.length(slug) <= @max_slug_length and Regex.match?(@slug_regex, slug)
  end

  def valid_slug?(_), do: false

  # ── Migration-slot allocator ─────────────────────────────────────────────

  @doc """
  Reserve the next free Ecto migration timestamp for a stack.

  Returns `{:ok, "YYYYMMDDHHMMSS"}` — the canonical filename prefix
  `mix ecto.gen.migration` produces — guaranteeing that two members of the
  same stack never receive the same string.

  ## Why this exists

  Stack members implement on independent worktrees and each run
  `mix ecto.gen.migration` themselves. Two members generating within the
  same second produce identical `YYYYMMDDHHMMSS` prefixes; Ecto then
  silently skips one migration and the failure surfaces far downstream as
  unrelated-looking test breakage (observed 2026-07-17: a 6-member stack
  where two members both minted `20260717000000`).

  ## Design

  * The cursor is a `NaiveDateTime`, not an integer counter, so timestamps
    stay chronologically meaningful. A stack dormant for weeks gets a slot
    reflecting wall clock rather than `base + N`.
  * `candidate = max(current, now)` means wall-clock jitter (NTP step,
    clock skew between hosts) can never regress the sequence: the cursor
    only ever moves forward.
  * Serialization uses `pg_advisory_xact_lock`, mirroring the rollup-branch
    idiom in `Platform.Tasks.StackDeployer` rather than `SELECT ... FOR
    UPDATE`. The key hashes `{"migration_slot", stack_id}` — deliberately
    NOT `stack_id` alone, which the rollup-branch lock already uses — so
    allocating a slot never contends with a rollup-branch operation on the
    same stack.
  * Transaction-scoped locks release on commit/rollback, so there is no
    leak path. Under the test sandbox all callers share one connection, so
    the lock is re-entrant and the connection itself provides the
    serialization; the observable uniqueness contract is preserved either
    way.
  """
  @spec allocate_migration_slot(Stack.t() | binary()) ::
          {:ok, String.t()} | {:error, :stack_not_found | Ecto.Changeset.t()}
  def allocate_migration_slot(%Stack{id: stack_id}), do: allocate_migration_slot(stack_id)

  def allocate_migration_slot(stack_id) when is_binary(stack_id) do
    result =
      Repo.transaction(fn ->
        lock_key = :erlang.phash2({"migration_slot", stack_id}, 2_147_483_647)
        Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key])

        # Read INSIDE the lock — a stack struct passed in by the caller may
        # carry a stale cursor from before a sibling's allocation.
        case Repo.get(Stack, stack_id) do
          nil ->
            Repo.rollback(:stack_not_found)

          %Stack{} = stack ->
            now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

            candidate =
              case stack.next_migration_slot do
                nil -> now
                current -> if NaiveDateTime.compare(current, now) == :gt, do: current, else: now
              end

            next = NaiveDateTime.add(candidate, 1, :second)

            case stack
                 |> Stack.changeset(%{next_migration_slot: next})
                 |> Repo.update() do
              {:ok, _updated} -> Calendar.strftime(candidate, "%Y%m%d%H%M%S")
              {:error, changeset} -> Repo.rollback(changeset)
            end
        end
      end)

    case result do
      {:ok, formatted_ts} -> {:ok, formatted_ts}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Audit the migration slots reserved across every member of a stack.

  Flattens `metadata["reserved_migration_slots"]` over all (non-deleted)
  members and reports any timestamp claimed more than once.

  Returns `{:ok, %{slots: [...], collisions: []}}` when every reserved
  timestamp is unique, or `{:error, :collision, offenders}` where each
  offender is `%{timestamp: ts, offenders: [task_id, ...]}`.

  ## Why this exists

  `allocate_migration_slot/1` makes collisions impossible *for slots it
  issues*. This audit catches the cases where the allocator was never
  consulted: the plan-approval detection regex missed a migration-authoring
  stage, a plan was hand-authored, or an executor minted its own timestamp
  instead of using the reserved one. Those bypass paths are exactly how the
  2026-07-17 M1/M4 incident produced two members both claiming
  `20260717000000` — a failure that surfaced far downstream as
  unrelated-looking test breakage.

  Callers treat this as an observability signal, never a gate:
  `advance_planning_waves/1` logs and emits telemetry on a collision but
  still dispatches the wave. A backstop that silently blocks work is worse
  than the problem it guards against.

  Malformed metadata (non-list value, entries missing `"timestamp"`,
  blank timestamps) is skipped rather than raising — this runs on the
  dispatch path and must never be the reason a wave fails.
  """
  @spec audit_migration_slots(Stack.t() | binary()) ::
          {:ok, %{slots: [map()], collisions: []}}
          | {:error, :collision, [%{timestamp: String.t(), offenders: [String.t()]}]}
          | {:error, :stack_not_found}
  def audit_migration_slots(%Stack{} = stack), do: do_audit_migration_slots(stack)

  def audit_migration_slots(stack_id) when is_binary(stack_id) do
    case Repo.get(Stack, stack_id) do
      nil -> {:error, :stack_not_found}
      %Stack{} = stack -> do_audit_migration_slots(stack)
    end
  end

  defp do_audit_migration_slots(%Stack{} = stack) do
    slots =
      stack
      |> members()
      |> Enum.flat_map(&reserved_slots_for_member/1)

    collisions =
      slots
      |> Enum.group_by(& &1.timestamp)
      |> Enum.filter(fn {_ts, entries} -> length(entries) > 1 end)
      |> Enum.map(fn {ts, entries} ->
        %{
          timestamp: ts,
          offenders: entries |> Enum.map(& &1.task_id) |> Enum.uniq() |> Enum.sort()
        }
      end)
      |> Enum.sort_by(& &1.timestamp)

    case collisions do
      [] -> {:ok, %{slots: slots, collisions: []}}
      _ -> {:error, :collision, collisions}
    end
  end

  defp reserved_slots_for_member(%Task{} = task) do
    entries =
      case task.metadata do
        %{} = meta -> Map.get(meta, "reserved_migration_slots")
        _ -> nil
      end

    case entries do
      list when is_list(list) ->
        Enum.flat_map(list, fn
          %{"timestamp" => ts} = entry when is_binary(ts) and ts != "" ->
            [
              %{
                task_id: task.id,
                timestamp: ts,
                stage_id: Map.get(entry, "stage_id"),
                stage_name: Map.get(entry, "stage_name")
              }
            ]

          _ ->
            []
        end)

      _ ->
        []
    end
  end
end
