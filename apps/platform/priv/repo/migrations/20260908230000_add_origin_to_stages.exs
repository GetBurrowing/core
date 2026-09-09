defmodule Platform.Repo.Migrations.AddOriginToStages do
  @moduledoc """
  Task 01a0588e stage 1: adds `stages.origin` so a planner-authored stage is
  structurally distinguishable from an engine-synthesized one, which the
  architecture gate needs in order to refuse a plan with no authored
  implementation stage. Nothing today represents that distinction.
  """

  use Ecto.Migration

  # Task 01a0588e stage 1. A structural marker for WHO wrote a stage:
  # the planner ("authored") or the plan engine ("synthesized").
  #
  # The backfill IS the default. Every pre-existing row reads "authored",
  # which is the correct reading of history: the marker is an INPUT written
  # at insert time, not a fact inferred after the fact. Deliberately NO
  # retroactive reclassification pass over old "Task-level review" rows —
  # inferring origin from a name or a description is exactly the failure
  # mode this column exists to make impossible.
  def change do
    alter table(:stages) do
      add(:origin, :string, null: false, default: "authored")
    end
  end
end
