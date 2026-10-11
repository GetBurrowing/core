defmodule Platform.Responsibilities.Janitor do
  @moduledoc """
  Server-side eligibility, exclusion policy, and bounded claiming for the
  `janitor.cron_drain` responsibility (task `019fa1ac-6685` stage 2).

  The janitor handler (`Handlers.JanitorCronDrain`) calls `claim/1` from
  `gather_context/2`, which the Responsibilities Router reaches only after
  its assignment gate has resolved a `janitor` assignee. This module never
  decides whether the janitor is enabled; it decides WHICH tasks the
  enabled janitor may take, and that decision is authoritative — the model
  receives the claimed ids and never re-derives or widens them.

  ## Eligibility: conjunctive, server-enforced

  A task is a candidate only when ALL of these hold, read from the
  persisted row:

    * `status == "backlog"`
    * `kind == "chore"` (taxonomy from task `019fa1ac-00ef`)
    * `origin == "internal"` and `trust == "trusted"` (provenance/trust
      from task `01a11ec3`; the base query is
      `Platform.Tasks.trusted_internal_chore_query/0`, consumed rather than
      restated)
    * not soft-deleted, and not already handled by the janitor
      (`metadata.handled_by == "janitor"`, whatever the disposition), so a
      refused, claimed, or handed-back task is never picked up twice.

  The same predicate is re-checked in Elixir on every locked row before
  any write (`eligible?/1`), so a widened query could not by itself let an
  external-feedback or quarantined row through.

  ## Order and cap

  Architect-sweep chores (`metadata.filed_by == "architect_cron_sweep"`)
  first, then every other chore, each group oldest first (`inserted_at`,
  then `id` as the deterministic tie-break). At most
  `max_tasks_per_run/0` (3) tasks are CLAIMED per run. Every eligible task
  past the cap is not locked, not read for writing, and not modified.

  ## Concurrency: one transaction, `FOR UPDATE SKIP LOCKED`

  Candidates are selected and locked in batches inside one transaction
  with `FOR UPDATE SKIP LOCKED`. A second, overlapping run does not wait
  for and does not see the rows the first run holds; it moves on to the
  next unlocked candidates. Once the first run commits, its rows carry
  `handled_by: "janitor"` and fall out of the candidate query, so a later
  run cannot re-claim them either.

  Batches are sized to the claims still owed (`cap - claimed`) so a run
  locks only rows it is about to dispose of. Refused rows count toward
  `@scan_limit` (not toward the cap), bounding the work of a run that
  meets a long run of dangerous chores.

  ## Exclusion policy: conservative, before any auto-approval

  `evaluate/1` runs over the normalized (downcased) title and description
  and over declared paths: string lists under `metadata["paths"]`,
  `metadata["files"]`, `metadata["declared_paths"]`, `metadata["refs"]`,
  plus path-shaped tokens found in the text. It refuses:

    * `"vault"` — any `vault.ex` / vault module (`**/vault.ex`, `**/vault/**`)
    * `"database_migration"` — migrations and schema changes
      (`**/priv/repo/migrations/**`, `**/migrations/**`, `**/structure.sql`)
    * `"auth_or_secrets"` — authentication, authorization, credentials,
      secrets (`**/auth/**`, `**/*auth*`, `**/accounts/**`, `**/*oidc*`,
      `**/*secret*`, ...)
    * `"tenancy_boundary"` — tenant, cross-tenant, org-boundary scope
      (`**/tenancy/**`, `**/*tenan*`, `**/external_scope*`)
    * `"deploy_runtime_config"` — release/deploy/container/workflow/runtime
      configuration (`**/config/*.exs`, `**/rel/**`, `**/dockerfile*`,
      `**/.github/workflows/**`, `**/*.service`, `**/*.tf`, ...)
    * `"ambiguous_scope"` — scope the policy cannot read: a blank title, a
      description shorter than `@min_description_chars`, or a declared-path
      key whose value is not a list of strings. Unknown is ineligible, never
      presumed safe.

  The first matching category (in the order above) is the stable reason
  code; the matched keyword or path is kept as `janitor_reason_detail`.

  ## Writes, all through `Platform.Tasks`

  Refused: stays `backlog`, `auto_approve_plan: false`, metadata MERGED
  with `handled_by`, `janitor_disposition: "refused"`, `janitor_reason`,
  `janitor_reason_detail`, `janitor_at`, `janitor_run_id`.

  Claimed: first `Tasks.set_phase_assignees/2` puts the janitor agent on
  the planning and execution slots; only then does `Tasks.update_task/3`
  merge `handled_by`, `janitor_disposition: "claimed"`, `janitor_at`,
  `janitor_run_id`, `janitor_agent_id` and set `auto_approve_plan: true`.
  `claim/1` does not move status; `route_claimed/2` does, after the claim
  commits (stage 3).

  ## Routing, hand-back and audit (stage 3)

    * `route_claimed/2` moves exactly the claimed batch `backlog -> planning`
      through `Tasks.transition_task/3`, so the TaskRouter owns each claim
      from then on. It never reads the backlog itself.
    * `hand_back/3` is the escalation path, exposed to the janitor agent as
      the `janitor_hand_back` MCP tool. It is atomic and keeps all prior
      metadata; a forbidden path among `:paths` forces its category as the
      reason.
    * `reconcile_stranded/1` hands back claims a dead run left in `backlog`.
    * `record_run/3` writes `audit_events` rows and execution-space log
      lines. No other store is written.

  Existing metadata, including `filed_by`, is preserved by `Map.merge/2`
  over the LOCKED row's metadata, never a stale caller struct.
  """

  import Ecto.Query

  require Logger

  alias Platform.Audit
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.Task

  @max_tasks_per_run 3
  # Upper bound on rows a single run may dispose of (claims + refusals).
  @scan_limit 25
  @min_description_chars 20

  @architect_filed_by "architect_cron_sweep"
  @handled_by "janitor"

  @declared_path_keys ~w(paths files declared_paths refs)

  @reason_codes ~w(vault database_migration auth_or_secrets tenancy_boundary deploy_runtime_config ambiguous_scope)

  # The excluded-scope subset of `@reason_codes`: discovering any of these
  # after a claim is a MANDATORY hand-back (stage 3).
  @forbidden_scope_codes ~w(vault database_migration auth_or_secrets tenancy_boundary deploy_runtime_config)

  # Stable hand-back reason codes. The forbidden-scope codes first, then the
  # reasons that are not about scope.
  #
  #   * `not_small`         — inspection showed the chore is not small
  #   * `ambiguous_scope`   — inspection could not bound the change
  #   * `routing_refused`   — the server could not move the claim into planning
  #   * `stack_member`      — a stack owns the member's backlog -> planning hop
  #   * `claim_not_routed`  — a committed claim was found still in backlog on a
  #                           later run (the run that claimed it died first)
  @hand_back_reasons @forbidden_scope_codes ++
                       ~w(ambiguous_scope not_small routing_refused stack_member claim_not_routed)

  # The automated transition table has no `in_progress -> backlog` or
  # `in_review -> backlog` edge, so those walk through `blocked`, which has
  # both. Every hop is a `Tasks.transition_task/3` call. `deploying`, `done`
  # and `cancelled` are absent on purpose: work that reached deploy is past
  # the point a hand-back can undo, and a terminal task has nothing to hand.
  @hand_back_walk %{
    "backlog" => [],
    "planning" => ["backlog"],
    "blocked" => ["backlog"],
    "stack_pending" => ["backlog"],
    "in_progress" => ["blocked", "backlog"],
    "in_review" => ["blocked", "backlog"]
  }

  @janitor_phases ~w(planning execution review)

  # A claim this old that is still in `backlog` was never routed. Generous
  # on purpose: overlapping fires land within seconds of each other, and a
  # claim that one run committed must never be reclaimed by its sibling in
  # the moment before that run routes it.
  @stranded_after_seconds 3600

  # {reason_code, text regexes, path globs}. ORDER IS THE PRECEDENCE: the
  # first category that matches names the refusal.
  @categories [
    {"vault", [~r/\bvault(?:\.ex)?\b/], ["**/vault.ex", "**/vault/**", "**/*vault*"]},
    {"database_migration",
     [
       ~r/\bmigrat\w*/,
       ~r/\bschema (?:change|migration)s?\b/,
       ~r/\bdatabase schema\b/,
       ~r/\balter table\b/,
       ~r/\b(?:add|drop|rename) (?:a |an |the )?(?:column|table|index|constraint)s?\b/,
       ~r/\bbackfill\w*/
     ], ["**/priv/repo/migrations/**", "**/migrations/**", "**/structure.sql"]},
    {"auth_or_secrets",
     [
       ~r/\bauth[nz]?\b/,
       ~r/\bauthenticat\w*/,
       ~r/\bauthori[sz]\w*/,
       ~r/\boauth\w*/,
       ~r/\boidc\b/,
       ~r/\bsso\b/,
       ~r/\blog ?in\b/,
       ~r/\blog ?out\b/,
       ~r/\bsign[- ]?(?:in|on)\b/,
       ~r/\bpasswords?\b/,
       ~r/\bcredentials?\b/,
       ~r/\bsecrets?\b/,
       ~r/\bapi[ _-]?keys?\b/,
       ~r/\b(?:access|api|bearer|refresh|auth|session|signing) tokens?\b/,
       ~r/\bsigning keys?\b/,
       ~r/\bpermissions?\b/,
       ~r/\brbac\b/,
       ~r/\bacls?\b/,
       ~r/\bencrypt\w*/,
       ~r/\bdecrypt\w*/,
       ~r/\bcsrf\b/,
       ~r/\bcookies?\b/
     ],
     [
       "**/auth/**",
       "**/*auth*",
       "**/accounts/**",
       "**/accounts.ex",
       "**/*oidc*",
       "**/*secret*",
       "**/*credential*",
       "**/*permission*"
     ]},
    {"tenancy_boundary",
     [
       ~r/\btenan\w*/,
       ~r/\bcross[- ]org\w*/,
       ~r/\bmulti[- ]?org\w*/,
       ~r/\borg (?:isolation|boundar\w*|scop\w*)\b/,
       ~r/\bexternal[_ ]scope\b/
     ], ["**/tenancy/**", "**/tenancy.ex", "**/*tenan*", "**/external_scope*"]},
    {"deploy_runtime_config",
     [
       ~r/\bdeploy\w*/,
       ~r/\breleases?\b/,
       ~r/\bruntime(?:\.exs| config\w*)/,
       ~r/\bdocker\w*/,
       ~r/\bpodman\b/,
       ~r/\bcontainerfile\b/,
       ~r/\bcontainer (?:image|config\w*|build)s?\b/,
       ~r/\bkubernetes\b|\bk8s\b|\bhelm\b|\bterraform\b|\bsystemd\b|\bquadlet\b/,
       ~r/\bgithub (?:actions?|workflows?)\b/,
       ~r/\bci (?:workflow|pipeline|config\w*)s?\b/,
       ~r/\benv(?:ironment)? var\w*/,
       ~r/\bfly\.toml\b/
     ],
     [
       "**/config/*.exs",
       "**/config/**/*.exs",
       "**/rel/**",
       "**/dockerfile*",
       "**/containerfile*",
       "**/docker-compose*",
       "**/compose.yml",
       "**/compose.yaml",
       "**/.github/workflows/**",
       "**/*.service",
       "**/*.container",
       "**/fly.toml",
       "**/deploy/**",
       "**/infra/**",
       "**/k8s/**",
       "**/helm/**",
       "**/*.tf",
       "**/.env*"
     ]}
  ]

  # Path-shaped tokens inside free text: a/b/c segments, or a bare file name
  # with a code/config extension.
  @text_path_regex ~r{(?:[\w.*-]+/)+[\w.*-]+|[\w-]+\.(?:exs|ex|heex|eex|js|ts|json|ya?ml|toml|sh|tf|service|container|env|sql)\b}

  @type refusal :: {:refuse, String.t(), String.t()}
  @type result :: %{
          run_id: String.t(),
          claimed: [Task.t()],
          refused: [{Task.t(), String.t()}]
        }

  @doc "Per-run cap on CLAIMED tasks."
  @spec max_tasks_per_run() :: pos_integer()
  def max_tasks_per_run, do: @max_tasks_per_run

  @doc "Upper bound on tasks one run may dispose of (claims plus refusals)."
  @spec scan_limit() :: pos_integer()
  def scan_limit, do: @scan_limit

  @doc "The stable refusal reason codes, in precedence order."
  @spec reason_codes() :: [String.t()]
  def reason_codes, do: @reason_codes

  @doc "The exclusion path globs, keyed by reason code."
  @spec path_globs() :: %{String.t() => [String.t()]}
  def path_globs, do: Map.new(@categories, fn {code, _re, globs} -> {code, globs} end)

  @doc """
  The conjunctive eligibility predicate, over a loaded row. Mirrors the
  candidate query; used as a second check on every locked row before any
  write.
  """
  @spec eligible?(Task.t()) :: boolean()
  def eligible?(%Task{} = task) do
    task.status == "backlog" and task.kind == "chore" and task.origin == "internal" and
      task.trust == "trusted" and is_nil(task.deleted_at) and not handled?(task)
  end

  def eligible?(_), do: false

  @doc """
  Run the exclusion policy over one task. `:ok` means safe for unattended
  work; `{:refuse, reason_code, detail}` names the first category hit.
  """
  @spec evaluate(Task.t()) :: :ok | refusal()
  def evaluate(%Task{} = task) do
    with {:ok, paths} <- declared_paths(task),
         :ok <- check_scope_readable(task) do
      text = normalized_text(task)
      paths = Enum.uniq(paths ++ text_paths(text))
      first_category_hit(text, paths)
    end
  end

  @doc """
  Claim up to `max_tasks_per_run/0` eligible chores for the janitor agent,
  refusing dangerous or ambiguous ones on the way, in one transaction.

  Options:

    * `:agent_id` (required) — the janitor agent put on the planning and
      execution slots of each claimed task.
    * `:run_id` — stamped on every disposed task; generated when absent.
    * `:now` — `DateTime` stamped as `janitor_at`; defaults to now.
    * `:before_commit` — `fn result -> any end`, called inside the
      transaction after every write and before commit. A test seam for
      holding a run open while an overlapping run executes.

  Returns `{:ok, %{run_id, claimed, refused}}` or `{:error, reason}` (the
  transaction rolled back and nothing was written).
  """
  @spec claim(keyword()) :: {:ok, result()} | {:error, term()}
  def claim(opts) when is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    run_id = Keyword.get_lazy(opts, :run_id, &Ecto.UUID.generate/0)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    before_commit = Keyword.get(opts, :before_commit)

    stamp = %{
      "handled_by" => @handled_by,
      "janitor_at" => DateTime.to_iso8601(now),
      "janitor_run_id" => run_id
    }

    Repo.transaction(fn ->
      result = drain(agent_id, stamp, %{claimed: [], refused: [], seen: []})

      result = %{
        run_id: run_id,
        claimed: Enum.reverse(result.claimed),
        refused: Enum.reverse(result.refused)
      }

      if is_function(before_commit, 1), do: before_commit.(result)

      result
    end)
    |> tap(fn
      {:ok, %{claimed: claimed, refused: refused}} ->
        Logger.info(
          "[janitor] run_id=#{run_id} claimed=#{inspect(Enum.map(claimed, & &1.id))} " <>
            "refused=#{inspect(Enum.map(refused, fn {t, code} -> {t.id, code} end))}"
        )

      {:error, reason} ->
        Logger.warning("[janitor] run_id=#{run_id} rolled back: #{inspect(reason)}")
    end)
  end

  @doc "The stable hand-back reason codes."
  @spec hand_back_reasons() :: [String.t()]
  def hand_back_reasons, do: @hand_back_reasons

  @doc "The reason codes whose discovery forces a hand-back."
  @spec forbidden_scope_codes() :: [String.t()]
  def forbidden_scope_codes, do: @forbidden_scope_codes

  @doc """
  Classify paths discovered while working a claimed chore. `:ok` when none
  is in excluded scope; `{:forbidden, reason_code, detail}` for the first
  that is, by the same globs and precedence the claim-time policy uses.
  """
  @spec scope_check([String.t()]) :: :ok | {:forbidden, String.t(), String.t()}
  def scope_check(paths) when is_list(paths) do
    paths = paths |> Enum.filter(&is_binary/1) |> Enum.map(&normalize_path/1)

    Enum.find_value(@categories, :ok, fn {code, _regexes, globs} ->
      if code in @forbidden_scope_codes do
        case Enum.find(paths, &matches_any_glob?(&1, globs)) do
          nil -> nil
          path -> {:forbidden, code, "path " <> path}
        end
      end
    end)
  end

  @doc """
  Move the claimed batch into normal planning (stage 3).

  Called with the `claimed` list `claim/1` returned and NOTHING else: this
  function never reads the backlog, so it cannot reach a task outside the
  claimed batch. Each claim is moved `backlog -> planning` through
  `Tasks.transition_task/3`, attributed to the janitor agent. From there the
  TaskRouter dispatches planning to the planning assignee the claim set, and
  the claim's `auto_approve_plan: true` carries the plan into execution.

  A claim that cannot be routed is handed back on the spot instead of being
  left in `backlog` with auto-approval on: a stack member (the stack's wave
  owns that hop) as `stack_member`, a refused transition as
  `routing_refused`.

  Returns `%{routed: [Task.t()], handed_back: [{Task.t(), reason_code}]}`.
  """
  @spec route_claimed([Task.t()], keyword()) :: %{
          routed: [Task.t()],
          handed_back: [{Task.t(), String.t()}]
        }
  def route_claimed(claimed, opts) when is_list(claimed) and is_list(opts) do
    agent_id = Keyword.fetch!(opts, :agent_id)
    hand_back_opts = Keyword.take(opts, [:now, :run_id])

    acc =
      Enum.reduce(claimed, %{routed: [], handed_back: []}, fn %Task{} = task, acc ->
        case route_one(task, agent_id) do
          {:ok, routed} ->
            %{acc | routed: [routed | acc.routed]}

          {:hand_back, code, detail} ->
            case hand_back(task.id, code, [detail: detail] ++ hand_back_opts) do
              {:ok, back} ->
                %{acc | handed_back: [{back, code} | acc.handed_back]}

              {:error, reason} ->
                Logger.error(
                  "[janitor] task_id=#{task.id} could not be routed (#{code}: #{detail}) " <>
                    "and the hand-back failed: #{inspect(reason)}"
                )

                acc
            end
        end
      end)

    %{routed: Enum.reverse(acc.routed), handed_back: Enum.reverse(acc.handed_back)}
  end

  defp route_one(%Task{stack_id: stack_id}, _agent_id) when is_binary(stack_id),
    do: {:hand_back, "stack_member", "stack #{stack_id} owns backlog -> planning"}

  defp route_one(%Task{} = task, agent_id) do
    case Tasks.transition_task(task, "planning", {:agent, agent_id}) do
      {:ok, routed} -> {:ok, routed}
      {:error, reason} -> {:hand_back, "routing_refused", inspect(reason)}
      {:error, reason, _details} -> {:hand_back, "routing_refused", inspect(reason)}
    end
  end

  @doc """
  Hand back every committed janitor claim that is still in `backlog` more
  than an hour after it was claimed, as `claim_not_routed`.

  `route_claimed/2` moves a claim into planning moments after `claim/1`
  commits. A claim still in `backlog` an hour later belongs to a run that
  died between the two, and would otherwise sit with auto-approval on and
  `handled_by: "janitor"`, skipped by every later run. Runs at the start of
  each janitor fire, after the Router's assignment gate.

  Options: `:now` (defaults to now), `:run_id`.
  Returns the handed-back tasks.
  """
  @spec reconcile_stranded(keyword()) :: [Task.t()]
  def reconcile_stranded(opts \\ []) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cutoff = DateTime.add(now, -@stranded_after_seconds, :second)

    from(t in Task,
      where: t.status == "backlog" and is_nil(t.deleted_at),
      where: fragment("?->>'handled_by' = ?", t.metadata, ^@handled_by),
      where: fragment("?->>'janitor_disposition' = 'claimed'", t.metadata),
      where: fragment("(?->>'janitor_at')::timestamptz < ?", t.metadata, ^cutoff),
      order_by: [asc: t.inserted_at, asc: t.id],
      select: t.id
    )
    |> Repo.all()
    |> Enum.flat_map(fn id ->
      case hand_back(
             id,
             "claim_not_routed",
             [detail: "claimed but still in backlog after #{@stranded_after_seconds}s"] ++
               Keyword.take(opts, [:now, :run_id])
           ) do
        {:ok, task} -> [task]
        {:error, _reason} -> []
      end
    end)
  end

  @doc """
  Hand a janitor-claimed task back to the humans (stage 3), atomically.

  In ONE transaction, over the row locked `FOR UPDATE`:

    1. the task walks back to `backlog` through `Tasks.transition_task/3`
       (via `blocked` from `in_progress` / `in_review`, which have no direct
       edge);
    2. the janitor agent leaves every phase slot it holds, through
       `Tasks.set_phase_assignees/2`;
    3. `auto_approve_plan` is set `false` and the metadata is MERGED with
       `janitor_disposition: "handed_back"`, `janitor_reason`,
       `janitor_reason_detail` and `janitor_handed_back_at`. Every prior key,
       `filed_by` and the claim's own `janitor_at` / `janitor_run_id`
       included, is kept.

  Any failing step rolls the whole hand-back back.

  Options:

    * `:detail` — free text kept as `janitor_reason_detail`
    * `:paths` — paths found while working the chore. When any is in
      excluded scope (`scope_check/1`) that category REPLACES the reason
      given: discovering a migration, `vault.ex`, auth, tenancy or deploy
      config is a mandatory hand-back and is recorded as such.
    * `:agent_id` — the calling agent. When given it must be the claim's
      janitor agent or hold one of the task's phase slots.
    * `:now`, `:run_id`

  Only a task the janitor CLAIMED can be handed back; `deploying`, `done`
  and `cancelled` tasks are refused. Returns `{:ok, task}` or
  `{:error, reason}`.
  """
  @spec hand_back(Ecto.UUID.t(), String.t(), keyword()) :: {:ok, Task.t()} | {:error, term()}
  def hand_back(task_id, reason, opts \\ []) when is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    caller = Keyword.get(opts, :agent_id)

    with :ok <- valid_uuid(task_id),
         :ok <- valid_reason(reason),
         {:ok, paths} <- valid_paths(Keyword.get(opts, :paths, [])) do
      {code, detail} = effective_reason(reason, Keyword.get(opts, :detail), paths)

      Repo.transaction(fn ->
        with {:ok, task} <- lock_task(task_id),
             :ok <- require_janitor_claim(task),
             :ok <- require_claim_holder(task, caller),
             {:ok, task} <- walk_to_backlog(task, caller),
             {:ok, task} <- release_janitor_slots(task),
             {:ok, task} <- stamp_handed_back(task, code, detail, now, opts) do
          task
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> tap(fn
        {:ok, task} -> record_handed_back(task, code, detail, caller, opts)
        {:error, _} -> :ok
      end)
    end
  end

  @doc """
  Record one run's outcomes on the existing audit surfaces (stage 3): an
  `audit_events` row per disposed task (`resource_type: "task"`,
  `event_type: "platform.janitor.<disposition>"`), and, for each routed
  claim, a log-only line in that task's execution space. Refusals are
  already on the task row's metadata; hand-backs record themselves in
  `hand_back/3`. Never raises and never vetoes the run.
  """
  @spec record_run(map(), map(), keyword()) :: :ok
  def record_run(%{run_id: run_id, refused: refused}, %{routed: routed}, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id)

    for {task, code} <- refused do
      audit(task, "refused", agent_id, %{
        "run_id" => run_id,
        "reason" => code,
        "detail" => get_in(task.metadata || %{}, ["janitor_reason_detail"])
      })
    end

    for task <- routed do
      audit(task, "claimed", agent_id, %{"run_id" => run_id, "status" => task.status})

      post_task_log(
        task.id,
        "Janitor run #{run_id} claimed this chore and moved it into planning with " <>
          "auto-approval. Selected by the server; the janitor agent plans and executes it " <>
          "through the normal workflow and hands it back if it is not small.",
        %{"janitor_disposition" => "claimed", "janitor_run_id" => run_id},
        :create
      )
    end

    :ok
  end

  # ── the drain loop ───────────────────────────────────────────────────────

  defp drain(agent_id, stamp, acc) do
    owed = @max_tasks_per_run - length(acc.claimed)
    budget = @scan_limit - length(acc.seen)

    if owed <= 0 or budget <= 0 do
      acc
    else
      case lock_batch(acc.seen, min(owed, budget)) do
        [] ->
          acc

        batch ->
          acc = Enum.reduce(batch, acc, &dispose(&1, agent_id, stamp, &2))
          drain(agent_id, stamp, acc)
      end
    end
  end

  defp lock_batch(seen_ids, limit) do
    candidate_query()
    |> where([t], t.id not in ^seen_ids)
    |> limit(^limit)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
  end

  @doc false
  # The candidate query, ordered. Public for tests that assert ordering
  # without claiming; not a writer.
  def candidate_query do
    Tasks.trusted_internal_chore_query()
    |> where([t], is_nil(t.deleted_at))
    |> where([t], fragment("coalesce(?->>'handled_by', '') <> ?", t.metadata, ^@handled_by))
    |> order_by([t],
      desc: fragment("coalesce(?->>'filed_by', '') = ?", t.metadata, ^@architect_filed_by),
      asc: t.inserted_at,
      asc: t.id
    )
  end

  defp dispose(%Task{} = task, agent_id, stamp, acc) do
    acc = %{acc | seen: [task.id | acc.seen]}

    # Defence in depth: the query already filters these, but no row the
    # predicate rejects is ever written, whatever the query returned.
    if eligible?(task) do
      case evaluate(task) do
        :ok -> do_claim(task, agent_id, stamp, acc)
        {:refuse, code, detail} -> do_refuse(task, code, detail, stamp, acc)
      end
    else
      acc
    end
  end

  defp do_refuse(task, code, detail, stamp, acc) do
    metadata =
      (task.metadata || %{})
      |> Map.merge(stamp)
      |> Map.merge(%{
        "janitor_disposition" => "refused",
        "janitor_reason" => code,
        "janitor_reason_detail" => detail
      })

    case Tasks.update_task(task, %{metadata: metadata, auto_approve_plan: false}) do
      {:ok, updated} -> %{acc | refused: [{updated, code} | acc.refused]}
      {:error, reason} -> Repo.rollback({:refuse_failed, task.id, reason})
    end
  end

  defp do_claim(task, agent_id, stamp, acc) do
    slot = %{"assignee_id" => agent_id, "assignee_type" => "agent"}

    metadata =
      (task.metadata || %{})
      |> Map.merge(stamp)
      |> Map.merge(%{"janitor_disposition" => "claimed", "janitor_agent_id" => agent_id})

    # Assignment FIRST; auto-approval only once the janitor holds the
    # planning and execution slots.
    with {:ok, assigned} <-
           Tasks.set_phase_assignees(task, %{"planning" => slot, "execution" => slot}),
         {:ok, claimed} <-
           Tasks.update_task(assigned, %{metadata: metadata, auto_approve_plan: true}) do
      %{acc | claimed: [claimed | acc.claimed]}
    else
      {:error, reason} -> Repo.rollback({:claim_failed, task.id, reason})
    end
  end

  # ── hand-back internals ──────────────────────────────────────────────────

  defp valid_uuid(id) do
    if Platform.UUID.valid?(id), do: :ok, else: {:error, :invalid_task_id}
  end

  defp valid_reason(reason) when reason in @hand_back_reasons, do: :ok
  defp valid_reason(_reason), do: {:error, :invalid_reason}

  defp valid_paths(nil), do: {:ok, []}

  defp valid_paths(paths) when is_list(paths) do
    if Enum.all?(paths, &is_binary/1), do: {:ok, paths}, else: {:error, :invalid_paths}
  end

  defp valid_paths(_), do: {:error, :invalid_paths}

  # A forbidden path outranks whatever reason the caller gave: the category
  # is the recorded reason, and the caller's own reason survives in the
  # detail so nothing they said is lost.
  defp effective_reason(reason, detail, paths) do
    case scope_check(paths) do
      {:forbidden, code, path_detail} when code != reason ->
        {code, join_detail([path_detail, "reported as #{reason}", detail])}

      {:forbidden, code, path_detail} ->
        {code, join_detail([path_detail, detail])}

      :ok ->
        {reason, join_detail([detail])}
    end
  end

  defp join_detail(parts) do
    parts
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join("; ")
  end

  defp lock_task(task_id) do
    case Repo.one(from(t in Task, where: t.id == ^task_id, lock: "FOR UPDATE")) do
      nil -> {:error, :not_found}
      task -> {:ok, task}
    end
  end

  defp require_janitor_claim(%Task{metadata: metadata}) do
    case metadata || %{} do
      %{"handled_by" => @handled_by, "janitor_disposition" => "claimed"} ->
        :ok

      %{"handled_by" => @handled_by, "janitor_disposition" => other} ->
        {:error, {:not_janitor_claimed, other}}

      _ ->
        {:error, {:not_janitor_claimed, nil}}
    end
  end

  defp require_claim_holder(_task, nil), do: :ok

  defp require_claim_holder(%Task{} = task, caller) when is_binary(caller) do
    if caller == janitor_agent_id(task) or caller in slot_holders(task),
      do: :ok,
      else: {:error, :not_claim_holder}
  end

  defp walk_to_backlog(%Task{status: status} = task, caller) do
    case Map.fetch(@hand_back_walk, status) do
      {:ok, steps} ->
        actor = if is_binary(caller), do: {:agent, caller}, else: :system

        Enum.reduce_while(steps, {:ok, task}, fn step, {:ok, current} ->
          case Tasks.transition_task(current, step, actor) do
            {:ok, next} -> {:cont, {:ok, next}}
            {:error, reason} -> {:halt, {:error, {:transition_refused, step, reason}}}
            {:error, reason, _d} -> {:halt, {:error, {:transition_refused, step, reason}}}
          end
        end)

      :error ->
        {:error, {:not_handbackable, status}}
    end
  end

  # Clears the slots the janitor holds and leaves anyone else's alone. The
  # claim records its agent as `janitor_agent_id`; a claim without it (none
  # are expected) falls back to the two slots `claim/1` sets.
  defp release_janitor_slots(%Task{} = task) do
    janitor = janitor_agent_id(task)
    phase_assignees = task.phase_assignees || %{}

    clears =
      for phase <- @janitor_phases,
          slot = Map.get(phase_assignees, phase),
          is_map(slot) and slot != %{},
          held_by_janitor?(slot, phase, janitor),
          into: %{},
          do: {phase, nil}

    if clears == %{}, do: {:ok, task}, else: Tasks.set_phase_assignees(task, clears)
  end

  defp held_by_janitor?(%{"assignee_id" => id}, _phase, janitor) when is_binary(janitor),
    do: id == janitor

  defp held_by_janitor?(_slot, phase, nil), do: phase in ["planning", "execution"]
  defp held_by_janitor?(_slot, _phase, _janitor), do: false

  defp stamp_handed_back(%Task{} = task, code, detail, now, opts) do
    metadata =
      (task.metadata || %{})
      |> Map.merge(%{
        "handled_by" => @handled_by,
        "janitor_disposition" => "handed_back",
        "janitor_reason" => code,
        "janitor_reason_detail" => detail,
        "janitor_handed_back_at" => DateTime.to_iso8601(now)
      })
      |> maybe_put_run(Keyword.get(opts, :run_id))

    Tasks.update_task(
      task,
      Map.merge(%{metadata: metadata, auto_approve_plan: false}, flat_pointer_clear(task))
    )
  end

  # `set_phase_assignees/2` re-derives the flat pointer from the phase
  # slots and keeps the existing one when the slot is empty, so a pointer
  # still naming the janitor is cleared here, in the same write. Anyone
  # else's pointer is left alone.
  defp flat_pointer_clear(%Task{assignee_id: id} = task) when is_binary(id) do
    janitor = janitor_agent_id(task)

    if is_nil(janitor) or id == janitor,
      do: %{assignee_id: nil, assignee_type: nil},
      else: %{}
  end

  defp flat_pointer_clear(_task), do: %{}

  defp maybe_put_run(metadata, run_id) when is_binary(run_id),
    do: Map.put(metadata, "janitor_handed_back_run_id", run_id)

  defp maybe_put_run(metadata, _), do: metadata

  defp janitor_agent_id(%Task{metadata: %{"janitor_agent_id" => id}}) when is_binary(id), do: id
  defp janitor_agent_id(_), do: nil

  defp slot_holders(%Task{phase_assignees: pa}) when is_map(pa) do
    for {_phase, %{"assignee_id" => id}} <- pa, is_binary(id), do: id
  end

  defp slot_holders(_), do: []

  defp record_handed_back(%Task{} = task, code, detail, caller, opts) do
    audit(task, "handed_back", caller, %{
      "reason" => code,
      "detail" => detail,
      "run_id" => Keyword.get(opts, :run_id)
    })

    post_task_log(
      task.id,
      "Janitor handed this chore back (#{code}): #{if detail == "", do: "no detail", else: detail}. " <>
        "It is in backlog with auto-approval off and the janitor removed from its phase slots.",
      %{"janitor_disposition" => "handed_back", "janitor_reason" => code},
      :existing
    )
  end

  defp audit(%Task{} = task, disposition, agent_id, metadata) do
    Audit.record(%{
      event_type: "platform.janitor." <> disposition,
      action: disposition,
      actor_type: if(is_binary(agent_id), do: "agent", else: "system"),
      actor_id: if(Platform.UUID.valid?(agent_id), do: agent_id),
      resource_type: "task",
      resource_id: task.id,
      metadata: Map.put(metadata, "handled_by", @handled_by)
    })
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[janitor] audit row for task_id=#{task.id} failed: #{inspect(reason)}")
    end
  rescue
    error ->
      Logger.warning(
        "[janitor] audit row for task_id=#{task.id} raised: #{Exception.message(error)}"
      )
  end

  # `:create` resolves (or creates) the space a routed task's TaskRouter will
  # use anyway; `:existing` posts only where a space already exists, so a
  # hand-back never conjures a space for a task nobody is running.
  defp post_task_log(task_id, body, metadata, mode) do
    space =
      case mode do
        :create ->
          case ExecutionSpace.find_or_create(task_id) do
            {:ok, space} -> space
            _ -> nil
          end

        :existing ->
          ExecutionSpace.find_by_task_id(task_id)
      end

    if space do
      ExecutionSpace.post_log(space.id, body,
        metadata: Map.merge(%{"source" => "janitor", "handled_by" => @handled_by}, metadata)
      )
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "[janitor] execution-space log for task_id=#{task_id} raised: #{Exception.message(error)}"
      )

      :ok
  end

  # ── policy internals ─────────────────────────────────────────────────────

  defp handled?(%Task{metadata: %{"handled_by" => @handled_by}}), do: true
  defp handled?(_), do: false

  defp check_scope_readable(%Task{title: title, description: description}) do
    cond do
      blank?(title) ->
        {:refuse, "ambiguous_scope", "blank title"}

      String.length(String.trim(description || "")) < @min_description_chars ->
        {:refuse, "ambiguous_scope",
         "description shorter than #{@min_description_chars} characters"}

      true ->
        :ok
    end
  end

  defp declared_paths(%Task{metadata: metadata}) when is_map(metadata) do
    Enum.reduce_while(@declared_path_keys, {:ok, []}, fn key, {:ok, acc} ->
      case Map.fetch(metadata, key) do
        :error ->
          {:cont, {:ok, acc}}

        {:ok, nil} ->
          {:cont, {:ok, acc}}

        {:ok, list} when is_list(list) ->
          if Enum.all?(list, &is_binary/1) do
            {:cont, {:ok, acc ++ Enum.map(list, &normalize_path/1)}}
          else
            {:halt, {:refuse, "ambiguous_scope", "metadata.#{key} is not a list of strings"}}
          end

        {:ok, _other} ->
          {:halt, {:refuse, "ambiguous_scope", "metadata.#{key} is not a list of strings"}}
      end
    end)
  end

  defp declared_paths(_task), do: {:ok, []}

  defp normalized_text(%Task{title: title, description: description}) do
    [title || "", description || ""]
    |> Enum.join("\n")
    |> String.downcase()
  end

  defp text_paths(text) do
    @text_path_regex
    |> Regex.scan(text)
    |> Enum.map(fn [match | _] -> normalize_path(match) end)
  end

  defp normalize_path(path) do
    path
    |> String.trim()
    |> String.downcase()
    |> String.trim_leading("./")
    # `lib/x.ex:12`, `lib/x.ex:12:3`, `lib/x.ex#L12` name the file.
    |> String.replace(~r/(?::\d+)+\z|#l\d+(?:-l?\d+)?\z/, "")
  end

  defp first_category_hit(text, paths) do
    Enum.find_value(@categories, :ok, fn {code, regexes, globs} ->
      cond do
        path = Enum.find(paths, &matches_any_glob?(&1, globs)) ->
          {:refuse, code, "path " <> path}

        regex = Enum.find(regexes, &Regex.match?(&1, text)) ->
          [term | _] = Regex.run(regex, text)
          {:refuse, code, "term " <> inspect(term)}

        true ->
          nil
      end
    end)
  end

  defp matches_any_glob?(path, globs), do: Enum.any?(globs, &glob_match?(path, &1))

  @doc false
  # Minimal glob: `**/` matches zero or more directories, `**` anything,
  # `*` anything but `/`, `?` one non-`/` character. Anchored, full match.
  def glob_match?(path, glob) do
    Regex.match?(glob_regex(glob), path)
  end

  defp glob_regex(glob) do
    body =
      glob
      |> String.downcase()
      |> tokenize_glob([])
      |> Enum.reverse()
      |> Enum.join()

    Regex.compile!("\\A" <> body <> "\\z")
  end

  defp tokenize_glob("", acc), do: acc
  defp tokenize_glob("**/" <> rest, acc), do: tokenize_glob(rest, ["(?:.*/)?" | acc])
  defp tokenize_glob("**" <> rest, acc), do: tokenize_glob(rest, [".*" | acc])
  defp tokenize_glob("*" <> rest, acc), do: tokenize_glob(rest, ["[^/]*" | acc])
  defp tokenize_glob("?" <> rest, acc), do: tokenize_glob(rest, ["[^/]" | acc])

  defp tokenize_glob(<<char::utf8, rest::binary>>, acc),
    do: tokenize_glob(rest, [Regex.escape(<<char::utf8>>) | acc])

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_), do: true
end
