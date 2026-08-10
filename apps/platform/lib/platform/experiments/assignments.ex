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
  """

  import Ecto.Query

  alias Platform.Experiments.Assignment
  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Variant
  alias Platform.Repo

  @typedoc """
  A subject: anything an experiment can be applied to. Accepts a map with
  `subject_type`/`subject_id` (string or atom keys) or a `{type, id}` tuple.
  """
  @type subject :: map() | {String.t(), String.t()}

  @doc """
  Returns the subject's assignment for this experiment, creating it only if
  it does not already exist.

  Called repeatedly with the same arguments this returns the same row and
  the same `variant_slug` every time, and leaves exactly one row behind.
  """
  @spec assign_once(Experiment.t(), subject()) ::
          {:ok, Assignment.t()} | {:error, Ecto.Changeset.t()} | {:error, :no_variants}
  def assign_once(%Experiment{} = experiment, subject) do
    {subject_type, subject_id} = subject_key(subject)

    case get_assignment(experiment, subject) do
      %Assignment{} = existing ->
        # The existing row wins, untouched. Note what is NOT here: no
        # re-resolution, no weight re-check, no update of any kind.
        {:ok, existing}

      nil ->
        insert_assignment(experiment, subject_type, subject_id)
    end
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
        %Assignment{}
        |> Assignment.changeset(%{
          experiment_id: experiment.id,
          subject_type: subject_type,
          subject_id: subject_id,
          variant_slug: slug,
          assigned_at: DateTime.utc_now()
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

  defp subject_key({subject_type, subject_id}), do: {to_string(subject_type), subject_id}

  defp subject_key(%{subject_type: subject_type, subject_id: subject_id}),
    do: {to_string(subject_type), subject_id}

  defp subject_key(%{"subject_type" => subject_type, "subject_id" => subject_id}),
    do: {to_string(subject_type), subject_id}
end
