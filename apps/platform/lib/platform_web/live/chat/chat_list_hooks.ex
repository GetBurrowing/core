defmodule PlatformWeb.ChatLive.ChatListHooks do
  @moduledoc """
  Lifecycle hook for the phone Chat list's sheets (task 01a1557a-8562
  stage 3), the same shape as `SearchHooks` (ADR 0035).

  Owns:

    * `@list_sheet`: `nil | :search | :new | :options | {:row, space_id}`.
      ONE assign drives every list sheet, so two can never be open at once.
      Stage 4 uses the `{:row, _}` form.
    * `@list_search_query` and `@list_search_results`, the search sheet's
      state.
    * Events `open_list_sheet` (param `sheet`), `close_list_sheet` and
      `list_search`.

  `reset/1` clears all three and is called from `handle_params/3` for
  `:show`. That reset, not a click handler, is what closes the search sheet
  when the reader follows a result: every result is a plain `<.link patch>`
  with no `phx-click` (a bare-string `phx-click` on a patch link throws in the
  client, and a `JS.push` on one never reaches the server).

  ## What the search reads

    * CHANNELS: name matches over the flattened Spaces, the pinned channels
      and the Agents space (plus Archived while it is shown). Matching runs on
      the DISPLAYED, masked label, through `list_filter_sections/3` for the
      sectioned channels, so a masked row is never reachable by the name it
      is hiding.
    * DIRECT: `list_filter_dms/3` over the Direct list and the pinned DMs.
    * MESSAGES: `Chat.search_messages_in_spaces/3` over the channels and DMs
      MINUS `@restricted_channel_ids`, limit 20, only when
      `Chat.searchable_query?/1` holds. Which spaces is decided here; the
      search function decides nothing about access.
    * An empty query lists the five most recent conversations, by their last
      message.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  import PlatformWeb.ChatLive.RenderHelpers,
    only: [list_filter_dms: 3, list_filter_pinned: 3, list_filter_sections: 3]

  alias Platform.Chat
  alias Platform.Chat.SidebarMask
  alias PlatformWeb.ChatLive

  @sheets %{"search" => :search, "new" => :new, "options" => :options}
  @max_query 100
  @message_limit 20
  @recent_limit 5

  @empty %{channels: [], dms: [], messages: [], recent: []}

  @row_sheet_events ~w(toggle_pinned hide_channel close_dm close_row_actions toggle_sidebar_edit)

  @doc "The space id the row sheet is open on, or nil."
  def row_sheet_space_id({:row, id}), do: id
  def row_sheet_space_id(_), do: nil

  @doc "Attach the list-sheet handlers. Call from `ChatLive.mount/3`."
  def attach(socket) do
    socket
    |> reset()
    |> attach_hook(:chat_list_events, :handle_event, &handle_event/3)
  end

  @doc "Close every list sheet and clear the search."
  def reset(socket) do
    socket
    |> assign(:list_sheet, nil)
    |> assign(:list_search_query, "")
    |> assign(:list_search_results, @empty)
  end

  @doc false
  def empty_results, do: @empty

  # A row's long-press (`RowLongPress`): only a space on the reader's own
  # list opens the row sheet; anything else is ignored.
  defp handle_event("open_list_sheet", %{"sheet" => "row", "space_id" => id}, socket)
       when is_binary(id) do
    a = socket.assigns

    if Enum.any?(a.channels ++ a.dm_conversations, &(&1.id == id)) do
      {:halt, socket |> reset() |> assign(:list_sheet, {:row, id})}
    else
      {:halt, socket}
    end
  end

  defp handle_event("open_list_sheet", %{"sheet" => key}, socket) do
    case Map.fetch(@sheets, key) do
      {:ok, :search} ->
        {:halt, socket |> reset() |> assign(:list_sheet, :search) |> run_search("")}

      {:ok, sheet} ->
        {:halt, socket |> reset() |> assign(:list_sheet, sheet)}

      :error ->
        {:halt, socket}
    end
  end

  defp handle_event("close_list_sheet", _params, socket), do: {:halt, reset(socket)}

  # The row sheet's items fire the rail's EXISTING handlers, which reset
  # `@row_actions_space_id`; this resets `@list_sheet` on the same events and
  # lets the event continue to them.
  defp handle_event(event, _params, socket) when event in @row_sheet_events do
    socket =
      case socket.assigns[:list_sheet] do
        {:row, _} -> assign(socket, :list_sheet, nil)
        _ -> socket
      end

    {:cont, socket}
  end

  defp handle_event("list_search", %{"value" => value}, socket) when is_binary(value) do
    {:halt, run_search(socket, value)}
  end

  defp handle_event("list_search", _params, socket), do: {:halt, socket}

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── search ────────────────────────────────────────────────────────────

  defp run_search(socket, value) do
    query = value |> String.slice(0, @max_query) |> String.trim()

    socket
    |> assign(:list_search_query, query)
    |> assign(:list_search_results, search(socket.assigns, query))
  end

  @doc false
  # Pure over the assigns, so the component and the tests read one answer.
  def search(assigns, "") do
    %{@empty | recent: recent(assigns)}
  end

  def search(assigns, query) do
    %{
      channels: channel_hits(assigns, query),
      dms: dm_hits(assigns, query),
      messages: message_hits(assigns, query),
      recent: []
    }
  end

  defp mask_ctx(assigns) do
    SidebarMask.context(
      assigns.sidebar_sections,
      assigns.mask_names?,
      assigns.revealed_section_ids
    )
  end

  defp channel_hits(assigns, query) do
    sectioned =
      assigns.sidebar_sections
      |> list_filter_sections(query, mask_ctx(assigns))
      |> Platform.Chat.Sidebar.flatten_sections()

    pinned =
      assigns.channel_sections.pinned
      |> ChatLive.pinned_rail_entries([])
      |> Enum.filter(&(&1.kind == :channel))
      |> list_filter_pinned_masked(assigns, query)

    agents =
      case assigns.agents_block do
        %{space: space} -> masked_matches([space], assigns, query)
        _ -> []
      end

    archived =
      if assigns.archived_open,
        do: masked_matches(assigns.archived_channels, assigns, query),
        else: []

    Enum.uniq_by(agents ++ pinned ++ sectioned ++ archived, & &1.id)
  end

  # Pinned channels have no section in hand, so they match on the label the
  # header and the tab use (`masked_space_name/2`), as the list row renders.
  defp list_filter_pinned_masked(entries, assigns, query) do
    entries |> Enum.map(& &1.space) |> masked_matches(assigns, query)
  end

  defp masked_matches(spaces, assigns, query) do
    q = String.downcase(query)

    Enum.filter(spaces, fn space ->
      assigns
      |> ChatLive.masked_space_name(space.name || "")
      |> String.downcase()
      |> String.contains?(q)
    end)
  end

  defp dm_hits(assigns, query) do
    pinned_dms =
      assigns.channel_sections.pinned
      |> ChatLive.pinned_rail_entries([])
      |> Enum.filter(&(&1.kind == :dm))
      |> list_filter_pinned(query, assigns.user_id)
      |> Enum.map(& &1.space)

    Enum.uniq_by(
      pinned_dms ++ list_filter_dms(assigns.channel_sections.dms, query, assigns.user_id),
      & &1.id
    )
  end

  defp message_hits(assigns, query) do
    if Chat.searchable_query?(query) do
      assigns
      |> searchable_space_ids()
      |> Chat.search_messages_in_spaces(query,
        limit: @message_limit,
        scope: assigns[:access_scope]
      )
    else
      []
    end
  end

  @doc false
  # The channels and DMs on the reader's own list, minus restricted channels.
  def searchable_space_ids(assigns) do
    restricted = assigns.restricted_channel_ids

    (assigns.channels ++ assigns.dm_conversations)
    |> Enum.map(& &1.id)
    |> Enum.reject(&MapSet.member?(restricted, &1))
    |> Enum.uniq()
  end

  defp recent(assigns) do
    excerpts = assigns[:list_excerpts] || %{}
    restricted = assigns.restricted_channel_ids

    (assigns.channels ++ assigns.dm_conversations)
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&MapSet.member?(restricted, &1.id))
    |> Enum.filter(&Map.has_key?(excerpts, &1.id))
    |> Enum.sort_by(&excerpts[&1.id].inserted_at, {:desc, DateTime})
    |> Enum.take(@recent_limit)
  end
end
