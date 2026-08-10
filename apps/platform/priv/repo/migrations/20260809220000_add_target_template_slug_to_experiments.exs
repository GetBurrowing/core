defmodule Platform.Repo.Migrations.AddTargetTemplateSlugToExperiments do
  use Ecto.Migration

  @moduledoc """
  Task 019fe6b9 (variant resolution at the template read point), ADR-0048.

  Adds the column that says WHICH prompt template an experiment is an
  experiment ON.

  ## Why this column did not already exist, and why it has to

  `20260809191424_create_experiments.exs` created `experiments` with
  `(slug, name, hypothesis, primary_metric, status, stop_rule)` and nothing
  else. `Platform.Experiments.activate/2` takes a prompt template, copies its
  `content` into the `control` variant row, and then drops the reference on
  the floor — the snapshot survives, the linkage does not.

  That is an omission, not a deliberate deferral. ADR-0048 assumes the link
  throughout: "editing a template in AdminPromptsLive while an experiment
  targets its slug", and the risk register's "at most one active assignment
  per (subject, slug)". Without it the read point has no question it can ask:
  a resolver at `render_template/2` is handed a template slug and there is no
  predicate connecting that slug to any experiment row, so the entire
  resolution step is inexpressible rather than merely awkward.

  ## Why a SLUG and not a template_id FK

  `render_template/2` is called with a slug and never loads a template id
  before it needs to know whether an experiment applies. Storing the id would
  force the resolver to fetch the template row first purely to translate one
  key into the other, on the hot path of every dispatch in the system, for a
  join it does not otherwise need. The slug is also the stable public handle:
  `prompt_templates.slug` carries a unique index, callers pin slugs as module
  attributes (`@template_slug "stacks.dep_inference.v1"`), and a template
  deleted and re-seeded keeps its slug but not its id — under an FK that
  re-seed would either cascade the experiment away or block the delete, and
  under a slug the experiment survives it, which is the behaviour a
  months-long experiment record wants.

  Deliberately NOT a foreign key, for the same reason `experiment_assignments.subject_id`
  is a plain column: the target is a name, not a row pointer.

  ## Nullable, and the index is partial

  Nullable because the existing rows predate the column and because an
  experiment is created in `draft` before it is bound to anything —
  `create_experiment/1` does not know the target, `activate/2` does. Making
  it `null: false` would mean a draft cannot exist, which inverts the
  lifecycle.

  The index is partial on `status = 'running'` because that is the only
  question the read point asks often: "is there a live experiment on this
  slug?" A full index would also cover the terminal rows, which accumulate
  forever and are never the selective part of that lookup.
  """

  def change do
    alter table(:experiments) do
      add(:target_template_slug, :string)
    end

    create(
      index(:experiments, [:target_template_slug],
        where: "status = 'running'",
        name: :experiments_running_target_template_slug_index
      )
    )
  end
end
