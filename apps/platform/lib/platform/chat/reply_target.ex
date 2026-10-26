defmodule Platform.Chat.ReplyTarget do
  @moduledoc """
  Validates the message a member's MAIN-LOG reply answers (task 01a174f5
  stage 1).

  A main-log reply is an ordinary top-level message (`thread_id` nil) whose
  metadata carries `"reply_to_message_id"`, the same key built-in and
  federated agents already write, so one reader quotes all of them. It is
  posted through `Platform.Chat.post_message/2` with a `:reply_to_message_id`
  attr; this module decides whether that attr is kept.

  A target is kept only when every one of these holds:

    1. every `Platform.Chat.ReplyContext.check/3` check: canonical UUID,
       exists, same space, not deleted, inside the author's history grant;
    2. it is TOP-LEVEL (`thread_id` nil, `not_top_level`): a reply to a
       thread message belongs in that thread, which already has its own
       affordance;
    3. it is AGENT-AUTHORED (`not_agent`): the attention router routes a
       reply to the agent that wrote the target, and nothing else.

  An invalid target is DROPPED, never fatal: the member's message still
  posts, as a plain top-level message.
  """

  alias Platform.Chat
  alias Platform.Chat.{Message, Participant, ReplyContext}

  @doc """
  `{:ok, message}` when `target_id` is a valid main-log reply target in
  `space_id` for `author` (a `%Participant{}` or its id), else
  `{:drop, reason}`.
  """
  @spec validate(term(), binary(), Participant.t() | binary() | nil) ::
          {:ok, Message.t()} | {:drop, String.t()}
  def validate(target_id, space_id, author) do
    with {:ok, %Message{} = target} <- ReplyContext.check(target_id, space_id, author_id(author)),
         true <- is_nil(target.thread_id) || {:drop, "not_top_level"},
         true <- agent_authored?(target) || {:drop, "not_agent"} do
      {:ok, target}
    end
  end

  @doc """
  Apply a `:reply_to_message_id` attr to
  `Chat.post_message/2` attrs: removed from the attrs either way, and stored
  as `metadata["reply_to_message_id"]` only when the message is top-level and
  `validate/3` keeps it.
  """
  @spec apply_to_attrs(map()) :: map()
  def apply_to_attrs(attrs) when is_map(attrs) do
    case Map.pop(attrs, :reply_to_message_id) do
      {nil, attrs} -> attrs
      {target_id, attrs} -> maybe_put_target(attrs, target_id)
    end
  end

  defp maybe_put_target(attrs, target_id) do
    space_id = Map.get(attrs, :space_id)

    with true <- is_nil(Map.get(attrs, :thread_id)),
         true <- is_binary(space_id),
         {:ok, _target} <- validate(target_id, space_id, Map.get(attrs, :participant_id)) do
      put_metadata(attrs, "reply_to_message_id", target_id)
    else
      _ -> attrs
    end
  end

  # `post_message/2` attrs are atom-keyed (`put_author_snapshot/3` adds atom
  # keys, so a string-keyed map cannot be cast anyway).
  defp put_metadata(attrs, key, value) do
    metadata = Map.get(attrs, :metadata) || %{}
    Map.put(attrs, :metadata, Map.put(metadata, key, value))
  end

  defp agent_authored?(%Message{participant_id: participant_id}) do
    match?(%Participant{participant_type: "agent"}, Chat.get_participant(participant_id))
  end

  defp author_id(%Participant{id: id}), do: id
  defp author_id(id), do: id
end
