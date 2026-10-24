defmodule Platform.Repo.Migrations.AgentAttentionControls do
  use Ecto.Migration

  @moduledoc """
  Task `01a1557a-8f80-7000-9ee4-40b29760da18` (Burrow redesign rung 8),
  stage 1: persist the three choices a space member makes about agents.

    * `chat_spaces.watch_enabled` is RENAMED IN PLACE to `agents_awake`, the
      space's master switch. The old column had no reader and no writer in
      `lib/` (task 019f9790 removed its toggle), so its DM-only `true` values
      mean nothing now: every row is set to `true`, which is today's
      behaviour (un-mentioned messages reach the mutex holder).
    * `chat_spaces.agent_attention_policy` (`on_mention | directed |
      collaborative`, NULL = the kind default). Every EXISTING channel and
      group row is backfilled `'on_mention'`, so no existing space changes
      behaviour: the group kind default is `collaborative`, and a NULL group
      row would otherwise start fanning un-mentioned messages out to every
      agent. The kind default only applies to spaces created after this.
    * `chat_participants.silenced`, the per-agent "mention-only" switch.

  `down/0` reverses the schema. It cannot restore the dead column's old
  values, and does not try.
  """

  @policy_check "agent_attention_policy IS NULL OR " <>
                  "agent_attention_policy IN ('on_mention', 'directed', 'collaborative')"

  def up do
    rename(table(:chat_spaces), :watch_enabled, to: :agents_awake)

    execute("UPDATE chat_spaces SET agents_awake = true")

    alter table(:chat_spaces) do
      modify(:agents_awake, :boolean, default: true, null: false)
      add(:agent_attention_policy, :string)
    end

    create(
      constraint(:chat_spaces, :chat_spaces_agent_attention_policy_check, check: @policy_check)
    )

    execute("""
    UPDATE chat_spaces
    SET agent_attention_policy = 'on_mention'
    WHERE kind IN ('channel', 'group')
    """)

    alter table(:chat_participants) do
      add(:silenced, :boolean, default: false, null: false)
    end
  end

  def down do
    alter table(:chat_participants) do
      remove(:silenced)
    end

    drop(constraint(:chat_spaces, :chat_spaces_agent_attention_policy_check))

    alter table(:chat_spaces) do
      remove(:agent_attention_policy)
      modify(:agents_awake, :boolean, default: false, null: false)
    end

    rename(table(:chat_spaces), :agents_awake, to: :watch_enabled)
  end
end
