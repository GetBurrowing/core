defmodule PlatformWeb.ChatLive.ChatListData do
  @moduledoc """
  The data behind the phone Chat list (`Partials.ChatList`, task 01a1557a-8562
  stage 2): the per-space last-message excerpts and the per-row identities
  (display name, and the agent behind an agent DM).

  Both are ASSIGNS, computed in a handful of queries for the whole list, never
  in the render. The drawer it replaces resolved a DM's label per row at
  render time (`RenderHelpers.sidebar_display_name/2`, one participant query
  per row); the list renders on every `/chat` visit and re-renders on every
  unread bump, so a per-row query there would put N round trips on the arrival
  of each message.

  ## Which spaces get an excerpt

  `excerpt_space_ids/1`: the channels, the DMs and the pinned task
  conversations, MINUS `@restricted_channel_ids`. A restricted channel renders
  the drawer's restricted treatment and no excerpt, so its newest message is
  never read. `Platform.Chat.last_message_excerpts/2` decides nothing about
  access (see its @doc), which is why the list is the one place that narrows.

  ## Live updates

  `put_message/2` patches ONE entry from an arriving message and
  `refresh_space/2` re-reads ONE space after a delete. Both act only on a
  space `excerpt_space_ids/1` already names, and only on a top-level message,
  so a thread reply never becomes a channel's headline (the same rule the
  query applies).
  """

  import Phoenix.Component, only: [assign: 3, update: 3]

  alias Platform.Chat
  alias Platform.Chat.Participant

  @doc """
  Load `@list_excerpts`, `@list_identities` and `@list_private_ids` for the
  list's spaces.
  """
  def assign_all(socket) do
    socket
    |> assign(:list_excerpts, load_excerpts(socket.assigns))
    |> assign(:list_identities, load_identities(socket.assigns))
    |> assign(:list_private_ids, load_private_ids(socket.assigns))
  end

  @doc """
  The private channels the reader CAN open, as a MapSet of ids: a channel
  carrying a role restriction (`Platform.Access.Restrictions`) that is not in
  `@restricted_channel_ids`. The list draws a lock for these and a `#` for
  every other channel; a channel the reader cannot open keeps the restricted
  row and its own marker, so "private" and "restricted" never share a glyph.
  """
  def load_private_ids(assigns) do
    restricted = assigns[:restricted_channel_ids] || MapSet.new()

    (List.wrap(assigns[:channels]) ++ List.wrap(assigns[:archived_channels]))
    |> Enum.filter(&(Map.get(&1, :kind) == "channel"))
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Platform.Access.Restrictions.gated_space_ids()
    |> MapSet.difference(restricted)
  end

  @doc """
  Reload both assigns after the rail's inputs changed, but only while the
  list is what is on screen (`:index`, not embedded, not external). A `:show`
  socket reloads on its way back to `:index`, in `handle_params/3`.
  """
  def maybe_refresh(socket) do
    a = socket.assigns

    if a[:live_action] == :index and not a[:embedded] and not a[:external?],
      do: assign_all(socket),
      else: socket
  end

  @doc """
  The channel a desktop `/chat` lands in: the first channel that is not
  restricted, or `nil` (no channel, or not on `/chat`): the landing desktop
  had before `/chat` became the phone list, for internal and external users
  alike.
  """
  def desktop_landing(assigns) do
    if assigns[:live_action] == :index do
      restricted = assigns[:restricted_channel_ids] || MapSet.new()
      Enum.find(List.wrap(assigns[:channels]), &(not MapSet.member?(restricted, &1.id)))
    end
  end

  @doc "The space ids the list may show an excerpt for."
  def excerpt_space_ids(assigns) do
    restricted = assigns[:restricted_channel_ids] || MapSet.new()

    (List.wrap(assigns[:channels]) ++
       List.wrap(assigns[:dm_conversations]) ++ List.wrap(assigns[:pinned_task_spaces]))
    |> Enum.map(& &1.id)
    |> Enum.reject(&MapSet.member?(restricted, &1))
    |> Enum.uniq()
  end

  @doc "`%{space_id => excerpt}` for every space `excerpt_space_ids/1` names."
  def load_excerpts(assigns) do
    assigns
    |> excerpt_space_ids()
    |> Chat.last_message_excerpts(scope: assigns[:access_scope])
  end

  @doc """
  Patch one excerpt from an arriving top-level message. A no-op when the
  socket carries no `@list_excerpts`, the message is a thread reply, or its
  space is not one the list may show.
  """
  def put_message(socket, %{thread_id: nil, space_id: space_id} = msg) do
    with %{} = excerpts <- socket.assigns[:list_excerpts],
         true <- space_id in excerpt_space_ids(socket.assigns) do
      entry = %{
        content: Chat.message_excerpt(msg.content),
        author_name: msg.author_display_name,
        inserted_at: msg.inserted_at
      }

      assign(socket, :list_excerpts, Map.put(excerpts, space_id, entry))
    else
      _ -> socket
    end
  end

  def put_message(socket, _msg), do: socket

  @doc """
  The phone list's order inside one section (task 01a166bf stage 1): newest
  top-level message first, by `excerpts[space.id].inserted_at` compared with
  `DateTime.compare/2` (never as strings). A row with no excerpt goes LAST,
  those rows by downcased name; equal times break by downcased name, then id.

  `rows` are spaces, or maps carrying one under `:space` (the Pinned
  entries). `name_fun` gives a row's name. Pure: `@list_excerpts` already
  holds each space's newest top-level message and `put_message/2` /
  `refresh_space/2` patch it live, so a new message re-sorts on the next
  render with no query.
  """
  def sort_by_recency(rows, excerpts, name_fun) when is_function(name_fun, 1) do
    Enum.sort(rows, fn a, b ->
      precedes?(sort_key(a, excerpts, name_fun), sort_key(b, excerpts, name_fun))
    end)
  end

  @doc """
  The order one section renders in (task 01a166bf stage 4): with no hold
  (`hold_ids` nil) exactly `sort_by_recency/3`; while the list is held,
  the order of `hold_ids` (the section's ids when the hold began), with any
  row the snapshot does not name appended at the END, those in recency
  order among themselves. Only ORDER freezes: the excerpt, time, weight and
  dot of every row still read the live assigns.
  """
  def order_rows(rows, excerpts, nil, name_fun), do: sort_by_recency(rows, excerpts, name_fun)

  def order_rows(rows, excerpts, hold_ids, name_fun) when is_list(hold_ids) do
    index = hold_ids |> Enum.with_index() |> Map.new()
    {known, unknown} = Enum.split_with(rows, &Map.has_key?(index, row_space(&1).id))

    Enum.sort_by(known, &Map.fetch!(index, row_space(&1).id)) ++
      sort_by_recency(unknown, excerpts, name_fun)
  end

  defp sort_key(row, excerpts, name_fun) do
    space = row_space(row)

    time =
      case Map.get(excerpts || %{}, space.id) do
        %{inserted_at: %DateTime{} = at} -> at
        _ -> nil
      end

    {time, String.downcase(to_string(name_fun.(row) || "")), to_string(space.id)}
  end

  defp row_space(%{space: %{id: _} = space}), do: space
  defp row_space(space), do: space

  defp precedes?({nil, _, _}, {%DateTime{}, _, _}), do: false
  defp precedes?({%DateTime{}, _, _}, {nil, _, _}), do: true

  defp precedes?({ta, na, ia}, {tb, nb, ib}) do
    case if(ta && tb, do: DateTime.compare(ta, tb), else: :eq) do
      :gt -> true
      :lt -> false
      :eq -> {na, ia} <= {nb, ib}
    end
  end

  @doc "Re-read one space's excerpt (after a delete). Absent when it has none."
  def refresh_space(socket, space_id) do
    with %{} <- socket.assigns[:list_excerpts],
         true <- space_id in excerpt_space_ids(socket.assigns) do
      fresh = Chat.last_message_excerpts([space_id], scope: socket.assigns[:access_scope])

      update(socket, :list_excerpts, fn excerpts ->
        case Map.fetch(fresh, space_id) do
          {:ok, entry} -> Map.put(excerpts, space_id, entry)
          :error -> Map.delete(excerpts, space_id)
        end
      end)
    else
      _ -> socket
    end
  end

  @doc """
  `%{space_id => %{name: String.t(), agent: nil | %{name, avatar_url, slot}}}`
  for the DMs and group conversations (pinned ones included) and the pinned
  task conversations.

  A conversation's name comes from `Chat.display_name_for_space/3`, the same
  function the drawer's `sidebar_row_label/2` ends in, fed one batched
  participant read instead of one read per row. `agent` is set for a
  one-to-one DM whose other participant is an agent, so its row can draw that
  agent's avatar in its rung-3 slot.
  """
  def load_identities(assigns) do
    user_id = assigns[:user_id]
    conversations = conversation_spaces(assigns)

    participants_by_space = conversations |> Enum.map(& &1.id) |> Chat.participants_by_space()
    agent_participants = participants_by_space |> Map.values() |> List.flatten()

    # The rail's own resolvers, keyed by participant id: `slot_for/1` of the
    # agent's colour (blue when none), and the avatar URL with blank ones left
    # out, so a row falls back exactly as every other agent surface does.
    slots = Chat.agent_slot_map_for_participants(agent_participants)
    avatars = Chat.agent_avatar_map_for_participants(agent_participants)

    conversation_identities =
      Map.new(conversations, fn space ->
        participants = Map.get(participants_by_space, space.id, [])

        {space.id,
         %{
           name: Chat.display_name_for_space(space, participants, user_id),
           agent: dm_agent(space, participants, user_id, slots, avatars)
         }}
      end)

    task_identities =
      Map.new(List.wrap(assigns[:pinned_task_spaces]), fn space ->
        {space.id, %{name: Platform.Tasks.ChatPins.display_name_for_space(space), agent: nil}}
      end)

    Map.merge(task_identities, conversation_identities)
  end

  # DMs and groups, from both lists a conversation can be rendered from: the
  # Direct section and the Pinned block.
  defp conversation_spaces(assigns) do
    pinned = get_in(assigns, [:channel_sections, :pinned]) || []

    (List.wrap(assigns[:dm_conversations]) ++ pinned)
    |> Enum.filter(&(&1.kind in ["dm", "group"]))
    |> Enum.uniq_by(& &1.id)
  end

  # A one-to-one DM whose other participant is an agent: that agent's name
  # (the participant's display name, as the row's own label), avatar and slot.
  defp dm_agent(%{kind: "dm"}, participants, user_id, slots, avatars) do
    case Enum.find(participants, &(&1.participant_id != user_id)) do
      %Participant{participant_type: "agent", id: pid, display_name: name} ->
        %{
          name: name || "",
          avatar_url: Map.get(avatars, pid),
          slot: Platform.Agents.ColorPalette.slot_for(Map.get(slots, pid))
        }

      _ ->
        nil
    end
  end

  defp dm_agent(_space, _participants, _user_id, _slots, _avatars), do: nil
end
