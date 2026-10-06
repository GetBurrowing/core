defmodule Platform.Chat.Messages.Edit do
  @moduledoc """
  In-process edit application for chat messages, per the editable-
  messages cross-phase contract (docs/contracts/editable-messages-
  contract.md). Shared by:

    * `PlatformWeb.MessageController.update/2` — the HTTP API surface
      (Task 3). Translates `apply_edit/3`'s return shape to status
      codes + JSON envelopes.
    * `PlatformWeb.ChatLive` (task 019e0f29 Stage 5) — the LiveView
      inline editor. Translates the same return shape to optimistic
      stream updates + flash toasts.

  Keeping the edit logic in one place means future contract changes
  (e.g. additional broadcast metadata, freeze-check refinements,
  edit-history schema tweaks) land once and both call sites stay
  in sync.

  ## What `apply_edit/3` does
  1. **Freeze check** (Section F.2 Policy 2). Returns
     `{:error, :frozen, freezing_action}` if `message.frozen_at` is set;
     the controller maps this to 409, the LV maps it to a toast.
  2. **Transactional update + version row append**. The
     `chat_messages.content` + `edited_at` update and the
     `chat_message_versions` insert run in one `Repo.transaction` so a
     mid-write crash never leaves the message and its history out of
     sync.
  3. **Broadcast** (Section c). `{:message_edited, payload}` to the
     space's PubSub topic with the new version, the previous content,
     the editor's participant id, and the word-run diff
     (`removed_substrings`) per Section C.3.
  4. **Telemetry**. `[:platform, :chat, :message_edited]` so existing
     telemetry handlers (presence, analytics) see edits.

  Idempotency, validation, and author-only authz are NOT enforced here
  — they belong to the calling layer (HTTP-level for the controller,
  socket-assign-level for the LV). This module assumes its inputs are
  already authorized.
  """

  alias Platform.Chat.{Message, MessageVersions, Participant, PubSub}
  alias Platform.Repo

  @type freezing_action :: %{
          participant_id: binary() | nil,
          participant_display_name: String.t() | nil,
          frozen_at: DateTime.t() | nil
        }

  @type apply_result ::
          {:ok, Message.t()}
          | {:error, :frozen, freezing_action()}
          | {:error, Ecto.Changeset.t()}

  @doc """
  Apply an edit to `message`, attributed to `participant`, with the
  given new `content`. See module doc for the full contract.

  Callers are responsible for:
    * checking the requesting actor is the message author
      (`message.participant_id == participant.id`)
    * deciding whether to short-circuit on idempotent edits
      (`content == message.content`)
    * surfacing the removal-warning UI before calling this function
      when the edit shortens content (Section F.4 Policy 4)
  """
  @spec apply_edit(Message.t(), Participant.t(), String.t()) :: apply_result()
  def apply_edit(%Message{} = message, %Participant{} = participant, content)
      when is_binary(content) do
    if message.frozen_at do
      {:error, :frozen, freezing_action(message)}
    else
      do_apply(message, participant, content)
    end
  end

  defp do_apply(message, participant, content) do
    now = DateTime.utc_now()
    previous_content = message.content || ""

    txn_result =
      Repo.transaction(fn ->
        with {:ok, updated} <-
               message |> Message.changeset(%{content: content, edited_at: now}) |> Repo.update(),
             {:ok, version} <-
               MessageVersions.record_edit(updated.id, %{
                 content: content,
                 edited_at: now,
                 edited_by_participant_id: participant.id,
                 edited_by_display_name: participant.display_name || "(unknown)"
               }) do
          {updated, version}
        else
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case txn_result do
      {:ok, {updated, version}} ->
        broadcast_edit(updated, previous_content, content, version, participant)
        emit_telemetry(updated)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp broadcast_edit(updated, previous_content, new_content, version, participant) do
    payload = %{
      message: updated,
      previous_content: previous_content,
      version_number: version.version_number,
      edited_by_participant_id: participant.id,
      removed_substrings: compute_removed_substrings(previous_content, new_content)
    }

    # Space-wide broadcast — kept for LiveView user clients (the chat panel
    # halts the event for agent-impersonating sockets at messages_hooks.ex,
    # but user UIs use this to refresh the `(edited)` affordance).
    PubSub.broadcast(updated.space_id, {:message_edited, payload})

    # Policy 1 narrow scoping (editable-messages contract Section f, task
    # 019e1e83): in addition to the space-wide broadcast above, fan out the
    # same event to per-participant runtime topics for the agents that are
    # entitled to it (mentioned in the body OR assignee of the task linked
    # to this space via chat_spaces.metadata.task_id). LiveView user sockets
    # continue to subscribe to the space topic and are unaffected.
    #
    # Note: as of this commit there is no agent-side consumer subscribing to
    # `chat:participant:<id>` for `{:message_edited}` — the broadcast is a
    # silent no-op until one is added. That deferral is deliberate (see
    # audit/2026-05-13-policy-1-broadcaster/03-stage3-deferred.md): shipping
    # the producer half locks in the privacy-by-construction shape so any
    # future consumer just subscribes to the right topic.
    case Platform.Chat.eligible_edit_recipients_for_message(updated) do
      [] ->
        :ok

      recipient_ids when is_list(recipient_ids) ->
        Enum.each(recipient_ids, fn participant_id ->
          Phoenix.PubSub.broadcast(
            Platform.PubSub,
            "chat:participant:" <> participant_id,
            {:message_edited, payload}
          )
        end)
    end
  end

  defp emit_telemetry(message) do
    :telemetry.execute(
      [:platform, :chat, :message_edited],
      %{system_time: System.system_time()},
      %{message_id: message.id, space_id: message.space_id}
    )
  end

  @doc """
  Who froze `message` and when: `participant_id`, `frozen_at`, and the
  freezing participant's `participant_display_name` when it resolves. Also
  `Platform.Chat.edit_message/2`'s refusal payload.
  """
  @spec freezing_action(Message.t()) :: freezing_action()
  def freezing_action(message) do
    base = %{
      participant_id: message.frozen_by_participant_id,
      frozen_at: message.frozen_at
    }

    case message.frozen_by_participant_id &&
           Repo.get(Participant, message.frozen_by_participant_id) do
      %Participant{display_name: name} when is_binary(name) and name != "" ->
        Map.put(base, :participant_display_name, name)

      _ ->
        base
    end
  end

  # Section C.3 — detect shortened / removed-substring edits so in-context
  # agents can react to retractions. Word-tokenize previous + new content;
  # collect runs of consecutive words that appear in previous but not in
  # new. Detection only — false positives are acceptable, false negatives
  # are not. Whitespace defines word boundaries.
  @doc false
  @spec compute_removed_substrings(String.t(), String.t()) :: [String.t()]
  def compute_removed_substrings(previous, new) do
    prev_words = String.split(previous, ~r/\s+/, trim: true)
    new_set = MapSet.new(String.split(new, ~r/\s+/, trim: true))

    {final_run, runs} =
      Enum.reduce(prev_words, {[], []}, fn word, {current_run, acc} ->
        if MapSet.member?(new_set, word) do
          {[], maybe_append_run(current_run, acc)}
        else
          {[word | current_run], acc}
        end
      end)

    final_run |> maybe_append_run(runs) |> Enum.reverse()
  end

  defp maybe_append_run([], acc), do: acc
  defp maybe_append_run(run, acc), do: [run |> Enum.reverse() |> Enum.join(" ") | acc]
end
