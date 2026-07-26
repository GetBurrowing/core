defmodule Platform.Tasks.Plan do
  @moduledoc """
  A versioned plan for a task.

  ## Why `architecture_verdict` lives here and not on `tasks`

  ADR-0046 member 5 adds an architecture gate between `plan_submit` and
  `approve`. Its state is a property of a plan VERSION, not of the task:

    * Member 6 (`019f9b29-251e`) produces a v2 after a reject and must
      count iterations. A task-level verdict makes v2 silently inherit
      v1's verdict and forces member 6 to invent a parallel per-version
      history. `plans.version` already IS that history, and
      `Tasks.list_plans/1` already walks it ascending.
    * The verdict column and member 4's `tasks.planning_step_outcomes`
      answer DIFFERENT questions and must not be collapsed.
      `planning_step_outcomes["architecture"]["outcome"]` answers *did
      the dispatch happen* (`complete | not_applicable | failed` —
      `Platform.Responsibilities.outcome/1`'s range).
      `plans.architecture_verdict["state"]` answers *what did the
      architect say*. One slot for both puts a failed dispatch and a
      reject verdict in the same value, which is exactly the ADR-0046:83
      conflation this stack exists to undo.

  REJECTED ALTERNATIVE — a separate `plan_reviews` table. It would be
  strictly 1:1 with `plans`, add a join to every gate read on the hot
  approval path, and buy nothing: member 6's escalation needs the
  accumulated objections, which it gets by walking `Tasks.list_plans/1`
  and reading each version's verdict.

  ## The verdict shape

  JSONB, string keys throughout — it round-trips through Postgres and
  through the MCP tool stage 4 adds.

      %{
        "state"              => one of `architecture_gate_states/0`,
        "opened_at"          => iso8601,
        "deadline_at"        => iso8601,
        "resolved_at"        => iso8601 | nil,
        "resolved_by"        => string | nil,
        "architect_agent_id" => uuid | nil,
        "source"             => "mcp" | "handle_output" | "deadline" | "human" | nil,
        "summary"            => string | nil,
        "findings"           => [%{"stage_id" => uuid | nil,
                                   "stage_name" => string | nil,
                                   "constraint" => one of `architecture_constraints/0`,
                                   "detail" => non-empty string}]
      }

  ## The closed constraint vocabulary is the prompt contract made enforceable

  ADR-0046:95 says the architect rejects only for module boundaries,
  data model, cross-context coupling and duplicated logic, and
  explicitly NOT for taste, naming or style. "Do not reject for style"
  is unenforceable as prose. A closed four-value enum means a style
  objection has NO REPRESENTABLE VALUE — the boundary refuses it rather
  than the prompt discouraging it. Stage 4's prompt uses these four
  literals verbatim so the model and the validator speak one vocabulary.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Platform.Types.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft pending_review approved rejected superseded executing completed)

  # ADR-0046 member 5. The lifecycle of the architecture gate for ONE
  # plan version. `pending` is the only non-terminal state; the other
  # five are terminal and `Tasks.record_architecture_verdict/3` is
  # one-shot against them.
  @architecture_gate_states ~w(pending passed rejected expired dispatch_failed human_override)

  # ADR-0046:95's closed rejection vocabulary. Public accessor because a
  # guard that hardcodes its own copy of a list is how the class comes
  # back (member 4's rule); stage 4's tool boundary reads this.
  @architecture_constraints ~w(module_boundary data_model cross_context_coupling duplicated_logic)

  schema "plans" do
    belongs_to(:task, Platform.Tasks.Task)
    field(:status, :string, default: "draft")
    field(:version, :integer)
    # Generic actor identifier: may be a user UUID or a system/runtime label.
    field(:approved_by, :string)
    field(:approved_at, :utc_datetime_usec)
    # Auto-approve plan (task 019f25f2): timestamp captured when the
    # opt-in `tasks.auto_approve_plan` flag fires. Distinct from
    # `approved_at` (still set by the shared approval codepath) so
    # downstream observers can distinguish auto- vs. manual-review
    # approvals. Nullable — most plans never carry this marker.
    field(:auto_approved_at, :utc_datetime_usec)
    # Free-text reason captured when a plan is rejected. Reused by the
    # reopen-with-feedback flow (see task 019dfad1). Validation lives
    # in the UI/lifecycle layers, not here.
    field(:rejection_reason, :string)
    # Self-referential FK pointing to the plan that replaced this one.
    # Set by the auto-supersession lifecycle helper (stage 2 of task
    # 019dfd5a). Nullable: plans that were never superseded leave it nil.
    belongs_to(:superseded_by, Platform.Tasks.Plan, foreign_key: :superseded_by_plan_id)

    # ADR-0046 member 5: the architecture gate's state for THIS plan
    # version. See the moduledoc for the shape and for why it lives
    # here. NULL means the gate never opened for this version — a
    # distinct fact from "opened and produced nothing", which is why
    # there is no `default: %{}`.
    #
    # Written ONLY through `architecture_verdict_changeset/2` — it is
    # deliberately absent from `changeset/2`'s cast list below.
    field(:architecture_verdict, :map)

    has_many(:stages, Platform.Tasks.Stage)

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "The closed set of `architecture_verdict[\"state\"]` values."
  def architecture_gate_states, do: @architecture_gate_states

  @doc """
  The closed set of grounds an architect may reject a plan on
  (ADR-0046:95). Style, naming and taste are absent BY CONSTRUCTION.
  """
  def architecture_constraints, do: @architecture_constraints

  # DELIBERATELY ABSENT from the cast list below: `:architecture_verdict`
  # (ADR-0046 member 5). Load-bearing in both directions, the same
  # reasoning member 4 applied to `Task.changeset/2`:
  #
  #   * `changeset/2` casts `:status`, which makes it the unguarded
  #     plan-status writer. Routing verdict writes through it would put
  #     the gate's state on that same unguarded surface — a verdict
  #     write could smuggle `status: "approved"` past the gate it is
  #     supposed to be reporting to.
  #   * Symmetrically, a caller holding only
  #     `architecture_verdict_changeset/2` cannot smuggle a `:status`
  #     change through it.
  #
  # Both directions are proved in `architecture_gate_test.exs`, not in
  # this comment. Do not "simplify" by merging the two cast lists.
  def changeset(plan, attrs) do
    plan
    |> cast(attrs, [
      :task_id,
      :status,
      :version,
      :approved_by,
      :approved_at,
      :auto_approved_at,
      :rejection_reason,
      :superseded_by_plan_id
    ])
    |> validate_required([:task_id, :version])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:task_id, :version])
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:superseded_by_plan_id)
  end

  @doc """
  The entire write surface for `:architecture_verdict`.

  Casts ONLY `:architecture_verdict`. Anything else in `attrs` —
  including `:status` — is ignored, by design. See the comment above
  `changeset/2`.

  Validations (all of them structural; the lifecycle rules — one-shot,
  level-triggered expiry — live in `Platform.Tasks`, because they need
  the persisted row, not just the change):

    * a string-keyed map (`nil` is not castable here; clearing a verdict
      is not an operation this schema offers);
    * `"state"` present and in `architecture_gate_states/0`;
    * `"findings"`, when present, a list of maps, each with a
      `"constraint"` in `architecture_constraints/0` and a non-empty
      binary `"detail"`.

  An unknown state string is REJECTED, not coerced. A writer must not be
  able to introduce a seventh state that downstream readers would then
  have to guess about — `Tasks.architecture_gate/1` branches on exactly
  the six.
  """
  def architecture_verdict_changeset(plan, attrs) do
    plan
    |> cast(attrs, [:architecture_verdict])
    |> validate_architecture_verdict()
  end

  defp validate_architecture_verdict(changeset) do
    case get_change(changeset, :architecture_verdict) do
      nil ->
        changeset

      verdict when is_map(verdict) ->
        changeset
        |> validate_verdict_string_keys(verdict)
        |> validate_verdict_state(verdict)
        |> validate_verdict_findings(verdict)

      _other ->
        add_error(changeset, :architecture_verdict, "must be a map")
    end
  end

  # String keys throughout: the map round-trips through JSONB, which
  # returns strings, so an atom-keyed write would read back different
  # from what was written. Rejecting at the boundary keeps the two
  # halves of that round trip identical.
  defp validate_verdict_string_keys(changeset, verdict) do
    if Enum.all?(Map.keys(verdict), &is_binary/1) do
      changeset
    else
      add_error(changeset, :architecture_verdict, "must use string keys")
    end
  end

  defp validate_verdict_state(changeset, verdict) do
    case Map.get(verdict, "state") do
      state when is_binary(state) ->
        if state in @architecture_gate_states do
          changeset
        else
          add_error(
            changeset,
            :architecture_verdict,
            "has invalid state #{inspect(state)} " <>
              "(allowed: #{inspect(@architecture_gate_states)})"
          )
        end

      _other ->
        add_error(
          changeset,
          :architecture_verdict,
          "must include a string \"state\" key " <>
            "(one of: #{Enum.join(@architecture_gate_states, ", ")})"
        )
    end
  end

  defp validate_verdict_findings(changeset, verdict) do
    case Map.get(verdict, "findings") do
      nil ->
        changeset

      findings when is_list(findings) ->
        Enum.reduce(findings, changeset, &validate_verdict_finding/2)

      _other ->
        add_error(changeset, :architecture_verdict, "\"findings\" must be a list")
    end
  end

  defp validate_verdict_finding(%{"constraint" => constraint, "detail" => detail}, acc)
       when is_binary(constraint) and is_binary(detail) do
    acc
    |> then(fn acc ->
      if constraint in @architecture_constraints do
        acc
      else
        add_error(
          acc,
          :architecture_verdict,
          "finding has invalid constraint #{inspect(constraint)} " <>
            "(allowed: #{inspect(@architecture_constraints)}). ADR-0046:95 — the architect " <>
            "rejects for architecture, not for style, naming or taste."
        )
      end
    end)
    |> then(fn acc ->
      if String.trim(detail) == "" do
        add_error(acc, :architecture_verdict, "finding \"detail\" must be a non-empty string")
      else
        acc
      end
    end)
  end

  defp validate_verdict_finding(finding, acc) when is_map(finding) do
    add_error(
      acc,
      :architecture_verdict,
      "finding must include string \"constraint\" and \"detail\" keys, got: #{inspect(Map.keys(finding))}"
    )
  end

  defp validate_verdict_finding(_other, acc) do
    add_error(acc, :architecture_verdict, "each finding must be a map")
  end
end
