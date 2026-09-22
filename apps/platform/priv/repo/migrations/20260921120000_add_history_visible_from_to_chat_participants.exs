defmodule Platform.Repo.Migrations.AddHistoryVisibleFromToChatParticipants do
  @moduledoc """
  Task 01a0ac64-a959-7001-9ca2-e429535a1bb2 stage 1.

  A mention-granted participant row records WHEN the grant happened so the
  read path can bound the history it hands over. NULL means unbounded —
  a pre-existing row, or one created by the dispatch-side add path
  (`Platform.Chat.DispatchMembership.ensure_writable/3`), which keeps
  writing NULL deliberately.
  """
  use Ecto.Migration

  def change do
    alter table(:chat_participants) do
      add(:history_visible_from, :utc_datetime_usec)
    end
  end
end
