defmodule Platform.Experiments.Assignments do
  @moduledoc """
  Assigns subjects to experiment variants, once. Task 019fe6b9, ADR-0048.

  ## The whole contract is in the name

  `assign_once/2` reads any existing row for
  `(experiment_id, subject_type, subject_id)` and returns it UNCHANGED.
  Only when no row exists does it resolve a variant by weight and insert.

  There is deliberately no function here that recomputes an existing
  assignment — no `reassign`, no re-roll option, no "resolve" that writes.
  If one is ever genuinely needed it must be named so that its danger is
  legible at the call site; adding it quietly to this module would not be.

  Why it matters more than it looks: without stickiness a single task gets
  variant A at planning and variant B at execution. That is a contamination
  NO downstream metric can detect, because both rows are individually
  well-formed and neither looks wrong. The experiment still reports a
  number; the number is just about nothing.

  ## Two layers, because one is not enough

  The read-before-write path handles the ordinary case. The unique index
  `:experiment_assignments_subject_unique_index` is the backstop under a
  race, when two processes both read "no assignment" before either writes.
  A constraint violation is therefore NOT an error here — it means someone
  else won, so we re-read and return THEIR row. Both callers end up with the
  same variant, which is the point.

  ## Exclusions are recorded, never removed

  `exclude/3` sets `excluded_reason` and the row STAYS. There is no delete
  function in this module and none may be added. A subject dropped from the
  denominator with no record is how a result quietly becomes wrong: the
  arithmetic still works and the omission is invisible.

  `subject_type` stays generic (`"task"` today) so dispatch-level subjects
  work later without a migration.

  ## Eligibility: tenancy columns, then the experiment's `assignment_policy`

  `assign_once/3` takes the subject's attributes (`:project_id`, `:org_id`,
  `:epic_id`, `:inserted_at`) and, for a NEW subject only, decides
  eligibility before any row is written (task 01a0d415):

    1. **Tenancy columns.** A subject whose `project_id` differs from a
       non-null `experiment.project_id` is `:no_opinion`; for an org-wide
       experiment (org set, project null) the same holds for `org_id`. A
       subject that does not carry the attribute is not in scope. This is a column
       check, not a policy key: tenancy is who the experiment is FOR.
    2. **The policy chain.** A non-empty `assignment_policy` is built by
       `Platform.Experiments.PolicySpec` into the existing policy modules
       and asked for a decision:
         * `{:ok, slug}` — the row is written with that variant.
         * `{:excluded, reason}` — the row IS written, with
           `excluded_reason` set and the control slug as `variant_slug`. The
           subject was a candidate and was deliberately removed, so the
           removal stays visible and is never deleted (ADR-0048 Decision 3).
         * `:no_opinion` from the whole chain — NO row is written and
           `assign_once/3` returns `:no_opinion`. The subject was never
           eligible, and that is NOT an exclusion: writing an exclusion row for
           it would record a removal from an experiment it was never in, for
           every subject in the system the experiment was not about.
    3. **An empty policy with null project and org is today's weighted
       pick**, unchanged — every experiment that predates the policy column
       resolves exactly as it did.

  An EXISTING row still wins before any of this runs: eligibility is decided
  once, at first touch, like the variant.
  """

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.PolicySpec
  alias Platform.Experiments.Subject
  alias Platform.Experiments.Variant
  alias Platform.Repo

  @typedoc """
  A subject: anything an experiment can be applied to. Accepts a map with
  `subject_type`/`subject_id` (string or atom keys) or a `{type, id}` tuple.
  """
  @type subject :: map() | {String.t(), String.t()} | Subject.t()

  @doc """
  Returns the subject's assignment for this experiment, creating it only if
  it does not already exist.

  Called repeatedly with the same arguments this returns the same row and
  the same `variant_slug` every time, and leaves exactly one row behind.
  """
  @spec assign_once(Experiment.t(), subject()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()} | {:error, :no_variants}
  def assign_once(%Experiment{} = experiment, subject) do
    assign_once(experiment, subject, subject_attributes(subject))
  end

  @doc """
  `assign_once/2` with the subject's attributes, applying the experiment's
  tenancy columns and `assignment_policy` to a NEW subject. See the
  moduledoc. Returns `:no_opinion` (and writes nothing) when the subject is
  not eligible.
  """
  @spec assign_once(Experiment.t(), subject(), map()) ::
          {:ok, Assignment.t()}
          | :no_opinion
          | {:error, Ecto.Changeset.t()}
          | {:error, :no_variants}
  def assign_once(%Experiment{} = experiment, subject, attributes) when is_map(attributes) do
    {subject_type, subject_id} = subject_key(subject)

    case get_assignment(experiment, subject) do
      %Assignment{} = existing ->
        # The existing row wins, untouched. Note what is NOT here: no
        # re-resolution, no weight re-check, no update of any kind.
        {:ok, existing}

      nil ->
        case eligibility(experiment, subject_type, subject_id, attributes) do
          :weighted ->
            insert_assignment(experiment, subject_type, subject_id)

          {:ok, slug} ->
            write_assignment(experiment, subject_type, subject_id, slug, nil)

          {:excluded, reason} ->
            write_assignment(
              experiment,
              subject_type,
              subject_id,
              Experiment.control_slug(),
              reason
            )

          :no_opinion ->
            :no_opinion

          {:error, _} = error ->
            error
        end
    end
  end

  # Tenancy first — a column check, not a policy key — then the policy chain.
  defp eligibility(experiment, subject_type, subject_id, attributes) do
    cond do
      out_of_scope?(experiment.project_id, attr(attributes, :project_id)) ->
        :no_opinion

      # A project scope already implies its org (the experiment changeset
      # refuses a mismatch), so the org column is checked only for an
      # org-wide experiment.
      is_nil(experiment.project_id) and
          out_of_scope?(experiment.org_id, attr(attributes, :org_id)) ->
        :no_opinion

      true ->
        policy_decision(experiment, subject_type, subject_id, attributes)
    end
  end

  defp out_of_scope?(nil, _subject_value), do: false
  defp out_of_scope?(scope, subject_value), do: scope != subject_value

  defp policy_decision(experiment, subject_type, subject_id, attributes) do
    variants = list_variants(experiment)

    case PolicySpec.parse(experiment.assignment_policy || %{},
           experiment_id: experiment.id,
           variants: variants
         ) do
      :none ->
        :weighted

      {:ok, {module, opts}} ->
        subject = Subject.new(subject_type, subject_id, atomize_attributes(attributes))

        case module.assign(subject, opts) do
          {:ok, slug} = ok ->
            if Enum.any?(variants, &(&1.slug == slug)),
              do: ok,
              else: {:error, {:unknown_variant, slug}}

          other ->
            other
        end

      {:error, reasons} ->
        {:error, {:invalid_policy, reasons}}
    end
  end

  defp attr(attributes, key), do: Map.get(attributes, key) || Map.get(attributes, to_string(key))

  # Policies read atom keys. Only the documented keys are carried, so a
  # caller-supplied string never becomes an atom. `:agent_id` (task 01a114a8
  # stage 4) is the dispatched phase's assignee, which a `task_cohort` on
  # `agent_id` reads; without it here that cohort could never match.
  defp atomize_attributes(attributes) do
    for key <- [:project_id, :org_id, :epic_id, :inserted_at, :agent_id],
        value = attr(attributes, key),
        not is_nil(value),
        into: %{},
        do: {key, value}
  end

  defp subject_attributes(%Subject{attributes: attributes}), do: attributes
  defp subject_attributes(_subject), do: %{}

  defp list_variants(%Experiment{id: experiment_id}) do
    Repo.all(
      from(v in Variant, where: v.experiment_id == ^experiment_id, order_by: [asc: v.slug])
    )
  end

  @doc """
  Returns the subject's assignment for this experiment, or nil.

  A malformed `subject_id` folds into `nil` rather than raising. The subject
  is caller-supplied — a task id from a dispatch today, anything the later
  stack members choose tomorrow — and `where: a.subject_id == ^value` raises
  `Ecto.Query.CastError` on a malformed binary exactly as `Repo.get/2` does.
  """
  @spec get_assignment(Experiment.t(), subject()) :: Assignment.t() | nil
  def get_assignment(%Experiment{id: experiment_id}, subject) do
    {subject_type, subject_id} = subject_key(subject)

    if Platform.UUID.valid?(subject_id) do
      Repo.one(
        from(a in Assignment,
          where:
            a.experiment_id == ^experiment_id and
              a.subject_type == ^subject_type and
              a.subject_id == ^subject_id
        )
      )
    end
  end

  @doc "Lists every assignment for an experiment, excluded ones included."
  @spec list_assignments(Experiment.t()) :: [Assignment.t()]
  def list_assignments(%Experiment{id: experiment_id}) do
    Repo.all(
      from(a in Assignment,
        where: a.experiment_id == ^experiment_id,
        order_by: [asc: a.assigned_at]
      )
    )
  end

  @doc """
  Records that a subject is excluded from the analysis, with a reason.

  The row is UPDATED, never deleted, and its original `variant_slug` is left
  intact — the record of what the subject was given survives its exclusion.
  """
  @spec exclude(Experiment.t(), subject(), String.t()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_assigned}
  def exclude(%Experiment{} = experiment, subject, reason) when is_binary(reason) do
    case get_assignment(experiment, subject) do
      nil ->
        {:error, :not_assigned}

      %Assignment{} = assignment ->
        assignment
        |> Assignment.changeset(%{excluded_reason: reason})
        |> Repo.update()
    end
  end

  defp insert_assignment(experiment, subject_type, subject_id) do
    case pick_variant(experiment) do
      nil ->
        {:error, :no_variants}

      %Variant{slug: slug} ->
        write_assignment(experiment, subject_type, subject_id, slug, nil)
    end
  end

  defp write_assignment(experiment, subject_type, subject_id, slug, excluded_reason) do
    %Assignment{}
    |> Assignment.changeset(%{
      experiment_id: experiment.id,
      subject_type: subject_type,
      subject_id: subject_id,
      variant_slug: slug,
      assigned_at: DateTime.utc_now(),
      excluded_reason: excluded_reason
    })
    |> Repo.insert()
    |> case do
      {:ok, assignment} ->
        {:ok, assignment}

      {:error, changeset} ->
        # Someone else inserted between our read and our write. Their row
        # is the assignment; ours never existed. Re-read and return
        # theirs, so both callers agree on the variant.
        #
        # This depends on the constraint arriving as a changeset error
        # rather than a raised Ecto.ConstraintError, which is why the
        # index name is pinned explicitly in the migration — Ecto's
        # derived name for those three columns exceeds Postgres's 63-byte
        # identifier limit and would be truncated to something the
        # schema's unique_constraint could not match.
        requery_after_conflict(experiment, subject_type, subject_id, changeset)
    end
  end

  defp requery_after_conflict(experiment, subject_type, subject_id, changeset) do
    case get_assignment(experiment, %{subject_type: subject_type, subject_id: subject_id}) do
      %Assignment{} = winner -> {:ok, winner}
      nil -> {:error, changeset}
    end
  end

  # Weighted random choice across the experiment's variants, control included.
  # Zero-weight variants are reachable only if every variant is zero-weight,
  # in which case the choice is uniform rather than an error.
  defp pick_variant(%Experiment{id: experiment_id}) do
    variants =
      Repo.all(
        from(v in Variant, where: v.experiment_id == ^experiment_id, order_by: [asc: v.slug])
      )

    case variants do
      [] ->
        nil

      variants ->
        total = variants |> Enum.map(& &1.weight) |> Enum.sum()

        if total <= 0 do
          Enum.random(variants)
        else
          weighted_pick(variants, :rand.uniform(total))
        end
    end
  end

  defp weighted_pick([variant], _remaining), do: variant

  defp weighted_pick([%Variant{weight: weight} = variant | rest], remaining) do
    if remaining <= weight do
      variant
    else
      weighted_pick(rest, remaining - weight)
    end
  end

  defp subject_key(%Subject{type: subject_type, id: subject_id}),
    do: {subject_type, subject_id}

  defp subject_key({subject_type, subject_id}), do: {to_string(subject_type), subject_id}

  defp subject_key(%{subject_type: subject_type, subject_id: subject_id}),
    do: {to_string(subject_type), subject_id}

  defp subject_key(%{"subject_type" => subject_type, "subject_id" => subject_id}),
    do: {to_string(subject_type), subject_id}
end
