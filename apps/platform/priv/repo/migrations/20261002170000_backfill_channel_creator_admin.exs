defmodule Platform.Repo.Migrations.BackfillChannelCreatorAdmin do
  @moduledoc """
  Task 01a0fd62-a7ef-7001-8477-bd17e47bbaca stage 1 — promote the provable
  creator of each existing channel to `role = 'admin'`.

  ## The defect

  Before this task `Platform.Chat.create_space/1` seated nobody but the
  role-pinned historian. The "+ New channel" modal never set `created_by`, and
  the creator's row came later from `ChatLive.ensure_participant/2`, which
  writes no role, so the schema default `"member"` applied. No code path
  outside federation `seat_admin/2` granted a user `role: "admin"` in a
  channel, so since #1053 (task 01a0ac64) `Chat.mention_summon_authorized?/2`
  has been false for every human author in every channel. The code fix seats
  the creator from now on; this migration repairs the channels that already
  exist, and only where the creator can be PROVEN.

  Measured read-only on prod (`core_platform`, 2026-10-02, inside
  `BEGIN TRANSACTION READ ONLY ... ROLLBACK`): 47 channels, 43 with
  `created_by IS NULL`, 0 with any admin row. Clause A matched 4 rows and
  clause B matched 21. Space `01a0fd55-542f-7001-b7ec-3f50b659d6d8`
  (survival-game) matches clause B: its only rows are the heartbeat
  historian (+0.009 s) and its creator's user row (+0.80 s).

  ## What it does

  Two UPDATEs. Both are restricted to `chat_spaces.kind = 'channel'`,
  `participant_type = 'user'` and `role = 'member'`, so observer, principal and
  admin rows are never touched, and DM, group and execution spaces are out of
  scope entirely.

  ### A. `created_by IS NOT NULL`

  The creator is recorded. Promote the user row whose `participant_id` is
  `created_by`.

  ### B. `created_by IS NULL`

  Every UI-created channel before this task. A user row is promoted ONLY IF
  all of these hold:

    * it is the EARLIEST participant in the space by `joined_at`, ignoring
      agent rows with `attention_mode = 'heartbeat'` (the historian auto-join
      in `create_space/1`). An agent-created MCP channel has its calling agent
      first and is therefore excluded;
    * its `joined_at` is no later than `chat_spaces.inserted_at + 60 seconds`:
      the modal and the URL bootstrap both seat the creator during the same
      navigation that created the channel;
    * NO other user participant joined within that window;
    * the space has no admin row yet.

  First-in-window is the evidence for creator identity: on main there is no
  other route to it. Anything ambiguous is left alone. That keeps the rule
  "promote no one but the creator", at the cost of leaving some old channels
  without an admin.

  ## What it deliberately does not do

  It never stamps `created_by`. `can_archive?` keys on that column
  (`PlatformWeb.ChatLive.SettingsComponent`), and granting archive rights is
  not this task.

  `down/0` is a documented no-op. A demotion cannot tell the admins this
  migration created from ones granted afterwards, so reversing it would demote
  people who earned the role legitimately.
  """
  use Ecto.Migration

  @clause_a """
  UPDATE chat_participants AS p
     SET role = 'admin'
    FROM chat_spaces AS s
   WHERE p.space_id = s.id
     AND s.kind = 'channel'
     AND s.created_by IS NOT NULL
     AND p.participant_type = 'user'
     AND p.role = 'member'
     AND p.participant_id = s.created_by
  """

  @clause_b """
  UPDATE chat_participants AS p
     SET role = 'admin'
    FROM chat_spaces AS s
   WHERE p.space_id = s.id
     AND s.kind = 'channel'
     AND s.created_by IS NULL
     AND p.participant_type = 'user'
     AND p.role = 'member'
     AND p.joined_at <= s.inserted_at + interval '60 seconds'
     AND NOT EXISTS (
       SELECT 1 FROM chat_participants AS a
        WHERE a.space_id = s.id AND a.role = 'admin'
     )
     AND NOT EXISTS (
       SELECT 1 FROM chat_participants AS o
        WHERE o.space_id = s.id
          AND o.id <> p.id
          AND o.participant_type = 'user'
          AND o.joined_at <= s.inserted_at + interval '60 seconds'
     )
     AND NOT EXISTS (
       SELECT 1 FROM chat_participants AS e
        WHERE e.space_id = s.id
          AND e.id <> p.id
          AND NOT (e.participant_type = 'agent' AND e.attention_mode = 'heartbeat')
          AND e.joined_at <= p.joined_at
     )
  """

  @doc false
  def clause_a_sql, do: @clause_a

  @doc false
  def clause_b_sql, do: @clause_b

  def up do
    execute(@clause_a)
    execute(@clause_b)
  end

  # Intentional no-op; see the moduledoc.
  def down, do: :ok
end
