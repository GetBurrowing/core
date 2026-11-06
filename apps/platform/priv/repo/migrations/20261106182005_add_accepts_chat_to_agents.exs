defmodule Platform.Repo.Migrations.AddAcceptsChatToAgents do
  @moduledoc """
  Task 01a1b20f: adds `agents.accepts_chat`, a per-agent opt-out of conversational chat
  replies for single-purpose agents. It applies to every agent kind, and
  defaults to `true` so every existing row keeps today's behaviour.
  """
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :accepts_chat, :boolean, null: false, default: true
    end
  end
end
