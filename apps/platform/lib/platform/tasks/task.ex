defmodule Platform.Tasks.Task do
  @moduledoc """
  A Task — the atomic unit of shepherded work.

  ## Three distinct people fields, three distinct concepts

  Tasks carry three separate references to humans/agents. They exist because
  they answer three different questions and are NOT interchangeable.

    * `sponsor_user_id` (added in ADR 0042) — the **sponsor**: a nullable human
      user who is accountable for the task landing. The shepherd. The person
      the task "belongs to" politically. Distinct from the technical assignee;
      the sponsor may be a manager, product owner, or approver who never
      touches the code. Cleared to `NULL` when the referenced user is deleted.

    * `assignee_type` + `assignee_id` — the **current-phase assignee**: whoever
      is doing the technical work *right now*. Derived by `Platform.Tasks`
      from `phase_assignees` whenever the phase changes (planning → execution
      → review). May be an agent (`assignee_type: "agent"`) or a human
      (`assignee_type: "user"`). Rotates as the task moves through phases.

    * `reported_by` — the **reporter**: a free-form string capturing who filed
      the task originally. Historical only. Not a foreign key; the referenced
      identity may not even be a Suite user. Never used for routing or
      authority.

  Interchanging these has caused confusion in the past — e.g. treating the
  assignee as accountable when phases are rotating, or reading `reported_by`
  as the sponsor when it's just an audit trail entry. When in doubt: sponsor
  answers "who is on the hook?", assignee answers "who is working on it?",
  reporter answers "who filed it?"
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  # `cancelled` (task 019e24ac stage 3) is an agent-reachable terminal status
  # for fold/supersede paths so a non-started task does not have to be walked
  # through `in_progress` (which would spawn dispatchers) just to retire it.
  # Terminal: see `@valid_task_transitions` in `Platform.Tasks` — `cancelled`
  # has `[]` outbound. Soft-deletable: a cancelled task remains in
  # `@deletable_statuses` so the UI can still fold it.
  @statuses ~w(backlog planning in_progress in_review deploying done blocked stack_pending cancelled)
  @priorities ~w(low medium high critical)

  # Per-phase assignee keys. Order matches the natural lifecycle progression.
  @phases ~w(planning execution review)

  # Canonical dependency kinds. Future-proofed by name (string list) so we can
  # add new kinds (e.g. "follows", "informs") without rewriting validators.
  @valid_dependency_kinds ~w(blocks)
  def valid_dependency_kinds, do: @valid_dependency_kinds

  # Allowed `strategy` values inside `deploy_target_config` (task 019f5e66
  # stage 2). Mirrors the dispatch-side registration in
  # `DeployStageBuilder`/`HeartbeatScheduler`; keep in sync when adding
  # new strategies.
  @deploy_target_config_strategies ~w(pr_merge docker_deploy skill_driven manual project_files email)
  def deploy_target_config_strategies, do: @deploy_target_config_strategies

  # ADR-0046 planning sub-phases (task 019f9b28-ab82 member 4).
  #
  # `@planning_steps` is the cursor domain for `planning_step` — where
  # inside the planning phase the task currently is. NOT a status: no
  # `designing`/`architecting` entry is added to `@statuses` and the
  # `@valid_task_transitions` table in `Platform.Tasks` is untouched.
  #
  # `@planning_step_keys` is the domain of the KEYS in
  # `planning_step_outcomes` — the steps that have a dispatchable
  # responsibility behind them. Note it is not the same list as
  # `@planning_steps`: plain `planning` dispatches nothing, so it has no
  # outcome to record.
  #
  # `@planning_step_outcomes` is the three-value outcome table. All three
  # accessors are public functions rather than bare attributes because
  # later stages of this task, and ADR-0046 members 5/7/8, all need to
  # read them — a caller that hardcodes its own copy of the list is
  # exactly how the conflation class comes back.
  @planning_steps ~w(designing planning architecting)
  def planning_steps, do: @planning_steps

  @planning_step_keys ~w(design architecture)
  def planning_step_keys, do: @planning_step_keys

  @planning_step_outcomes ~w(complete not_applicable failed)
  def planning_step_outcomes, do: @planning_step_outcomes

  schema "tasks" do
    belongs_to(:project, Platform.Tasks.Project)
    belongs_to(:epic, Platform.Tasks.Epic)
    belongs_to(:stack, Platform.Tasks.Stack)
    # Sponsor — human shepherd distinct from the current-phase technical
    # assignee. Nullable per ADR 0042. Cleared to NULL on user delete.
    belongs_to(:sponsor, Platform.Accounts.User,
      foreign_key: :sponsor_user_id,
      type: :binary_id
    )

    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "backlog")
    field(:priority, :string, default: "medium")
    # `assignee_type` / `assignee_id` are the *current-phase* assignee, derived
    # by `Platform.Tasks` whenever the phase changes. New assignments should be
    # written via `phase_assignees` so all phases get explicit values.
    field(:assignee_type, :string)
    field(:assignee_id, :binary_id)
    # Map keyed by phase ("planning" | "execution" | "review") with values
    # `%{"assignee_id" => uuid_string, "assignee_type" => "agent" | "user"}`.
    field(:phase_assignees, :map, default: %{})
    field(:deploy_target, :string)
    field(:deploy_strategy, :map)
    # `deploy_target_config` (task 019f5e66 stage 2) — richer per-task
    # deploy config replacing the legacy `deploy_target` string. Shape:
    # `%{"strategy" => one_of(@deploy_target_config_strategies), ...}`.
    # The legacy `deploy_target` column stays populated in parallel
    # until every read/write caller migrates; see the migration TODO.
    field(:deploy_target_config, :map, default: nil)
    field(:dependencies, {:array, :map}, default: [])
    field(:metadata, :map, default: %{})
    field(:stack_position, :integer)
    field(:reported_by, :string)
    field(:deleted_at, :utc_datetime_usec)
    # Auto-approve plan (task 019f25f2): opt-in flag. When true, the plan
    # submission path short-circuits pending_review and calls the shared
    # approve_plan/2 codepath directly. Non-null default false preserves the
    # manual-review default for existing rows and callers.
    field(:auto_approve_plan, :boolean, default: false)

    # Meeting-triage `needs_promotion` flag (task 019f5e2b-8d29 stage 2).
    # Set to true by `Platform.Meetings.Triage.file_tasks_from_canvas/2`
    # for tasks filed while the per-project triage-backlog count is under
    # `:meetings_triage_backlog_cap`. Cleared by `Platform.Tasks.promote/1`
    # when the kanban badge is clicked. See migration
    # `20260713120000_add_needs_promotion_to_tasks.exs` for the partial
    # index the kanban filter relies on.
    field(:needs_promotion, :boolean, default: false)

    # ADR-0046 planning sub-phase cursor (task 019f9b28-ab82 member 4).
    # One of `@planning_steps`; `"planning"` is the backfilled value for
    # every pre-existing row (see migration
    # `20260726045711_add_planning_step_to_tasks.exs`). Written ONLY via
    # `planning_step_changeset/2` — deliberately absent from
    # `changeset/2`'s cast list, see the comment there.
    field(:planning_step, :string, default: "planning")

    # ADR-0046 per-step outcome record. String-keyed map from a member of
    # `@planning_step_keys` to
    # `%{"outcome" => o, "recorded_at" => iso8601, "detail" => str | nil}`
    # where `o` is one of `@planning_step_outcomes`:
    #
    #   * `"complete"`        — the step's responsibility was dispatched.
    #   * `"not_applicable"`  — nobody holds the role, or the
    #     responsibility is unknown. The progressive-enhancement path;
    #     renders nothing, blocks nothing.
    #   * `"failed"`          — the step was expected to run and the
    #     dispatch failed.
    #
    # `not_applicable` and `failed` MUST NEVER COLLAPSE INTO ONE VALUE.
    # That collapse is what is forbidden by
    # `0046-design-and-architecture-phases-in-planning.md § Per-step outcome`:
    # a gate that never ran became
    # indistinguishable from a gate that ran and passed. Anything that
    # maps a fire result onto this table must go through
    # `Platform.Responsibilities.outcome/1` rather than re-deriving it.
    field(:planning_step_outcomes, :map, default: %{})

    # Bounded review loop (task 019ff788 stage 3). Counts the GENUINE
    # gate-failure bounces this task has taken — a review round that
    # returned a verdict about the feature. On the third the router routes
    # the task to re-planning instead of back to `in_progress`; see
    # `Platform.Orchestration.TaskRouter` and `Platform.Tasks.ReviewDisposition`.
    #
    # A round where the gate COULD NOT BE RUN does not touch this column.
    # Reset to 0 when an approved plan starts and when the task is
    # re-planned, so a fresh plan gets a fresh three rounds. Non-null,
    # default 0 — see migration
    # `20260812230000_add_review_round_count_to_tasks.exs`. Written ONLY via
    # `review_round_changeset/2`, deliberately absent from `changeset/2`'s
    # cast list for the same reason `:planning_step` is: `changeset/2` casts
    # `:status`, so routing the counter through it would put the loop bound
    # on the same unguarded surface `Tasks.update_task/3` exposes to agents.
    field(:review_round_count, :integer, default: 0)

    # `search_vector` (task 019f3dbb stage 1) is a Postgres `tsvector`
    # column, `GENERATED ALWAYS AS (to_tsvector('english', coalesce(title,
    # '') || ' ' || coalesce(description, ''))) STORED` — see migration
    # `20260708120000_add_search_vector_and_task_references_to_tasks.exs`.
    # Not declared as an Ecto field: we mirror `Platform.Org.WikiPage` /
    # `Platform.Org.WikiJournalEntry`, which drive their tsvector via
    # `fragment("... ?", p.search_vector, ...)` inside
    # `Platform.Org.Wiki.Search` without a schema declaration. Stage 3 adds
    # the task-corpus channel to `Search` and follows the same fragment
    # pattern.

    has_many(:plans, Platform.Tasks.Plan)

    has_many(:outgoing_task_references, Platform.Tasks.TaskReference,
      foreign_key: :source_task_id
    )

    has_many(:incoming_task_references, Platform.Tasks.TaskReference,
      foreign_key: :target_task_id
    )

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses
  def priorities, do: @priorities

  @doc """
  Sort rank for a priority value, by MEANING: `"critical"` 0, `"high"` 1,
  `"medium"` 2, `"low"` 3, anything else 4.

  Never compare the priority strings themselves: alphabetical order is
  critical, high, low, medium, which puts low above medium.

  "Anything else" is reachable. The changeset's `validate_inclusion` refuses
  values outside `priorities/0`, but the `tasks.priority` column is nullable
  with no check constraint, so `nil` and unknown strings (e.g. `"urgent"`)
  arrive through `insert_all`/`update_all`. They rank after `"low"` rather
  than raising.
  """
  @spec priority_rank(term()) :: 0..4
  def priority_rank("critical"), do: 0
  def priority_rank("high"), do: 1
  def priority_rank("medium"), do: 2
  def priority_rank("low"), do: 3
  def priority_rank(_other), do: 4
  def phases, do: @phases

  @deletable_statuses ~w(backlog planning blocked done stack_pending cancelled)
  def deletable_statuses, do: @deletable_statuses

  def deletable?(%__MODULE__{status: status}), do: status in @deletable_statuses

  # DELIBERATELY ABSENT from the cast list below: `:planning_step` and
  # `:planning_step_outcomes` (ADR-0046 member 4). This is load-bearing
  # in both directions:
  #
  #   * `changeset/2` casts `:status`, which makes `Tasks.update_task/3`
  #     a fully unguarded status writer (`promote/1` uses it that way).
  #     Routing planning_step writes through it would put the new fields
  #     on that same unguarded surface.
  #   * Symmetrically, a caller holding only `planning_step_changeset/2`
  #     cannot smuggle a `:status` change through it.
  #
  # One narrow changeset buys both properties. Do not "simplify" by
  # merging the two cast lists.
  #
  # SECOND PROPERTY, added by task 019fe4a8: because `changeset/2` is the
  # ONLY changeset that casts `:status`, it is also the sole recorded
  # status-transition writer. The `prepare_changes/2` hook at the end of
  # the pipeline writes one `Platform.Tasks.PhaseTransition` row per
  # executed status change, inside the same transaction as the write.
  #
  # ANY NEW CHANGESET THAT CASTS `:status` must either attach the same
  # hook or route its callers through here. A status write that skips the
  # hook does not error — it just silently produces no transition row, and
  # the per-phase cycle-time decomposition quietly under-reports. That is
  # why the failure mode is caught by a scan-based guard test rather than
  # left to review.
  #
  # Design alternatives considered and rejected (do not re-litigate):
  #
  #   * Instrumenting the known call sites — the named failure mode; the
  #     next writer someone adds goes missing as absent rows.
  #   * A `Platform.Repo.update/2` override — sees an untyped changeset,
  #     must re-derive "is this a Task and did status change", and
  #     `update_all`/`insert_all` bypass it anyway.
  #   * A wrapper function every writer must call — requires editing every
  #     existing writer AND voluntary future compliance. `prepare_changes`
  #     makes compliance automatic.
  #   * Telemetry — `Platform.Audit.TelemetryHandler` is detached globally
  #     by its own test's `on_exit`, so telemetry-driven persistence
  #     silently drops rows in downstream tests, and a handler runs outside
  #     the write's transaction.
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :project_id,
      :epic_id,
      :stack_id,
      :sponsor_user_id,
      :title,
      :description,
      :status,
      :priority,
      :assignee_type,
      :assignee_id,
      :phase_assignees,
      :deploy_target,
      :deploy_strategy,
      :deploy_target_config,
      :dependencies,
      :metadata,
      :stack_position,
      :reported_by,
      :deleted_at,
      :auto_approve_plan,
      :needs_promotion
    ])
    |> validate_required([:project_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_phase_assignees()
    |> validate_dependencies()
    |> validate_metadata()
    |> validate_deploy_target_config()
    |> validate_deploy_strategy()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
    |> foreign_key_constraint(:stack_id)
    |> foreign_key_constraint(:sponsor_user_id)
    # Last in the pipeline on purpose: `prepare_changes/2` only runs when
    # the changeset is valid AND the operation actually executes, so an
    # invalid or never-executed changeset records nothing.
    |> prepare_changes(&record_status_transition/1)
  end

  # Writes one `task_phase_transitions` row per executed status change.
  #
  # Runs inside the same `Repo` transaction as the update it describes:
  # roll the transaction back and the transition row goes with it, which is
  # the property that makes this table trustworthy.
  defp record_status_transition(changeset) do
    case Ecto.Changeset.get_change(changeset, :status) do
      # No status change in this write — an ordinary field update records
      # nothing.
      nil ->
        changeset

      to_status ->
        maybe_record(changeset, to_status)
    end
  end

  # LOAD-BEARING: skip inserts. `prepare_changes/2` runs BEFORE the parent
  # `tasks` row exists, so a transition row written here would violate the
  # `task_id` foreign key. Do not "fix" this by making the FK deferrable or
  # by inserting an origin row from `create_task/2` — the first interval is
  # anchored at `tasks.inserted_at` by the query helper instead.
  defp maybe_record(%{action: :insert} = changeset, _to_status), do: changeset

  defp maybe_record(changeset, to_status) do
    actor = Platform.Tasks.TransitionActor.current()

    attrs =
      Map.merge(actor, %{
        task_id: changeset.data.id,
        # Pre-write struct: the status the task is leaving.
        from_status: changeset.data.status,
        to_status: to_status,
        occurred_at: DateTime.utc_now()
      })

    case Platform.Tasks.PhaseTransitions.record(attrs, changeset.repo) do
      {:ok, _row} ->
        changeset

      {:error, reason} ->
        # Deliberately NOT `Repo.rollback/1`. This instrumentation is
        # observational: a broken recorder must never be able to fail a
        # legitimate status change. Log loudly and let the transition
        # through — a missing row is a measurement gap, a blocked
        # transition is an outage.
        require Logger

        Logger.error(
          "failed to record task phase transition for task #{inspect(changeset.data.id)}: " <>
            inspect(reason)
        )

        changeset
    end
  end

  @doc """
  Narrow changeset for the bounded-review-loop counter (task 019ff788
  stage 3). Casts `:review_round_count` and nothing else — in particular
  not `:status`, so a caller holding only this changeset cannot smuggle a
  status transition through it, and `changeset/2` (the sole recorded
  status writer) stays the only unguarded status surface.
  """
  def review_round_changeset(task, attrs) do
    task
    |> cast(attrs, [:review_round_count])
    |> validate_required([:review_round_count])
    |> validate_number(:review_round_count, greater_than_or_equal_to: 0)
  end

  @doc """
  Narrow changeset for the ADR-0046 planning sub-phase fields.

  Casts ONLY `:planning_step` and `:planning_step_outcomes`. Anything
  else in `attrs` — including `:status` — is ignored, by design: this
  changeset is the entire write surface for the planning fields, and it
  must not double as a status writer. See the comment above
  `changeset/2`.

  Validations:

    * `:planning_step` must be in `planning_steps/0`.
    * `:planning_step_outcomes` must be a string-keyed map whose keys are
      all in `planning_step_keys/0` and whose every value is a map with
      an `"outcome"` in `planning_step_outcomes/0`. Unknown outcome
      strings are REJECTED, not coerced — a writer must not be able to
      introduce a fourth outcome value that downstream readers would
      then have to guess about.
  """
  def planning_step_changeset(task, attrs) do
    task
    |> cast(attrs, [:planning_step, :planning_step_outcomes])
    |> validate_inclusion(:planning_step, @planning_steps)
    |> validate_planning_step_outcomes()
  end

  # `planning_step_outcomes` must be a string-keyed map from a member of
  # `@planning_step_keys` to a map carrying an `"outcome"` drawn from
  # `@planning_step_outcomes`. `%{}` (nothing recorded yet) is valid.
  # Extra keys inside an entry — `"recorded_at"`, `"detail"` — are
  # permitted; only `"outcome"` is pinned, because it is the value the
  # stage-4 merge-time guard branches on.
  defp validate_planning_step_outcomes(changeset) do
    case get_change(changeset, :planning_step_outcomes) do
      nil ->
        changeset

      outcomes when is_map(outcomes) ->
        changeset
        |> validate_planning_step_outcome_keys(outcomes)
        |> validate_planning_step_outcome_values(outcomes)

      _other ->
        add_error(changeset, :planning_step_outcomes, "must be a map")
    end
  end

  defp validate_planning_step_outcome_keys(changeset, outcomes) do
    bad_keys = Map.keys(outcomes) -- @planning_step_keys

    if bad_keys == [] do
      changeset
    else
      add_error(
        changeset,
        :planning_step_outcomes,
        "contains invalid step keys: #{inspect(bad_keys)} (allowed: #{inspect(@planning_step_keys)})"
      )
    end
  end

  defp validate_planning_step_outcome_values(changeset, outcomes) do
    Enum.reduce(outcomes, changeset, fn {step, entry}, acc ->
      case entry do
        %{"outcome" => outcome} when is_binary(outcome) ->
          if outcome in @planning_step_outcomes do
            acc
          else
            add_error(
              acc,
              :planning_step_outcomes,
              "#{inspect(step)} has invalid outcome #{inspect(outcome)} " <>
                "(allowed: #{inspect(@planning_step_outcomes)})"
            )
          end

        %{} ->
          add_error(
            acc,
            :planning_step_outcomes,
            "#{inspect(step)} must include a string \"outcome\" key " <>
              "(one of: #{Enum.join(@planning_step_outcomes, ", ")})"
          )

        _other ->
          add_error(acc, :planning_step_outcomes, "#{inspect(step)} entry must be a map")
      end
    end)
  end

  # `phase_assignees` keys must be in `@phases`. Each value should be a map
  # with optional `"assignee_id"` (UUID string or nil) and `"assignee_type"`.
  # We don't strictly require both keys — a phase can be left unassigned.
  defp validate_phase_assignees(changeset) do
    case get_change(changeset, :phase_assignees) do
      nil ->
        changeset

      pa when is_map(pa) ->
        bad_keys = Map.keys(pa) -- @phases

        if bad_keys == [] do
          changeset
        else
          add_error(
            changeset,
            :phase_assignees,
            "contains invalid phase keys: #{inspect(bad_keys)} (allowed: #{inspect(@phases)})"
          )
        end

      _other ->
        add_error(changeset, :phase_assignees, "must be a map")
    end
  end

  # Canonical dependency shape: `[%{"task_id" => uuid, "kind" => "blocks"}]`.
  # Each entry must be a string-keyed map with a UUID `task_id` and a `kind`
  # in `@valid_dependency_kinds`. `nil` and `[]` are allowed (no deps).
  # JSONB round-trips strings, so we validate string keys, not atoms.
  defp validate_dependencies(changeset) do
    case get_change(changeset, :dependencies) do
      nil ->
        changeset

      [] ->
        changeset

      deps when is_list(deps) ->
        case Enum.find_index(deps, &(!valid_dependency_entry?(&1))) do
          nil ->
            changeset

          idx ->
            add_error(
              changeset,
              :dependencies,
              "entry at index #{idx} is invalid: expected %{\"task_id\" => uuid, \"kind\" => one_of(#{Enum.join(@valid_dependency_kinds, "|")})}"
            )
        end

      _other ->
        add_error(changeset, :dependencies, "must be a list of dependency maps")
    end
  end

  defp valid_dependency_entry?(%{"task_id" => task_id, "kind" => kind})
       when is_binary(task_id) and is_binary(kind) do
    kind in @valid_dependency_kinds and match?({:ok, _}, Ecto.UUID.cast(task_id))
  end

  defp valid_dependency_entry?(_), do: false

  # Bug #3 (task 019f708f): shape-validate `metadata["merged_into_rollup_at"]`.
  #
  # When present, the stamp MUST be a map with:
  #
  #   * `"sha"` — a binary at least 7 chars long, matching
  #     `~r/^[0-9a-f]+$/i` (git-sha-shaped).
  #   * `"at"` — a binary that round-trips through
  #     `DateTime.from_iso8601/1`.
  #
  # A missing key, `nil` metadata, or absent `merged_into_rollup_at`
  # entry are all valid — the check applies only when the stamp is
  # asserted. Rejecting the malformed shapes at the changeset boundary
  # closes the `FunctionClauseError` class in `stack_deployer.ex`
  # (lines 885, 891, 1159, 1331 — every `%{"sha" => sha}` match on
  # the raw stamp).
  @merged_sha_regex ~r/^[0-9a-f]+$/i
  defp validate_metadata(changeset) do
    case get_change(changeset, :metadata) do
      nil ->
        changeset

      meta when is_map(meta) ->
        case Map.fetch(meta, "merged_into_rollup_at") do
          :error ->
            changeset

          {:ok, stamp} ->
            case validate_merged_into_rollup_at(stamp) do
              :ok ->
                changeset

              {:error, reason} ->
                add_error(
                  changeset,
                  :metadata,
                  "merged_into_rollup_at must be %{sha: <git_sha>, at: <iso8601>} " <>
                    "(#{reason})"
                )
            end
        end

      _other ->
        add_error(changeset, :metadata, "must be a map")
    end
  end

  defp validate_merged_into_rollup_at(%{"sha" => sha, "at" => at})
       when is_binary(sha) and is_binary(at) do
    with :ok <- validate_merged_sha(sha),
         :ok <- validate_merged_at(at) do
      :ok
    end
  end

  defp validate_merged_into_rollup_at(%{}), do: {:error, "map must include :sha and :at keys"}
  defp validate_merged_into_rollup_at(_stamp), do: {:error, "must be a map"}

  defp validate_merged_sha(sha) when byte_size(sha) < 7,
    do: {:error, "sha must be at least 7 hex chars"}

  defp validate_merged_sha(sha) do
    if Regex.match?(@merged_sha_regex, sha) do
      :ok
    else
      {:error, "sha must be hex-shaped (matches ~r/^[0-9a-f]+$/i)"}
    end
  end

  defp validate_merged_at(at) do
    case DateTime.from_iso8601(at) do
      {:ok, _dt, _off} -> :ok
      {:error, reason} -> {:error, "at is not ISO8601: #{inspect(reason)}"}
    end
  end

  # `deploy_target_config` (task 019f5e66 stage 2) must be a string-keyed
  # map with a `"strategy"` key drawn from
  # `@deploy_target_config_strategies`. Extra keys are permitted — each
  # strategy carries its own additional config (e.g. project_files
  # includes `"project_id"` + `"folder"`). `nil` is allowed: rows
  # predating the column and rows that have not opted into the new
  # shape stay valid.
  defp validate_deploy_target_config(changeset) do
    case get_change(changeset, :deploy_target_config) do
      nil ->
        changeset

      # The email strategy (task 01a0cf21 stage 6) names its account, sender
      # key and recipients here; a config missing any of them could only
      # fail at deploy time, so it is refused at write time instead. Shape
      # only — the account and sender are resolved against the task's org
      # by `Platform.Deploy.Email` when the deploy runs.
      %{"strategy" => "email"} = config ->
        if Platform.Deploy.Email.valid_config?(config) do
          changeset
        else
          add_error(
            changeset,
            :deploy_target_config,
            "email config must name an account_id, a sender_key and at least one " <>
              "recipient (recipients or recipient_user_ids)"
          )
        end

      %{"strategy" => strategy} when is_binary(strategy) ->
        if strategy in @deploy_target_config_strategies do
          changeset
        else
          add_error(
            changeset,
            :deploy_target_config,
            "strategy must be one of: #{Enum.join(@deploy_target_config_strategies, ", ")}"
          )
        end

      config when is_map(config) ->
        add_error(
          changeset,
          :deploy_target_config,
          "must include a string \"strategy\" key (one of: #{Enum.join(@deploy_target_config_strategies, ", ")})"
        )

      _other ->
        add_error(changeset, :deploy_target_config, "must be a map")
    end
  end

  # `task.deploy_strategy` beats `project.deploy_config["default_strategy"]`
  # in `Tasks.resolve_deploy_strategy/1`, and it is where a multi-repo
  # deploy declares its repository set. `Project.changeset/2` has always
  # routed the project-level strategy through
  # `DeployStageBuilder.validate_strategy/1`; the task-level override went
  # entirely unvalidated, so the refusal that matters most — `auto_merge`
  # on a repo with no CI to wait for — was unreachable on the exact path
  # the feature uses. Mirror the project clause here.
  defp validate_deploy_strategy(changeset) do
    case get_change(changeset, :deploy_strategy) do
      nil ->
        changeset

      strategy when is_map(strategy) ->
        case Platform.Tasks.DeployStageBuilder.validate_strategy(strategy) do
          :ok -> changeset
          {:error, reason} -> add_error(changeset, :deploy_strategy, reason)
        end

      _other ->
        add_error(changeset, :deploy_strategy, "must be a map")
    end
  end
end
