defmodule Platform.Experiments.Signals do
  @moduledoc """
  Records and lists experiment signals. Task 01a0d415, the
  experimentation-layer ADR-0052.

  `record/1` is IDEMPOTENT on `(experiment_id, source_type, source_id)`:
  recording the same source twice returns the row already there, unchanged.
  A labeler re-run, a redelivered event or a retried job therefore cannot
  count one outcome twice.

  There is NO delete function here, and none may be added. A signal is the
  evidence an outcome metric counts; deleting one changes a result with no
  record that it changed. A wrong label is corrected by the labeler writing
  its verdict, not by removing the row.
  """

  import Ecto.Query

  alias Platform.Experiments.Experiment
  alias Platform.Experiments.Signal
  alias Platform.Repo

  @doc """
  Records a signal, or returns the existing row for the same source.
  """
  @spec record(map()) :: {:ok, Signal.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    changeset = Signal.changeset(%Signal{}, attrs)

    case Repo.insert(changeset) do
      {:ok, signal} ->
        {:ok, signal}

      {:error, %Ecto.Changeset{} = failed} ->
        if unique_violation?(failed) do
          # The source was already recorded; its row is the signal.
          {:ok, existing!(changeset)}
        else
          {:error, failed}
        end
    end
  end

  @doc """
  Lists an experiment's signals, oldest first. Options: `:status`,
  `:subject_id`.
  """
  @spec list(Experiment.t() | Ecto.UUID.t(), keyword()) :: [Signal.t()]
  def list(experiment, opts \\ [])
  def list(%Experiment{id: id}, opts), do: list(id, opts)

  def list(experiment_id, opts) when is_binary(experiment_id) do
    Signal
    |> where([s], s.experiment_id == ^experiment_id)
    |> filter(:status, Keyword.get(opts, :status))
    |> filter(:subject_id, Keyword.get(opts, :subject_id))
    |> order_by([s], asc: s.inserted_at, asc: s.id)
    |> Repo.all()
  end

  defp filter(query, _field, nil), do: query
  defp filter(query, :status, status), do: where(query, [s], s.status == ^status)
  defp filter(query, :subject_id, id), do: where(query, [s], s.subject_id == ^id)

  defp unique_violation?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_msg, meta}} ->
      meta[:constraint] == :unique and
        meta[:constraint_name] == Atom.to_string(Signal.unique_index_name())
    end)
  end

  defp existing!(changeset) do
    experiment_id = Ecto.Changeset.get_field(changeset, :experiment_id)
    source_type = Ecto.Changeset.get_field(changeset, :source_type)
    source_id = Ecto.Changeset.get_field(changeset, :source_id)

    Repo.one!(
      from(s in Signal,
        where:
          s.experiment_id == ^experiment_id and s.source_type == ^source_type and
            s.source_id == ^source_id
      )
    )
  end
end
