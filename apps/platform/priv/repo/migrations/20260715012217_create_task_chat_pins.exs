defmodule Platform.Repo.Migrations.CreateTaskChatPins do
  use Ecto.Migration

  @moduledoc """
  Pin-to-Chat, stage 2 (task 019f62a1).

  Creates the `task_chat_pins` table backing `Platform.Tasks.ChatPins`.
  A pin row is a per-participant subscription to a task's execution chat
  space. The execution space itself is created lazily on the FIRST pin
  (or the first `Platform.Orchestration.ExecutionSpace.find_or_create/1`
  call from the plan engine, whichever wins) so backlog tasks that are
  never picked up leave zero `chat_spaces` rows.

  ## Columns

    * `task_id` — FK into `tasks(id)` with `ON DELETE CASCADE`. Pins die
      with the task.

    * `participant_kind` — `"user"` or `"agent"`. The context layer
      enforces inclusion; the DB only enforces `NOT NULL`.

    * `participant_id` — email for `user` rows, agent slug for `agent`
      rows. Stored as text (`:string`) so we can key on either identity
      shape without carrying two separate columns.

    * `pinned_by` — email of the sponsor or mentioner that caused the
      pin. Attribution only; not used for authority checks.

  ## Indexes

    * `unique_index(:task_id, :participant_kind, :participant_id)` —
      idempotency guard. Repeated `pin/3` calls upsert with
      `on_conflict: :nothing` and short-circuit the broadcast.

    * `index(:participant_kind, :participant_id)` — hot path for
      `list_pinned_task_spaces_for/1`, which resolves every task space a
      participant should see in the rail on every ChatLive mount.

  ## Migration hygiene

  This migration MUST NOT call `Platform.Audit.record/1` or any code
  path that broadcasts via `Phoenix.PubSub`. Migrations run before the
  app supervision tree — PubSub isn't up yet. See the 2026-07-14
  outage journal + PR #545 for the cascade that surfaced this rule.
  """

  def change do
    create table(:task_chat_pins, primary_key: false) do
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))

      add(
        :task_id,
        references(:tasks, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:participant_kind, :string, null: false)
      add(:participant_id, :string, null: false)
      add(:pinned_by, :string, null: false)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(
      unique_index(:task_chat_pins, [:task_id, :participant_kind, :participant_id],
        name: :task_chat_pins_task_participant_idx
      )
    )

    create(index(:task_chat_pins, [:participant_kind, :participant_id]))
  end
end
