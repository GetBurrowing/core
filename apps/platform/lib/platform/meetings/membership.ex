defmodule Platform.Meetings.Membership do
  @moduledoc """
  Canonical hook for adding a user to the chat space bound to a meeting.

  ## Why this exists

  Stages 1-3 of task `019e2d1a` removed the *wrong* participant-add
  triggers — canvas creation, chat panel mount — that were quietly
  inserting users into a meeting's bound chat space as a side-effect of
  unrelated UI actions. Stage 4 installs the *right* trigger: a user
  enters the meeting's chat space exactly when they join the LiveKit
  room, and only then.

  `ensure_chat_space_participant/3` is the **only** path that should
  add a user to a meeting's bound chat space. Anything else (canvas
  creation, panel mount, composer flush, sidebar hover) should treat
  membership as a read-only precondition and either render in
  read-only mode or prompt the user to join.

  ## Idempotency

  The function is a find-or-insert by `(space_id, user_id)`. Two calls
  for the same `(space_id, user_id)` produce a single row in
  `chat_participants` and both return `{:ok, %Participant{}}`. This
  matters because the join lifecycle in `MeetingHooks` fires every
  time the user clicks "Join" or the auto-join path runs on mount —
  we don't want a per-join row, just a stable membership record.

  ## Scope (stage 4)

  This module handles the **local-side** insert: the participant whose
  LiveView is mounted is the participant who gets added. The
  remote-participant mirror — where LiveKit's
  `RoomEvent.ParticipantConnected` would fire for OTHER users in the
  same room and trigger a server-side participant add on their behalf
  — is **DEFERRED to a follow-up** per the approved v2 plan. The
  reasoning: each user adds themselves on their own join, which is
  sufficient for the end-to-end test where every participant has a
  LiveView session attached. A remote mirror would only matter for
  server-driven joins (e.g. agents pulled into a room by another
  user's action), which is not in scope here.
  """

  alias Platform.Chat
  alias Platform.Chat.Participant

  require Logger

  @doc """
  Idempotently ensure a participant row exists for `user_id` in `space_id`.

  Returns `{:ok, %Participant{}}` on first insert AND on duplicate (i.e.
  when the row already existed). Returns `{:error, changeset}` only when
  the underlying insert fails for a reason other than "row already
  there" — surface it to the caller but never let it block the LiveKit
  join lifecycle.

  `display_name` is stored on the row and shown in the participant
  rail / video tiles. Callers should pass the same name they hand to
  LiveKit (the participant's `display_name` from chat, or a fallback
  like the user's email/`"User"`) so the chat roster and the LiveKit
  roster stay in sync.
  """
  @spec ensure_chat_space_participant(binary(), binary(), String.t() | nil) ::
          {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def ensure_chat_space_participant(space_id, user_id, display_name)
      when is_binary(space_id) and is_binary(user_id) do
    case find_user_participant(space_id, user_id) do
      %Participant{} = existing ->
        {:ok, existing}

      nil ->
        case Chat.add_participant(space_id, %{
               participant_type: "user",
               participant_id: user_id,
               display_name: display_name || "User",
               joined_at: DateTime.utc_now()
             }) do
          {:ok, %Participant{} = p} ->
            {:ok, p}

          {:error, changeset} ->
            # Race window: another LV process may have inserted the
            # row between our lookup and our insert. Re-lookup; if
            # present, treat as idempotent success.
            case find_user_participant(space_id, user_id) do
              %Participant{} = winner ->
                {:ok, winner}

              nil ->
                Logger.warning(
                  "[Meetings.Membership] ensure_chat_space_participant failed: " <>
                    inspect(changeset.errors)
                )

                {:error, changeset}
            end
        end
    end
  end

  defp find_user_participant(space_id, user_id) do
    space_id
    |> Chat.list_participants(participant_type: "user")
    |> Enum.find(fn p -> p.participant_id == user_id end)
  end
end
