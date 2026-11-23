defmodule Platform.Repo.Migrations.AddGoalConversationSpace do
  @moduledoc """
  Each goal's own conversation space (task 01a20939 stage 1):
  `goals.conversation_space_id`, the hidden owner + coach space
  (`Platform.Goals.Conversation`). A confirmed proposal's space becomes its
  goal's space; a goal with no proposal gets one lazily on first use.

  `0055-extension-contract-and-build-time-modules.md § 6. Migrations`: this
  alters only `goals`, a Goals table, and references the stable core table
  `chat_spaces`; core never references a `goal_*` table. The column is
  nullable, and a deleted space nils it.

  The unique index holds one goal per space, so two goals can never share a
  conversation, and lets `Conversation.ensure_space/1` detect a lost race.
  """

  use Ecto.Migration

  # old-code-compatible: adds one nullable column and a unique index to goals, a Goals table; no core table changes and the previous release reads neither

  def change do
    alter table(:goals) do
      add(
        :conversation_space_id,
        references(:chat_spaces, type: :binary_id, on_delete: :nilify_all)
      )
    end

    create(unique_index(:goals, [:conversation_space_id]))
  end
end
