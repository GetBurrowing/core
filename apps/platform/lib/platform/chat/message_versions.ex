defmodule Platform.Chat.MessageVersions do
  @moduledoc """
  Repo helpers for the editable-messages edit-history layer (task 019df568).

  Scope is intentionally narrow — Task 2 only ships the data layer. The
  business rules about *when* to record a version or *when* to freeze a
  message live in Task 3 (the PATCH controller) per
  `docs/contracts/editable-messages-contract.md`.

  Public surface:

    * `record_v1!/1` — insert the initial version row (v1) for a newly-
      created message. Called from the message creation path in Task 3
      inside the same Repo.transaction as the message insert.

    * `record_edit!/2` — append a new version row for an existing message,
      auto-incrementing `version_number`. Called by Task 3's PATCH handler.

    * `list_versions/1` — fetch all versions for a message, newest-first.
      Backing for `GET /api/messages/:id/versions`.

    * `count_versions/1` — count versions for a message. Cheaper than
      `list_versions/1 |> Enum.count/1` when only the count is needed (UI
      reads this to decide whether to render the "(edited)" affix).

    * `freeze!/2` — set `frozen_at` + `frozen_by_participant_id` on a
      message. Idempotent: a no-op on a message that is already frozen.
      Called by Task 3's freeze hooks.
  """

  import Ecto.Query

  alias Platform.Chat.Message
  alias Platform.Chat.MessageVersion
  alias Platform.Repo

  # ──────────────────────────────────────────────────────────────────────────
  # Version recording
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Insert version 1 (the original message body) for a newly-created message.

  Raises on changeset error — v1 insertion is a precondition for the edit
  history layer to be consistent; failure here is a bug, not a recoverable
  error path.

  Arguments are taken from the `Message` struct rather than a separate map
  so callers don't need to remember which fields to copy. The author
  snapshot (`author_display_name`, `participant_id`) is reused as the
  initial edit-history snapshot.
  """
  @spec record_v1!(Message.t()) :: MessageVersion.t()
  def record_v1!(%Message{} = message) do
    %MessageVersion{}
    |> MessageVersion.changeset(%{
      message_id: message.id,
      version_number: 1,
      content: message.content || "",
      edited_at: message.inserted_at || DateTime.utc_now(),
      edited_by_participant_id: message.participant_id,
      edited_by_display_name: message.author_display_name || "(unknown)"
    })
    |> Repo.insert!()
  end

  @doc """
  Append a new version row to a message's history.

  `attrs` requires `:content`, `:edited_by_participant_id`, and
  `:edited_by_display_name`. Optional `:edited_at` defaults to now.

  `version_number` is computed server-side from the existing max — callers
  do NOT pass it. Wraps insertion in a transaction so the
  max-then-insert is atomic against concurrent edits on the same message
  (the unique index on `(message_id, version_number)` is the ultimate
  safety net if two transactions race).

  Returns `{:ok, %MessageVersion{}}` on success or `{:error, changeset}` if
  the insert fails validation or trips the unique constraint.
  """
  @spec record_edit(binary(), map()) ::
          {:ok, MessageVersion.t()} | {:error, Ecto.Changeset.t()}
  def record_edit(message_id, attrs) when is_binary(message_id) and is_map(attrs) do
    Repo.transaction(fn ->
      next = next_version_number(message_id)

      attrs
      |> Map.put(:message_id, message_id)
      |> Map.put(:version_number, next)
      |> Map.put_new(:edited_at, DateTime.utc_now())
      |> then(&MessageVersion.changeset(%MessageVersion{}, &1))
      |> Repo.insert()
      |> case do
        {:ok, version} -> version
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Version listing / counting
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Fetch all versions for `message_id`, newest-first.

  Returns `[]` if the message has no versions (which shouldn't happen if
  the backfill ran, but the empty-list path is the safe default).
  """
  @spec list_versions(binary()) :: [MessageVersion.t()]
  def list_versions(message_id) when is_binary(message_id) do
    MessageVersion
    |> where([v], v.message_id == ^message_id)
    |> order_by([v], desc: v.version_number)
    |> Repo.all()
  end

  @doc """
  Count versions for `message_id`. UI reads this to decide whether to
  render the "(edited)" affix (`count > 1`).
  """
  @spec count_versions(binary()) :: non_neg_integer()
  def count_versions(message_id) when is_binary(message_id) do
    MessageVersion
    |> where([v], v.message_id == ^message_id)
    |> select(count())
    |> Repo.one()
  end

  @doc """
  `count_versions/1` for many messages in ONE query: `%{message_id => count}`.
  Messages with no versions are absent from the map (read them as 0). The
  chat window loaders use this so a 50-message window costs one COUNT, not
  fifty (task 01a17bf4 stage 2).
  """
  @spec count_versions_for([binary()]) :: %{binary() => non_neg_integer()}
  def count_versions_for([]), do: %{}

  def count_versions_for(message_ids) when is_list(message_ids) do
    MessageVersion
    |> where([v], v.message_id in ^message_ids)
    |> group_by([v], v.message_id)
    |> select([v], {v.message_id, count()})
    |> Repo.all()
    |> Map.new()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Freeze
  # ──────────────────────────────────────────────────────────────────────────

  @doc """
  Mark a message as frozen. Subsequent edit attempts return 409 per the
  contract.

  Idempotent: a no-op on a message that is already frozen — preserves the
  *original* `frozen_at` and `frozen_by_participant_id` (don't overwrite
  with later freezing events; the first action that froze it is the
  audit-relevant one).

  Returns `{:ok, %Message{}}` (frozen or already-frozen) or
  `{:error, changeset}` if the freeze fails validation.
  """
  @spec freeze(Message.t(), binary()) ::
          {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def freeze(%Message{frozen_at: %DateTime{}} = message, _participant_id), do: {:ok, message}

  def freeze(%Message{} = message, participant_id) when is_binary(participant_id) do
    message
    |> Message.freeze_changeset(%{
      frozen_at: DateTime.utc_now(),
      frozen_by_participant_id: participant_id
    })
    |> Repo.update()
  end

  # ──────────────────────────────────────────────────────────────────────────
  # Private
  # ──────────────────────────────────────────────────────────────────────────

  defp next_version_number(message_id) do
    max =
      MessageVersion
      |> where([v], v.message_id == ^message_id)
      |> select([v], max(v.version_number))
      |> Repo.one()

    (max || 0) + 1
  end
end
