defmodule Platform.Chat.ReplyContext do
  @moduledoc """
  Normalises the two optional reply annotations a federated runtime may send
  on a `reply` or `reply_with_media` frame (task 01a0d8de stage 2):

    * `in_reply_to_message_id` — the id of the message the reply answers;
    * `context` — one agent-written line saying what the reply answers, for a
      person who arrives hours later.

  `normalize/3` returns `{metadata_additions, dropped}`. The additions are
  merged into the posted message's metadata under `"reply_to_message_id"` (the
  key built-in agents already write, `Platform.Chat.AgentResponder`, so one UI
  reader serves both agent kinds) and `"reply_context"`. The wire names stay
  `in_reply_to_message_id` and `context`.

  An invalid field is DROPPED with a reason, never fatal: rejecting the frame
  would lose the agent's actual answer over an optional annotation. The
  caller reports `dropped` in its ack so the runtime can learn the field was
  refused. A key that is absent, or present as JSON null, is treated as not
  supplied and is neither stored nor reported.

  ## `in_reply_to_message_id`

  Kept only when every one of these holds, checked in this order, and the
  first failure names the reason:

    1. it is a canonical UUID string (`invalid_uuid`);
    2. a message row with that id exists (`not_found`);
    3. that row is in the space the reply is posted to (`other_space`);
    4. it is not soft-deleted (`deleted`);
    5. it is inside the replying agent participant's history grant, i.e.
       `inserted_at >= history_visible_from` when that column is non-NULL,
       the same rule `Platform.Chat.list_messages/2` applies with
       `:as_participant` (`outside_grant`).

  The space check comes before the deleted check so a reply can never learn
  whether a message in a different space was deleted.

  ## `context`

  Binary only (anything else is dropped as `not_string`). Invalid UTF-8 is
  replaced, every whitespace run including newlines collapses to one space,
  remaining control characters are removed, the result is trimmed and capped
  at 200 graphemes (the last one an ellipsis when it was cut), and finally
  passed through `Platform.Security.ExternalContent.escape_mentions/1`. If
  nothing is left it is dropped as `empty`.

  ## Why the mention escape, when metadata is never scanned

  Every consumer that acts on a mention token reads the message CONTENT and
  never its metadata: `Chat.reinvite_and_pin_mentioned/1`, the attention
  router's mention check, and the here-mention check. An agent author also
  fails the summon authorization gate added by task 01a0ac64. So a mention
  token placed only in `reply_context` adds no participant today, escaped or
  not. The escape protects the day this text is copied into content, a push
  body or a digest: once escaped, the at-sign is the fullwidth form, which
  reads the same to a person and matches nothing in the parser. The tests pin
  the escape itself, not only the absence of a participant.
  """

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias Platform.Security.ExternalContent

  @max_context_graphemes 200
  @ellipsis "…"

  @type dropped :: %{field: String.t(), reason: String.t()}

  @doc """
  Normalise the optional reply annotations in `params` for a reply posted to
  `space_id` by the agent participant `agent_participant_id`.
  """
  @spec normalize(map(), binary(), binary() | nil) :: {map(), [dropped()]}
  def normalize(params, space_id, agent_participant_id) when is_map(params) do
    {additions, dropped} =
      {%{}, []}
      |> put_reply_to(Map.get(params, "in_reply_to_message_id"), space_id, agent_participant_id)
      |> put_context(Map.get(params, "context"))

    {additions, Enum.reverse(dropped)}
  end

  defp put_reply_to(acc, nil, _space_id, _agent_participant_id), do: acc

  defp put_reply_to({additions, dropped}, id, space_id, agent_participant_id) do
    case check(id, space_id, agent_participant_id) do
      {:ok, _message} ->
        {Map.put(additions, "reply_to_message_id", id), dropped}

      {:drop, reason} ->
        {additions, [%{field: "in_reply_to_message_id", reason: reason} | dropped]}
    end
  end

  @doc """
  The `in_reply_to_message_id` checks above, in that order, for a reply posted
  to `space_id` by `participant_id`. `{:ok, message}` when every one holds,
  else `{:drop, reason}` naming the first failure. Shared with
  `Platform.Chat.ReplyTarget` so there is one validator, not two.
  """
  @spec check(term(), binary(), binary() | nil) :: {:ok, Message.t()} | {:drop, String.t()}
  def check(id, space_id, participant_id) do
    with true <- Platform.UUID.valid?(id) || {:drop, "invalid_uuid"},
         %Message{} = msg <- Chat.get_message(id) || {:drop, "not_found"},
         true <- msg.space_id == space_id || {:drop, "other_space"},
         true <- is_nil(msg.deleted_at) || {:drop, "deleted"},
         true <- inside_grant?(msg, participant_id) || {:drop, "outside_grant"} do
      {:ok, msg}
    end
  end

  @doc """
  The thread a reply should be posted INTO, given the `metadata_additions`
  `normalize/3` returned: the accepted `reply_to_message_id` target's
  `thread_id`, or `nil` (top-level) when there is no accepted target or the
  target is itself top-level (task 01a174f5 stage 1).
  """
  @spec placement_thread_id(map()) :: binary() | nil
  def placement_thread_id(%{"reply_to_message_id" => id}) when is_binary(id) do
    case Chat.get_message(id) do
      %Message{thread_id: thread_id} -> thread_id
      _ -> nil
    end
  end

  def placement_thread_id(_additions), do: nil

  @doc """
  `text` as a one-line preview, normalised and capped exactly like `context`
  (200 graphemes, ellipsis when cut, mentions escaped). `nil` becomes `""`.
  """
  @spec excerpt(String.t() | nil) :: String.t()
  def excerpt(nil), do: ""
  def excerpt(text) when is_binary(text), do: sanitize_context(text)

  defp inside_grant?(%Message{inserted_at: inserted_at}, agent_participant_id) do
    case participant(agent_participant_id) do
      %Participant{history_visible_from: %DateTime{} = from} ->
        DateTime.compare(inserted_at, from) != :lt

      _ ->
        true
    end
  end

  defp participant(id) do
    if Platform.UUID.valid?(id), do: Chat.get_participant(id), else: nil
  end

  defp put_context(acc, nil), do: acc

  defp put_context({additions, dropped}, context) when is_binary(context) do
    case sanitize_context(context) do
      "" -> {additions, [%{field: "context", reason: "empty"} | dropped]}
      clean -> {Map.put(additions, "reply_context", clean), dropped}
    end
  end

  defp put_context({additions, dropped}, _context) do
    {additions, [%{field: "context", reason: "not_string"} | dropped]}
  end

  @doc false
  @spec sanitize_context(String.t()) :: String.t()
  def sanitize_context(context) when is_binary(context) do
    context
    |> String.replace_invalid()
    |> String.replace(~r/\s+/u, " ")
    |> String.replace(~r/\p{Cc}/u, "")
    |> String.trim()
    |> cap()
    |> ExternalContent.escape_mentions()
  end

  defp cap(text) do
    if String.length(text) > @max_context_graphemes do
      text
      |> String.slice(0, @max_context_graphemes - 1)
      |> String.trim_trailing()
      |> Kernel.<>(@ellipsis)
    else
      text
    end
  end
end
