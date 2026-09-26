defmodule Platform.Tasks.Stage do
  @moduledoc """
  One stage of a versioned plan.

  ## Why `architecture_audit` lives here

  Task 019fa61c. `architecture.review_plan` is OBSERVABLE because it has
  a tool that writes a row (`plans.architecture_verdict`);
  `architecture.audit_diff` had no equivalent, so its success rate was
  unobservable by construction — 28 broadcasts in a 3.3-hour window left
  no durable evidence anywhere, and the original payload defect ran six
  days behind that blind spot. This column is the same artefact applied
  to the per-stage `architecture.audit_diff` step.

  NOT the per-stage column ADR-0046 member 9 retired, and the difference
  is why the absence guard covering this file still passes. That column
  was an INPUT — a role key read at dispatch time to choose an assignee,
  which resolved to nil in silence whenever it held a trigger key
  instead. This column is an OUTPUT: the recorded result of a fire that
  has already happened, written after the fact and never consulted to
  route anything.

  The guard is a strict source-text check over this whole file, so
  nothing here spells the retired concept out — the trigger key is named
  instead. Narrowing that guard to accommodate a comment would weaken it
  for everyone, and the wording is not load-bearing.

  It is on `stages` and not on `plans` because the SUBJECT of an
  `audit_diff` fire is one stage's diff:
  `PlanEngine.after_stage_completed/1` fires once per stage transition,
  so a plan-level slot would make stage 2's audit overwrite stage 1's and
  the coverage invariant would count one row where two fires happened.

  NULL means no fire was ever recorded for this stage — a distinct fact
  from "fired and produced nothing", which is why the column has no
  `default: %{}` (the same argument
  `20260726051454_add_architecture_verdict_to_plans.exs` gives).

  ## The audit shape

  JSONB, string keys throughout — it round-trips through Postgres and
  through the MCP tool a later stage adds.

      %{
        "state"         => one of `architecture_audit_states/0`,
        "stage_id"      => uuid,
        "task_id"       => uuid,
        "plan_id"       => uuid,
        "dispatched_at" => iso8601,
        "deadline_at"   => iso8601,
        "resolved_at"   => iso8601 | nil,
        "source"        => one of `architecture_audit_sources/0`, or nil,
        "reason"        => string | nil,
        "summary"       => string | nil,
        "findings"      => [%{"constraint" => one of
                              `Plan.architecture_constraints/0`,
                              "detail" => non-empty string}]
      }

  Every key in `architecture_audit_required_keys/0` is written on every
  write, explicitly `nil` where there is no value yet. A reader must
  never have to distinguish "key absent" from "key present and nil" —
  that ambiguity is the same class of unobservability the column exists
  to remove, one level down. UNKNOWN keys are permitted, so later stages
  can add `"resolved_by"` and `"noted_after_deadline"` without a schema
  change.

  ## `"expired"` is deliberately unrepresentable

  A `"pending"` row past its `deadline_at` is PROJECTED as expired at
  read time and never persisted as such. Persisting it would give one
  fact two representations that can disagree, and would demote the level
  check from the correctness guarantee to one opinion among two —
  `Tasks.architecture_gate/1` (`tasks.ex:2316-2349`) argues that at
  length for the plan gate, citing a production incident where an
  edge-triggered-only handler stranded a task. The same argument applies
  here, so the enum simply has no value for it.

  ## `"source"` names the CHANNEL, never the outcome

  `"state"` already answers *what happened*; `"source"` answers *which
  way in did it come*, and the one distinction it carries is MCP tool vs.
  external text parse. The two values are drawn from
  `Plan.architecture_verdict_sources/0` rather than invented — two copies
  of one vocabulary is exactly how the two architect surfaces drifted
  apart in the first place. `"deadline"` and `"human"` are NOT shared:
  nothing writes an audit on a deadline (see above) and there is no
  human-override surface for an audit.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Platform.Tasks.Plan

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running passed failed skipped)

  # Task 019fa61c. The lifecycle of the `architecture.audit_diff` fire for
  # ONE stage. `pending` is the only non-terminal state.
  #
  # `"pending"` — NOT `"noted"` — is what a SUCCESSFUL dispatch records:
  # handoff accepted is not output captured, and recording success at
  # fire time would make every later silence indistinguishable from a
  # win. That is `Platform.Design.PreplanStep`'s argument verbatim
  # (`preplan_step.ex:30-46`).
  #
  # `"expired"` is absent on purpose — see the moduledoc.
  @architecture_audit_states ~w(pending noted skipped failed)

  # The two channels an audit RESULT can arrive through: the MCP tool and
  # `Handlers.ArchitectureAuditDiff.handle_output/3` parsing an external
  # runtime's prose. A subset of `Plan.architecture_verdict_sources/0`,
  # deliberately — one vocabulary, one distinction.
  @architecture_audit_sources ~w(mcp handle_output)

  # Task 01a0588e. WHO wrote this stage: the planner ("authored") or the
  # plan engine ("synthesized").
  #
  # `origin` is an INPUT MARKER, written at insert time by the code that
  # creates the row, and NEVER inferred from `name` or `description`. Both
  # of those are template copy — the synthesized stage is called
  # "Task-level review" and its description opens "Synthesized by the plan
  # engine…" — and a classifier keyed to either fails OPEN the first time
  # someone rewords the template, admitting exactly the plans the marker
  # exists to refuse. Read `origin`; do not read prose.
  @origins ~w(authored synthesized)

  # Written on EVERY write, explicitly nil where there is no value yet.
  # See the moduledoc: absence and nil must not be two ways of saying the
  # same thing.
  @architecture_audit_required_keys ~w(state stage_id task_id plan_id dispatched_at
                                       deadline_at resolved_at source reason summary findings)

  schema "stages" do
    belongs_to(:plan, Platform.Tasks.Plan)
    field(:position, :integer)
    field(:name, :string)
    field(:description, :string)
    field(:status, :string, default: "pending")
    field(:expected_artifacts, {:array, :map}, default: [])

    # See @origins: an insert-time marker, never inferred from name or
    # description.
    field(:origin, :string, default: "authored")

    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)

    # Task 019fa61c: the `architecture.audit_diff` fire's outcome for THIS
    # stage. NULL means no fire was ever recorded — a distinct fact from
    # "fired and produced nothing", which is why there is no
    # `default: %{}`.
    #
    # Written ONLY through `architecture_audit_changeset/2` — it is
    # deliberately absent from `changeset/2`'s cast list below.
    field(:architecture_audit, :map)

    has_many(:validations, Platform.Tasks.Validation)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc """
  The closed set of `origin` values.

  "authored" means a planner wrote the stage; "synthesized" means the plan
  engine emitted it. The value is written at insert time and is never
  derived from the stage's name or description.
  """
  def origins, do: @origins

  @doc "The closed set of persistable `architecture_audit[\"state\"]` values."
  def architecture_audit_states, do: @architecture_audit_states

  @doc """
  The closed set of `architecture_audit["source"]` values, `nil` aside.

  `nil` is also permitted and means no channel has answered yet; it is
  absent from this list because the list is the *vocabulary of channels*,
  and "no channel" is not one of them.
  """
  def architecture_audit_sources, do: @architecture_audit_sources

  @doc """
  The keys every `architecture_audit` map must carry, nil-valued or not.

  Public accessor rather than an inline literal in the validator: a guard
  that hardcodes its own copy of a list is how the two architect surfaces
  drifted apart, and the test asserts against this accessor so the list
  and its enforcement cannot separate.
  """
  def architecture_audit_required_keys, do: @architecture_audit_required_keys

  # DELIBERATELY ABSENT from the cast list below: `:architecture_audit`.
  # Load-bearing in both directions, the same reasoning
  # `Platform.Tasks.Plan` applies to `:architecture_verdict`
  # (`plan.ex:176-186`):
  #
  #   * `changeset/2` casts `:status`, which makes it the unguarded
  #     stage-status writer, and there are THREE of those:
  #     `PlanEngine.transition_stage/2` (`plan_engine.ex:561`),
  #     `Tasks.create_stage/1` (`tasks.ex:3546`) and
  #     `Tasks.transition_stage/2` (`tasks.ex:3579`). Routing audit writes through it
  #     would put the audit on that same unguarded surface, where an
  #     audit write could smuggle a `:status` change past the transition
  #     rules, and where a routine transition could silently clobber an
  #     audit the architect had already landed.
  #   * Symmetrically, a caller holding only
  #     `architecture_audit_changeset/2` cannot smuggle a `:status`
  #     change through it.
  #
  # Both directions are proved in
  # `stage_architecture_audit_changeset_test.exs`, not in this comment.
  # Do not "simplify" by merging the two cast lists.
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [
      :plan_id,
      :position,
      :name,
      :description,
      :status,
      :expected_artifacts,
      :origin,
      :started_at,
      :completed_at
    ])
    |> validate_required([:plan_id, :position, :name])
    # stages.name is varchar(255) NOT NULL
    # (20260320120000_create_tasks_tables.exs:100). Without this bound an
    # over-length name raised Postgrex 22001 from inside the plan_create /
    # plan_update transaction and MCP callers got an opaque 500 (task
    # 01a08a87). `:codepoints` matches Postgres, which counts UTF8
    # characters: the default `:graphemes` passes e+U+0301 x128 (256
    # codepoints) that the DB then rejects, and `:bytes` refuses 255
    # multi-byte chars the DB accepts. Stricter than Postgres in one case,
    # deliberately: the DB silently truncates over-length trailing spaces;
    # here they are a named refusal. Written inline, not shared with
    # Task.changeset/2's title bound, so each field's tests fail on its own.
    |> validate_length(:name, max: 255, count: :codepoints)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:origin, @origins)
    |> foreign_key_constraint(:plan_id)
  end

  @doc """
  The entire write surface for `:architecture_audit`.

  Casts ONLY `:architecture_audit`. Anything else in `attrs` — including
  `:status` — is ignored, by design. See the comment above `changeset/2`.

  Validations here are all STRUCTURAL. The lifecycle rules — one-shot
  arbitration, the level-triggered expiry projection — live in
  `Platform.Architecture.StageAudit`, because they need the persisted row
  rather than just the change.

    * a string-keyed map (`nil` is not castable here; clearing an audit
      is not an operation this schema offers);
    * every key in `architecture_audit_required_keys/0` present, nil or
      not;
    * `"state"` in `architecture_audit_states/0` — `"expired"` is
      rejected with a message naming the projection, so a writer who
      reaches for it is told where the value actually lives;
    * `"source"`, when non-nil, in `architecture_audit_sources/0`;
    * `"findings"` a list of maps, each with a `"constraint"` in
      `Plan.architecture_constraints/0` and a non-empty binary
      `"detail"`.

  An unknown state string is REJECTED, not coerced: a writer must not be
  able to introduce a fifth state that `StageAudit.coverage/1` would then
  have to guess about, because a bucket nobody sums is how the balance
  invariant stops being an invariant.
  """
  def architecture_audit_changeset(stage, attrs) do
    stage
    |> cast(attrs, [:architecture_audit])
    |> validate_architecture_audit()
  end

  defp validate_architecture_audit(changeset) do
    case get_change(changeset, :architecture_audit) do
      nil ->
        changeset

      audit when is_map(audit) ->
        changeset
        |> validate_audit_string_keys(audit)
        |> validate_audit_required_keys(audit)
        |> validate_audit_state(audit)
        |> validate_audit_source(audit)
        |> validate_audit_findings(audit)

      _other ->
        add_error(changeset, :architecture_audit, "must be a map")
    end
  end

  # String keys throughout: the map round-trips through JSONB, which
  # returns strings, so an atom-keyed write would read back different
  # from what was written. Rejecting at the boundary keeps the two halves
  # of that round trip identical.
  defp validate_audit_string_keys(changeset, audit) do
    if Enum.all?(Map.keys(audit), &is_binary/1) do
      changeset
    else
      add_error(changeset, :architecture_audit, "must use string keys")
    end
  end

  # Presence, not value. `"resolved_at" => nil` is a legitimate open
  # audit; a MISSING `"resolved_at"` is a writer that forgot, and no
  # reader should have to tell those apart. Unknown keys are untouched —
  # later stages add `"resolved_by"` and `"noted_after_deadline"`.
  defp validate_audit_required_keys(changeset, audit) do
    @architecture_audit_required_keys
    |> Enum.reject(&Map.has_key?(audit, &1))
    |> Enum.reduce(changeset, fn key, acc ->
      add_error(
        acc,
        :architecture_audit,
        "is missing required key #{inspect(key)} — every audit writes all of " <>
          "#{inspect(@architecture_audit_required_keys)}, explicitly nil where it " <>
          "has no value yet, so no reader has to distinguish an absent key from a nil one"
      )
    end)
  end

  defp validate_audit_state(changeset, audit) do
    case Map.get(audit, "state") do
      "expired" ->
        add_error(
          changeset,
          :architecture_audit,
          "has invalid state \"expired\" — an elapsed deadline is projected by " <>
            "Platform.Architecture.StageAudit.read/1 from a persisted \"pending\" " <>
            "row and is never written. Persisting it would give one fact two " <>
            "representations that can disagree"
        )

      state when is_binary(state) ->
        if state in @architecture_audit_states do
          changeset
        else
          add_error(
            changeset,
            :architecture_audit,
            "has invalid state #{inspect(state)} " <>
              "(allowed: #{inspect(@architecture_audit_states)})"
          )
        end

      _other ->
        add_error(
          changeset,
          :architecture_audit,
          "must include a string \"state\" key " <>
            "(one of: #{Enum.join(@architecture_audit_states, ", ")})"
        )
    end
  end

  # An unknown source is REJECTED, not coerced — the same construction
  # `Plan.architecture_verdict_changeset/2` uses, after that column spent
  # a whole stack storing `"architect"` and `"dispatch"`, values no reader
  # was documented to expect.
  defp validate_audit_source(changeset, audit) do
    case Map.get(audit, "source") do
      nil ->
        changeset

      source when is_binary(source) ->
        if source in @architecture_audit_sources do
          changeset
        else
          add_error(
            changeset,
            :architecture_audit,
            "has invalid source #{inspect(source)} " <>
              "(allowed: #{inspect(@architecture_audit_sources)}, or nil)"
          )
        end

      other ->
        add_error(
          changeset,
          :architecture_audit,
          "\"source\" must be a string or nil (got #{inspect(other)})"
        )
    end
  end

  defp validate_audit_findings(changeset, audit) do
    case Map.get(audit, "findings") do
      nil ->
        changeset

      findings when is_list(findings) ->
        Enum.reduce(findings, changeset, &validate_audit_finding/2)

      _other ->
        add_error(changeset, :architecture_audit, "\"findings\" must be a list")
    end
  end

  defp validate_audit_finding(%{"constraint" => constraint, "detail" => detail}, acc)
       when is_binary(constraint) and is_binary(detail) do
    acc
    |> then(fn acc ->
      # REUSED from `Plan.architecture_constraints/0`, never re-listed:
      # the architect audits for architecture, not for style, naming or
      # taste, and one vocabulary shared by both architect surfaces is
      # what stops them drifting apart again.
      if constraint in Plan.architecture_constraints() do
        acc
      else
        add_error(
          acc,
          :architecture_audit,
          "finding has invalid constraint #{inspect(constraint)} " <>
            "(allowed: #{inspect(Plan.architecture_constraints())}). " <>
            "0046-design-and-architecture-phases-in-planning.md § Architect prompt contract" <>
            " — the architect audits for architecture, not for style, naming or taste."
        )
      end
    end)
    |> then(fn acc ->
      if String.trim(detail) == "" do
        add_error(acc, :architecture_audit, "finding \"detail\" must be a non-empty string")
      else
        acc
      end
    end)
  end

  defp validate_audit_finding(finding, acc) when is_map(finding) do
    add_error(
      acc,
      :architecture_audit,
      "finding must include string \"constraint\" and \"detail\" keys, got: #{inspect(Map.keys(finding))}"
    )
  end

  defp validate_audit_finding(_other, acc) do
    add_error(acc, :architecture_audit, "each finding must be a map")
  end
end
