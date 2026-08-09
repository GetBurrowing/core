defmodule Platform.Lifecycle.Runs do
  @moduledoc """
  Reads and writes for `lifecycle_step_runs` (ADR-0046 Amendment 1,
  task 019fe1b6 stage 1).

  Storage only — this member calls no step, awaits nothing, honours no
  divert and enforces no budget. The runner is a later member of the stack.

  ## `run_count/2` counts firings, `for_edge/2` returns rows

  These answer different questions and must not be confused. One firing of a
  three-step pipeline is THREE rows and ONE run. The re-entry bound is
  expressed in firings, so `run_count/2` counts DISTINCT `run_seq`; using
  `Repo.aggregate(:count)` there would bound the pipeline at one transition
  for any project whose pipeline has more steps than the bound.
  """

  import Ecto.Query

  alias Platform.Lifecycle.StepRun
  alias Platform.Repo

  @doc "Persist one step run."
  @spec record(map()) :: {:ok, StepRun.t()} | {:error, Ecto.Changeset.t()}
  def record(attrs) do
    %StepRun{}
    |> StepRun.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  The `run_seq` the next firing of this edge should use.

  `1` when the edge has never fired.
  """
  @spec next_run_seq(Ecto.UUID.t(), String.t()) :: pos_integer()
  def next_run_seq(task_id, edge) do
    query =
      from(r in StepRun,
        where: r.task_id == ^task_id and r.edge == ^edge,
        select: max(r.run_seq)
      )

    case Repo.one(query) do
      nil -> 1
      max -> max + 1
    end
  end

  @doc """
  How many times this edge has FIRED — the number of distinct `run_seq`
  values, not the number of rows.
  """
  @spec run_count(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def run_count(task_id, edge) do
    query =
      from(r in StepRun,
        where: r.task_id == ^task_id and r.edge == ^edge,
        select: count(r.run_seq, :distinct)
      )

    Repo.one(query) || 0
  end

  @doc "Every recorded run for this edge, oldest firing first, in step order."
  @spec for_edge(Ecto.UUID.t(), String.t()) :: [StepRun.t()]
  def for_edge(task_id, edge) do
    from(r in StepRun,
      where: r.task_id == ^task_id and r.edge == ^edge,
      order_by: [asc: r.run_seq, asc: r.position]
    )
    |> Repo.all()
  end
end
