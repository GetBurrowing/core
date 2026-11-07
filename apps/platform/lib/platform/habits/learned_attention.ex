defmodule Platform.Habits.LearnedAttention do
  @moduledoc """
  The first consumer of learned defaults, server side: `chat.message_attention`
  (`0061-learned-defaults.md` §§ 4-5, task 01a1b6a1 stage 3).

    * `after_message_posted/1` runs on every posted message, after the post
      committed. It captures the principals the message @mentions
      (`chat.mention`, `chosen` at rung `none`) and, on the `act` rung, asks
      the learned target to look at the new message on the author's behalf.
    * `undo/3` and `stop/3` are the notice's two controls.

  ## Act

  Only for a top-level message a USER posted in a channel or group space that
  is not archived, and only when `Platform.Habits.suggest/3` returns `act`.
  `suggest/3` is the one gate: it refuses an opted-out user, a stopped
  pattern, too few accepted pre-fills and a target that is not reversible
  (an agent; `Platform.Habits.Actions.reversible?/2`). This module adds the
  space rules (never in a DM, never in an archived space) and nothing that
  would shadow those checks. The ask goes through
  `Platform.Chat.add_message_attention/4` as the author, and the notice is the
  `accepted` signal at rung `act` with `source_message_id`, so it renders
  from data (`Platform.Habits.act_notices/2`) and survives a reload.

  Nothing here may fail the post: see `Platform.Habits.Capture`.
  """

  alias Platform.Chat
  alias Platform.Chat.{Message, Space}
  alias Platform.Chat.AttentionRouter
  alias Platform.Habits
  alias Platform.Habits.Capture

  @action "chat.message_attention"

  @doc "The action key this consumer learns."
  @spec action() :: String.t()
  def action, do: @action

  @doc """
  Post-commit hook for a posted message: mention capture, then act. Always
  returns `:ok`.
  """
  @spec after_message_posted(Message.t()) :: :ok
  def after_message_posted(%Message{author_participant_type: "user", author_user_id: uid} = msg)
      when is_binary(uid) do
    Capture.safely("chat.mention", fn -> capture_mentions(msg, uid) end)
    Capture.safely(@action, fn -> maybe_act(msg, uid) end)
  end

  def after_message_posted(_msg), do: :ok

  # ── Mention capture ─────────────────────────────────────────────────────

  defp capture_mentions(%Message{content: content} = msg, uid) when is_binary(content) do
    if String.contains?(content, "@") do
      msg.space_id
      |> Chat.list_participants()
      |> Enum.reject(&(&1.id == msg.participant_id or &1.participant_id == uid))
      # Keyword matches (`attention_config["keywords"]`) are the recipient's
      # setting, not the author's choice, so they are not captured.
      |> Enum.filter(&AttentionRouter.mentioned?(%{&1 | attention_config: %{}}, msg))
      |> Enum.uniq_by(& &1.participant_id)
      |> Enum.each(fn p ->
        Capture.chosen(%{
          actor_user_id: uid,
          space_id: msg.space_id,
          action: "chat.mention",
          target_type: p.participant_type,
          target_id: p.participant_id,
          source_message_id: msg.id
        })
      end)
    end
  end

  defp capture_mentions(_msg, _uid), do: :ok

  # ── Act ─────────────────────────────────────────────────────────────────

  defp maybe_act(%Message{thread_id: nil, space_id: space_id} = msg, uid)
       when is_binary(space_id) do
    with true <- Habits.act_possible?(uid, space_id, @action),
         %Space{} = space <- Chat.get_space(space_id),
         true <- actable_space?(space),
         %{act: %{target_id: target_id} = target} <- Habits.suggest(uid, space_id, @action),
         {:ok, %{added: [_ | _]}} <-
           Chat.add_message_attention({:user, uid}, space_id, msg.id, [target_id]) do
      Capture.record(%{
        actor_user_id: uid,
        space_id: space_id,
        action: @action,
        target_type: target.target_type,
        target_id: target_id,
        outcome: "accepted",
        rung: "act",
        source_message_id: msg.id
      })

      notice_changed(space_id, msg.id)
    end
  end

  defp maybe_act(_msg, _uid), do: :ok

  defp actable_space?(%Space{kind: "dm"}), do: false
  defp actable_space?(%Space{archived_at: %DateTime{}}), do: false
  defp actable_space?(%Space{}), do: true

  # ── The notice's controls ───────────────────────────────────────────────

  @doc """
  Undo the automatic ask on `message_id`: removes the attention row and the
  Inbox row (`Platform.Chat.remove_message_attention/4`) and records
  `overridden` at rung `act`, which demotes the pattern to prefill and resets
  its accepted count.

  Returns `:ok`, or `{:error, :not_found}` when `user_id`'s habits took no
  live action on that message in `space_id`, or the removal's error.
  """
  @spec undo(binary(), binary(), binary()) :: :ok | {:error, term()}
  def undo(user_id, space_id, message_id) do
    with {:ok, %{undone?: false} = notice} <- notice(user_id, space_id, message_id),
         {:ok, _row} <-
           Chat.remove_message_attention({:user, user_id}, space_id, message_id, notice.target_id) do
      Capture.record(%{
        actor_user_id: user_id,
        space_id: space_id,
        action: notice.action,
        target_type: notice.target_type,
        target_id: notice.target_id,
        outcome: "overridden",
        rung: "act",
        source_message_id: message_id
      })

      notice_changed(space_id, message_id)
    else
      {:ok, %{undone?: true}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  @doc """
  Stop the pattern behind the automatic ask on `message_id`
  (`Platform.Habits.stop/4`): it drops to rank for this space and never
  pre-fills or acts again until forgotten. The ask itself stays.

  Returns `{:ok, pattern}` or `{:error, reason}`.
  """
  @spec stop(binary(), binary(), binary()) :: {:ok, term()} | {:error, term()}
  def stop(user_id, space_id, message_id) do
    with {:ok, notice} <- notice(user_id, space_id, message_id),
         {:ok, pattern} <-
           Habits.stop(user_id, space_id, notice.action, %{
             target_type: notice.target_type,
             target_id: notice.target_id
           }) do
      notice_changed(space_id, message_id)
      {:ok, pattern}
    end
  end

  # The notice renders from the signal rows (stage 4), which are written
  # AFTER the attention write broadcast `{:message_attention_changed, msg}`.
  # A viewer that re-rendered on that broadcast may have read the rows before
  # they existed, so the same message is broadcast again once they do. The
  # topic and payload are the attention writer's own; no new topic.
  defp notice_changed(space_id, message_id) do
    case Chat.get_message(message_id) do
      %Message{space_id: ^space_id} = message ->
        Platform.Chat.PubSub.broadcast(space_id, {:message_attention_changed, message})

      _ ->
        :ok
    end
  end

  defp notice(user_id, space_id, message_id) do
    case Habits.act_notices(user_id, [message_id]) do
      %{^message_id => %{space_id: ^space_id} = notice} -> {:ok, notice}
      _ -> {:error, :not_found}
    end
  end
end
