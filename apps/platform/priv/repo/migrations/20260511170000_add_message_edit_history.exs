defmodule Platform.Repo.Migrations.AddMessageEditHistory do
  use Ecto.Migration

  @moduledoc """
  Editable messages — schema + repo (task 019df568-357e).

  Implements section (a) of `docs/contracts/editable-messages-contract.md`:

  1. Three new columns on `chat_messages`:
     - `frozen_at` — timestamp the message became immutable.
     - `frozen_by_participant_id` — FK to the participant whose action froze it.
       Both-or-neither check constraint with `frozen_at`.
     - `corrects_message_id` — FK to a prior message, non-null only on agent
       correction messages (Policy 3).

  2. New `chat_message_versions` table — append-only edit history. v1 is the
     original message body (backfilled in this migration for existing rows;
     created in a transaction with the message insert for new rows in Task 3).
     `edited_by_display_name` is denormalized so version history survives
     participant deletion, following the ADR 0038 author-snapshot pattern.

  3. Indexes: unique `(message_id, version_number)` for the primary lookup +
     append integrity; secondary index on `message_id` alone for "fetch all
     versions" queries; partial index on `corrects_message_id` (only correction
     messages, which are a small minority of all messages).

  Backfill strategy: iterate `chat_messages` in 1000-row batches and insert
  one `chat_message_versions` row per message, setting `version_number=1`,
  `content=chat_messages.content`, `edited_at=chat_messages.inserted_at`, and
  `edited_by_*` from the snapshot already on `chat_messages`. Batched so the
  migration is safe at any volume.
  """

  def up do
    # ── 1. Three new columns on chat_messages ────────────────────────────────
    alter table(:chat_messages) do
      add(:frozen_at, :utc_datetime_usec, null: true)

      add(
        :frozen_by_participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      add(
        :corrects_message_id,
        references(:chat_messages, type: :binary_id, on_delete: :nilify_all),
        null: true
      )
    end

    # Both-or-neither: a frozen message must record who froze it.
    create(
      constraint(:chat_messages, :frozen_both_or_neither,
        check: "(frozen_at IS NULL AND frozen_by_participant_id IS NULL)
             OR (frozen_at IS NOT NULL AND frozen_by_participant_id IS NOT NULL)"
      )
    )

    create(
      index(:chat_messages, [:corrects_message_id],
        where: "corrects_message_id IS NOT NULL",
        name: :chat_messages_corrects_message_id_partial_index
      )
    )

    # ── 2. New chat_message_versions table ───────────────────────────────────
    create table(:chat_message_versions, primary_key: false) do
      add(:id, :binary_id, primary_key: true)

      add(:message_id, references(:chat_messages, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:version_number, :integer, null: false)
      add(:content, :text, null: false)
      add(:edited_at, :utc_datetime_usec, null: false)

      add(
        :edited_by_participant_id,
        references(:chat_participants, type: :binary_id, on_delete: :nilify_all),
        null: true
      )

      # Denormalized author snapshot — see ADR 0038. Survives later
      # participant deletion so the version history's "edited by ..." label
      # never goes blank in the UI.
      add(:edited_by_display_name, :string, null: false)

      add(:inserted_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end

    create(unique_index(:chat_message_versions, [:message_id, :version_number]))
    create(index(:chat_message_versions, [:message_id]))

    # Flush before the backfill: `create table` is queued by Ecto.Migration and
    # only sent to Postgres on flush/end-of-block, but `backfill_v1_rows/0`
    # calls `Repo.insert_all` directly, which bypasses the queue. Without this
    # flush, the INSERT runs before the CREATE TABLE and fails with
    # "relation \"chat_message_versions\" does not exist" on any DB with
    # existing chat_messages rows to backfill.
    flush()

    # ── 3. Backfill v1 rows for every existing chat_messages row ─────────────
    backfill_v1_rows()
  end

  def down do
    drop(table(:chat_message_versions))

    drop(
      index(:chat_messages, [:corrects_message_id],
        name: :chat_messages_corrects_message_id_partial_index
      )
    )

    drop(constraint(:chat_messages, :frozen_both_or_neither))

    alter table(:chat_messages) do
      remove(:corrects_message_id)
      remove(:frozen_by_participant_id)
      remove(:frozen_at)
    end
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Backfill helpers
  # ──────────────────────────────────────────────────────────────────────────

  @batch_size 1_000

  defp backfill_v1_rows do
    repo = repo()
    do_backfill(repo, _last_id = nil)
  end

  defp do_backfill(repo, last_id) do
    # Page through messages by `id` (UUIDv7 is sortable, ascending = insertion
    # order). On each page, build the version rows and `INSERT ... ON CONFLICT
    # DO NOTHING` so re-running the migration after a partial failure is safe.
    where_clause =
      if is_nil(last_id), do: "", else: "WHERE m.id > $1"

    rows_query = """
    SELECT m.id, m.content, m.inserted_at,
           m.participant_id, m.author_display_name
    FROM chat_messages m
    #{where_clause}
    ORDER BY m.id ASC
    LIMIT #{@batch_size}
    """

    params = if is_nil(last_id), do: [], else: [last_id]
    %{rows: rows} = repo.query!(rows_query, params)

    case rows do
      [] ->
        :ok

      _ ->
        version_rows = Enum.map(rows, &to_version_row/1)
        insert_versions(repo, version_rows)

        [last | _] = Enum.reverse(rows)
        [next_last_id | _] = last
        do_backfill(repo, next_last_id)
    end
  end

  defp to_version_row([message_id, content, inserted_at, participant_id, display_name]) do
    %{
      id: Ecto.UUID.bingenerate(),
      message_id: message_id,
      version_number: 1,
      content: content || "",
      edited_at: inserted_at,
      edited_by_participant_id: participant_id,
      # Display name may legitimately be nil on very old messages — fall
      # back to a clear placeholder rather than letting the NOT NULL trip.
      edited_by_display_name: display_name || "(unknown)",
      inserted_at: DateTime.utc_now()
    }
  end

  defp insert_versions(repo, rows) do
    # ON CONFLICT DO NOTHING on the (message_id, version_number) unique
    # constraint — re-running the migration after a partial failure won't
    # duplicate v1 rows.
    repo.insert_all(
      "chat_message_versions",
      rows,
      on_conflict: :nothing,
      conflict_target: [:message_id, :version_number]
    )
  end
end
