defmodule Platform.Repo.Migrations.AddAutoPromoteToExperiments do
  use Ecto.Migration

  @moduledoc """
  Task 019fe6ba, ADR-0048 — the per-experiment auto-promotion flag.

  Adds `experiments.auto_promote`, a boolean defaulting to FALSE and NOT
  NULL. Automatic promotion is opt-in per experiment: an experiment created
  before this column existed, or created without an opinion, must not start
  rewriting a live prompt template on its own.

  The flag controls WHO may call the promotion entry point, not WHAT that
  call does. `Platform.Experiments.Promotion.promote/2` is the single path
  to the content update for both manual and automatic promotion; the flag is
  checked inside it, so it cannot be routed around by a second caller.

  Default false and null: false rather than a nullable column, because a NULL
  read as "unset" is exactly the value a later `if experiment.auto_promote`
  would have to guess about.
  """

  def change do
    alter table(:experiments) do
      add(:auto_promote, :boolean, null: false, default: false)
    end
  end
end
