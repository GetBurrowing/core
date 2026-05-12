defmodule Platform.Repo.Migrations.CreateTaskStacks do
  use Ecto.Migration

  @moduledoc """
  Task Stacks T1 stage 1 — schema only (task 019e1a37).

  Implements the schema section of `docs/decisions/0041-task-stacks.md`:

  1. New `task_stacks` table — groups of co-related tasks that ship together
     as a single rollup PR. Each stack has a slug (url-safe, used in the
     rollup branch name), a project, an optional epic, a status drawn from
     the lifecycle enum (`forming | in_progress | in_review | deploying |
     done | abandoned`), the rollup branch name, and a base branch that
     defaults to `main`. The `(project_id, slug)` pair is unique so slugs
     can collide across projects but never within one.

  2. `tasks` gains two columns:
     - `stack_id` — nullable FK into `task_stacks` with `ON DELETE SET NULL`
       (per the planner's nilify_all decision; abandoning a stack should
       not delete the member tasks).
     - `stack_position` — stable display ordering within a stack (1, 2, 3…).
       Dispatch order is derived from the existing `dependencies` DAG, not
       from this column.

  3. A partial index on `tasks(stack_id) WHERE stack_id IS NOT NULL`. Most
     tasks won't be in a stack, so the partial index keeps the index small
     while still accelerating stack-membership lookups.

  Reversible: the `change/0` callback uses `references/2` and `index/2`
  helpers that Ecto can run in both directions, so `mix ecto.rollback` will
  drop the index, the alter columns, and the table cleanly.

  Forbidden in this stage (deferred to stages 2-4):
  - The `Stack` ecto schema module (stage 2).
  - The `stack_pending` task status enum entry (stage 3).
  - Any context functions, MCP tools, UI, or engine wiring (stage 4).
  """

  def change do
    # ── task_stacks ──────────────────────────────────────────────────────────
    create table(:task_stacks, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:slug, :text, null: false)
      add(:name, :text, null: false)
      add(:description, :text)

      add(
        :project_id,
        references(:projects, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(
        :epic_id,
        references(:epics, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      add(:status, :text, null: false, default: "forming")
      add(:rollup_branch, :text, null: false)
      add(:base_branch, :text, null: false, default: "main")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:task_stacks, [:project_id, :slug], name: :task_stacks_slug_project_uniq))

    # ── tasks alterations ────────────────────────────────────────────────────
    alter table(:tasks) do
      add(
        :stack_id,
        references(:task_stacks, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      add(:stack_position, :integer, null: true)
    end

    create(
      index(:tasks, [:stack_id],
        where: "stack_id IS NOT NULL",
        name: :tasks_stack_id_idx
      )
    )
  end
end
