defmodule PlatformWeb.ChatLive.QuotedMessage do
  @moduledoc """
  The ONE reader for "the message this one quotes" in the chat view: what the
  viewer may see of a `metadata["reply_to_message_id"]` target. Moved out of
  `PlatformWeb.ChatLive.MessageContextHooks` (task 01a174f5 stage 3) so the
  'Answering' panel, its jump and the main-log reply quote
  (`PlatformWeb.ChatLive.ReplyQuoteHooks`) apply the same rules, not copies.

  A message is VISIBLE to the viewer when it is inside their
  `external_scope`, in the ACTIVE space (a hand-built event naming another
  space's message is refused), not before their `history_visible_from`, and
  not deleted.

  `resolve/2` classifies a target into one of three states:

    * `%{status: :visible, message_id, author, author_participant_id,
      agent_slot, at, preview}` — `author` from
      `PresenceHooks.sender_name/2` (the message-header path, so the mask
      labels apply); `agent_slot` is the quoted author's palette slot when the
      author is an agent of this space, else nil (a person);
    * `%{status: :deleted}` — a target the viewer could otherwise see, now
      soft-deleted. Nothing of it (author, content, time) is returned;
    * `%{status: :no_access}` — anything else: missing, another space,
      outside the scope or before the grant. A deleted target outside the
      viewer's bounds is `:no_access` too, so deletion never leaks.
  """

  alias Platform.Chat
  alias Platform.Chat.Message
  alias Platform.Chat.Participant
  alias PlatformWeb.ChatLive.PresenceHooks

  @preview_chars 280

  @type state ::
          %{
            status: :visible,
            message_id: binary(),
            author: String.t(),
            author_participant_id: binary() | nil,
            agent_slot: String.t() | nil,
            at: DateTime.t() | nil,
            preview: String.t()
          }
          | %{status: :deleted}
          | %{status: :no_access}

  @doc "The `metadata[\"reply_to_message_id\"]` of a message, or nil."
  @spec reply_to_id(map()) :: binary() | nil
  def reply_to_id(msg) do
    case Map.get(msg, :metadata) do
      %{"reply_to_message_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  @doc """
  The message `id` names when the viewer may see it (see the moduledoc),
  else nil. Takes the socket or its assigns.
  """
  @spec visible_message(map(), term()) :: Message.t() | nil
  def visible_message(socket_or_assigns, id) do
    assigns = assigns(socket_or_assigns)

    case Chat.get_message(id, scope: assigns[:external_scope]) do
      %Message{} = msg -> if classify(assigns, msg) == :visible, do: msg, else: nil
      nil -> nil
    end
  end

  @doc "The quote state for target `id` (nil id gives nil). One query."
  @spec resolve(map(), binary() | nil) :: state() | nil
  def resolve(_socket_or_assigns, nil), do: nil

  def resolve(socket_or_assigns, id) do
    assigns = assigns(socket_or_assigns)
    msg = if Platform.UUID.valid?(id), do: Chat.get_message(id, scope: assigns[:external_scope])
    to_state(assigns, msg)
  end

  @doc """
  `resolve/2` for many target ids in ONE query: `%{id => state}`. Ids that
  are not UUIDs, or that no row answers, map to `:no_access`.
  """
  @spec resolve_many(map(), [binary()]) :: %{binary() => state()}
  def resolve_many(_socket_or_assigns, []), do: %{}

  def resolve_many(socket_or_assigns, ids) do
    assigns = assigns(socket_or_assigns)
    ids = Enum.uniq(ids)

    found =
      ids
      |> Enum.filter(&Platform.UUID.valid?/1)
      |> Chat.get_messages_by_ids(scope: assigns[:external_scope], include_deleted: true)
      |> Map.new(&{&1.id, &1})

    Map.new(ids, &{&1, to_state(assigns, Map.get(found, &1))})
  end

  defp to_state(assigns, %Message{} = msg) do
    case classify(assigns, msg) do
      :visible -> visible_state(assigns, msg)
      :deleted -> %{status: :deleted}
      :no_access -> %{status: :no_access}
    end
  end

  defp to_state(_assigns, _nil), do: %{status: :no_access}

  # The bounds first, deletion last: a deleted message outside the viewer's
  # bounds must read exactly like any other message they cannot see.
  defp classify(assigns, %Message{} = msg) do
    with %{id: space_id} <- assigns[:active_space],
         true <- msg.space_id == space_id,
         true <- within_grant?(msg, assigns[:current_participant]) do
      if is_nil(msg.deleted_at), do: :visible, else: :deleted
    else
      _ -> :no_access
    end
  end

  defp within_grant?(%Message{inserted_at: at}, %Participant{
         history_visible_from: %DateTime{} = from
       })
       when not is_nil(at) do
    DateTime.compare(at, from) != :lt
  end

  defp within_grant?(_msg, _participant), do: true

  defp visible_state(assigns, %Message{} = target) do
    agent? =
      MapSet.member?(assigns[:agent_participant_ids] || MapSet.new(), target.participant_id)

    %{
      status: :visible,
      message_id: target.id,
      author: PresenceHooks.sender_name(assigns[:participants_map] || %{}, target),
      author_participant_id: target.participant_id,
      agent_slot:
        if(agent?,
          do:
            Platform.Agents.ColorPalette.slot_for(
              Map.get(assigns[:agent_slots_map] || %{}, target.participant_id)
            )
        ),
      at: Chat.message_ordered_at(target),
      preview: preview(target.content)
    }
  end

  @doc "One-line preview of a message body, capped at #{@preview_chars} characters."
  @spec preview(term()) :: String.t()
  def preview(content) when is_binary(content) do
    content
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.slice(0, @preview_chars)
  end

  def preview(_), do: ""

  defp assigns(%Phoenix.LiveView.Socket{assigns: assigns}), do: assigns
  defp assigns(%{} = assigns), do: assigns
end
