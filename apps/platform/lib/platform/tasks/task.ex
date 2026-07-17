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
  @deploy_target_config_strategies ~w(pr_merge docker_deploy skill_driven manual project_files)
  def deploy_target_config_strategies, do: @deploy_target_config_strategies

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
  def phases, do: @phases

  @deletable_statuses ~w(backlog planning blocked done stack_pending cancelled)
  def deletable_statuses, do: @deletable_statuses

  def deletable?(%__MODULE__{status: status}), do: status in @deletable_statuses

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
      :auto_approve_plan
    ])
    |> validate_required([:project_id, :title])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:priority, @priorities)
    |> validate_phase_assignees()
    |> validate_dependencies()
    |> validate_metadata()
    |> validate_deploy_target_config()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:epic_id)
    |> foreign_key_constraint(:stack_id)
    |> foreign_key_constraint(:sponsor_user_id)
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
end
