defmodule Platform.Repo.Migrations.MergeMeetingProducerIntoScribe do
  @moduledoc """
  Merge the `meeting_producer` role into `meeting_scribe` (super agents
  restructure). The producer had one key, `meetings.intent_classify`, read
  the same transcript as the scribe and already handed work to it.

  In order:

    1. **Carry the producer's agent over.** When the producer is held by an
       agent that does NOT also hold `meeting_scribe`, that agent gets a
       per-key override on `meetings.intent_classify`, so the classifier
       keeps running on exactly the agent it ran on before (usually a fast,
       cheap one). An existing override on the key is left alone. When the
       same agent held both roles (the default Burrow install) nothing is
       needed.
    2. **Move the bundle row** `meetings.intent_classify` to `meeting_scribe`.
       The responsibility key itself is unchanged, so every persisted
       reference to it (responsibilities row, prompt template, overrides,
       dispatch history) keeps working.
    3. **Refresh the scribe's description** to say it classifies live intent.
    4. **Delete the `meeting_producer` role.** The FK cascade clears its
       assignment and any bundle rows left.
    5. **Narrow `roles_key_check`** to the ten-key roster.

  `down/0` widens the CHECK, restores the role, moves the bundle row back
  and restores the description. A producer assignment and any override
  written by `up/0` are not reconstructed: the override already routes the
  key to the same agent.
  """

  use Ecto.Migration

  # old-code-compatible: the previous release resolves meetings.intent_classify by responsibility key (bundle row moves, key unchanged); its Burrow.ensure assign of meeting_producer fails the FK and is logged and skipped; its meeting intents bar reads agent_id_for_role("meeting_producer") as nil and hides, nothing crashes

  @roster_after "key IN ('designer','historian','meeting_scribe'," <>
                  "'triage_officer','security_guard','architect','agents_leader'," <>
                  "'scientist','janitor','showrunner')"

  @roster_before "key IN ('designer','historian','meeting_scribe','meeting_producer'," <>
                   "'triage_officer','security_guard','architect','agents_leader'," <>
                   "'scientist','janitor','showrunner')"

  @scribe_description_after "Capture, summarize, follow up after meetings; classify live meeting intent"
  @scribe_description_before "Capture, summarize, follow up after meetings"

  def up do
    carry_over!(repo())

    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_after))
  end

  @doc """
  Steps 1-4 (data only, no DDL), against `repo`. Public so the carry-over
  can be exercised on a staged pre-merge state in a sandboxed test.
  """
  def carry_over!(repo) do
    repo.query!(
      """
      INSERT INTO responsibility_overrides (id, responsibility_key, agent_id, inserted_at, updated_at)
      SELECT gen_random_uuid(), 'meetings.intent_classify', p.agent_id, now(), now()
      FROM role_assignments p
      WHERE p.role_key = 'meeting_producer'
        AND NOT EXISTS (
          SELECT 1 FROM role_assignments s
          WHERE s.role_key = 'meeting_scribe' AND s.agent_id = p.agent_id
        )
      ON CONFLICT (responsibility_key) DO NOTHING
      """,
      []
    )

    repo.query!(
      """
      INSERT INTO role_responsibilities (id, role_key, responsibility_key, inserted_at, updated_at)
      SELECT gen_random_uuid(), r.key, 'meetings.intent_classify', now(), now()
      FROM roles r
      WHERE r.key = 'meeting_scribe'
      ON CONFLICT (role_key, responsibility_key) DO NOTHING
      """,
      []
    )

    repo.query!(
      "UPDATE roles SET description = $1, updated_at = now() WHERE key = 'meeting_scribe'",
      [@scribe_description_after]
    )

    repo.query!("DELETE FROM roles WHERE key = 'meeting_producer'", [])

    :ok
  end

  def down do
    drop(constraint(:roles, :roles_key_check))
    create(constraint(:roles, :roles_key_check, check: @roster_before))

    flush()

    repo().query!(
      """
      INSERT INTO roles (key, name, description, icon, inserted_at, updated_at)
      VALUES ('meeting_producer', 'Meeting Producer',
              'Watches meeting transcript in real time; classifies intent and delegates to specialist agents',
              'hero-signal', now(), now())
      ON CONFLICT (key) DO NOTHING
      """,
      []
    )

    repo().query!(
      """
      DELETE FROM role_responsibilities
      WHERE role_key = 'meeting_scribe' AND responsibility_key = 'meetings.intent_classify'
      """,
      []
    )

    repo().query!(
      """
      INSERT INTO role_responsibilities (id, role_key, responsibility_key, inserted_at, updated_at)
      VALUES (gen_random_uuid(), 'meeting_producer', 'meetings.intent_classify', now(), now())
      ON CONFLICT (role_key, responsibility_key) DO NOTHING
      """,
      []
    )

    repo().query!(
      "UPDATE roles SET description = $1, updated_at = now() WHERE key = 'meeting_scribe'",
      [@scribe_description_before]
    )
  end
end
