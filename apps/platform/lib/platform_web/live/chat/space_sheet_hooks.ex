defmodule PlatformWeb.ChatLive.SpaceSheetHooks do
  @moduledoc """
  Lifecycle hook for the phone space sheet (task 01a1557a-8a6d, rung 7), the
  sheet the conversation header's title button opens. Same shape as
  `ChatListHooks` (ADR 0035).

  Owns ONE assign, `@space_sheet`: `nil` (shut) or the page the sheet shows.
  One assign means two pages can never be open at once. The pages the plan
  names are `:space`, `:search`, `:pinned`, `:threads`, `:goal` and `:scope`
  and `{:links, seg}`; a page is reachable only once its markup exists, so
  `@pages` lists only the built ones. Stage 1 built `:space`; stage 2 added
  `:search`, `:pinned` and `:threads`, and stage 3 `:goal` and `:scope`:
  pushed pages inside the same sheet with a back arrow, never a second
  sheet. Stage 4 adds the Links & files segments, `{:links, seg}` with `seg`
  in `@segments`, which sit beside the Space segment under one segment
  strip; the title tap now lands on `{:links, :all}`.

  It also owns what those pages read: `@space_sheet_pins`
  (`Chat.list_pins_with_messages/2`, read when Pinned opens and again on each
  pin broadcast while it is open) and `@space_sheet_threads`
  (`Chat.list_thread_summaries/2`, read when the sheet opens, for the
  Threads count, and when Threads opens). Search keeps using `SearchHooks`'
  own assigns through the existing `search_submit` / `search_clear` events.
  `@space_sheet_files` (`Chat.list_space_attachments/2`) and
  `@space_sheet_links` (`Chat.list_space_links/2`) are nil until a Links
  segment first shows, read once then, and dropped with the sheet: opening a
  space costs nothing extra.

  Events:

    * `open_space_sheet`: opens on the All segment. Ignored with no open
      space.
    * `close_space_sheet`: shuts it.
    * `space_sheet_page` (param `page`): moves an OPEN sheet to a page in
      `@pages`, or with `page=links` to the segment in param `seg`. Unknown
      keys are ignored, like `ChatListHooks`' `@sheets`.
    * `space_sheet_back`: from a sub-page back to `:space`.

  ## Jumping to a message (task 01a1557a-8a6d stage 5)

  A Search result and a Pinned row fire the EXISTING `search_open_result`
  with an extra `from=space_sheet`; a Threads row fires
  `space_sheet_open_thread`. Both land on the TOP-LEVEL message (a reply's
  parent), because the main list is top-level only:

    * in the loaded window (`@rendered_message_ids`): push
      `chat:scroll-to-message` for it, server-side and in the same reply, and
      let `search_open_result` run on (`{:cont, _}`) for its highlight and
      thread context. A Threads row expands the thread with
      `MessagesHooks.expand_inline_thread/3` (never the toggle, which would
      collapse an open one).
    * outside it: `push_patch` to `?message=<id>`, the existing anchored
      window (`MessagesHooks.enter_space_anchored/4`), which loads around the
      message and pushes the same scroll event itself. A thread, or a search
      hit that is a reply, is expanded right after, by a message to self
      handled once `handle_params/3` has re-entered the space.

  Without the scroll the sheet closed onto a highlight nobody could see: the
  hit stayed where it was, often far above the viewport.

  `enter_space/1` is called from `ChatLive.handle_params/3` for `:show`, so
  moving to another space always shuts the sheet (`reset/1`), and hands the
  desktop details panel its own space change
  (`DetailsPanelHooks.enter_space/1`, Burrow redesign 22 stage 3).

  ## The desktop details panel shares the loaders

  `PlatformWeb.ChatLive.DetailsPanelHooks` renders the same sections at lg
  and reads the same data through `load_pins/2`, `load_threads/2` and
  `load_links/3` here, into its own assigns (`@details_pins`, ...), so
  closing the phone sheet never empties the open panel. It is attached from
  `attach/1` below, after this module's hooks and so before `PinHooks`
  (the open Pinned page re-reads on the same pin broadcasts), which keeps
  `chat_live.ex` free of a new line. The sheet's action rows push
  `close_space_sheet` before their own event (`JS.push |> JS.push`), so the
  existing handler (members, settings, canvases, the meeting join, the agent
  mutex) runs unchanged.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3, push_patch: 2, push_navigate: 2]

  alias Platform.Chat
  alias PlatformWeb.ChatLive.DetailsPanelHooks
  alias PlatformWeb.ChatLive.MessagesHooks

  @pages %{
    "space" => :space,
    "search" => :search,
    "pinned" => :pinned,
    "threads" => :threads,
    "goal" => :goal,
    "scope" => :scope
  }

  @segments %{
    "all" => :all,
    "canvas" => :canvas,
    "file" => :file,
    "site" => :site,
    "video" => :video
  }

  @doc """
  Attach the space-sheet handlers. Call from `ChatLive.mount/3` BEFORE
  `PinHooks.attach/1`: PinHooks halts `{:pin_added, _}` / `{:pin_removed, _}`,
  and the open Pinned page re-reads on those same broadcasts.
  """
  def attach(socket) do
    socket
    |> reset()
    |> attach_hook(:space_sheet_events, :handle_event, &handle_event/3)
    |> attach_hook(:space_sheet_info, :handle_info, &handle_info/2)
    |> DetailsPanelHooks.attach()
  end

  @doc """
  Entering a space (`ChatLive.handle_params/3`, `:show`): shut the sheet and
  let the desktop details panel follow the new space.
  """
  def enter_space(socket) do
    socket
    |> reset()
    |> DetailsPanelHooks.enter_space()
  end

  @doc "Shut the space sheet and drop what its pages loaded."
  def reset(socket) do
    socket
    |> assign(:space_sheet, nil)
    |> assign(:space_sheet_pins, [])
    |> assign(:space_sheet_threads, [])
    |> assign(:space_sheet_files, nil)
    |> assign(:space_sheet_links, nil)
  end

  # Opening reads the thread summaries once: the Space page's Threads count
  # is their length, and the Threads page lists them.
  defp handle_event("space_canvases_browser", _params, socket) do
    actor = %{id: socket.assigns[:current_user_id]}
    space = socket.assigns[:active_space]

    with %{} <- space,
         {:ok, viewer} <- Platform.Files.BrowserActions.viewer(actor),
         {:ok, items} <- Platform.Files.Browser.in_space(viewer, space.id) do
      source = socket.assigns[:active_canvas]

      highlight =
        if source && Enum.any?(items, &(&1.kind == :canvas && &1.id == source.id)), do: source.id

      path =
        PlatformWeb.Files.BrowserView.browser_path(%{"space" => space.id, "type" => "canvas"}, %{
          "highlight" => highlight
        })

      {:halt, socket |> reset() |> push_navigate(to: path)}
    else
      _ -> {:halt, reset(socket)}
    end
  end

  defp handle_event("open_space_sheet", _params, socket) do
    if socket.assigns[:active_space] do
      {:halt, socket |> assign(:space_sheet, {:links, :all}) |> load_threads() |> load_links()}
    else
      {:halt, socket}
    end
  end

  defp handle_event("close_space_sheet", _params, socket), do: {:halt, reset(socket)}

  defp handle_event("space_sheet_page", %{"page" => "links", "seg" => seg}, socket) do
    case {socket.assigns[:space_sheet], Map.fetch(@segments, seg)} do
      {nil, _} ->
        {:halt, socket}

      {_open, {:ok, seg}} ->
        {:halt, socket |> assign(:space_sheet, {:links, seg}) |> load_links()}

      {_open, :error} ->
        {:halt, socket}
    end
  end

  defp handle_event("space_sheet_page", %{"page" => key}, socket) do
    case {socket.assigns[:space_sheet], Map.fetch(@pages, key)} do
      {nil, _} -> {:halt, socket}
      {_open, {:ok, page}} -> {:halt, socket |> assign(:space_sheet, page) |> load_page(page)}
      {_open, :error} -> {:halt, socket}
    end
  end

  defp handle_event("space_sheet_page", _params, socket), do: {:halt, socket}

  defp handle_event("space_sheet_back", _params, socket) do
    case socket.assigns[:space_sheet] do
      nil -> {:halt, socket}
      _page -> {:halt, assign(socket, :space_sheet, :space)}
    end
  end

  defp handle_event(
         "search_open_result",
         %{"from" => "space_sheet", "message-id" => id},
         socket
       ) do
    case jump_target(socket, id) do
      {:in_window, top_id, _reply?} ->
        {:cont, push_event(socket, "chat:scroll-to-message", %{id: top_id})}

      {:outside, top_id, reply?} ->
        {:halt, anchor(socket, top_id, reply?)}

      :none ->
        {:cont, socket}
    end
  end

  defp handle_event("space_sheet_open_thread", %{"message-id" => id}, socket) do
    case jump_target(socket, id) do
      {:in_window, top_id, _reply?} ->
        socket = push_event(socket, "chat:scroll-to-message", %{id: top_id})

        if MapSet.member?(socket.assigns[:expanded_threads] || MapSet.new(), top_id),
          do: {:halt, socket},
          else: {:halt, MessagesHooks.expand_inline_thread(socket, top_id, focus: false)}

      {:outside, top_id, _reply?} ->
        {:halt, anchor(socket, top_id, true)}

      :none ->
        {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # After the anchored re-entry (`handle_params/3` ran on the patch): open
  # the thread the jump was for.
  defp handle_info({:space_sheet_expand_thread, top_id}, socket) do
    case socket.assigns[:active_space] do
      %{} -> {:halt, MessagesHooks.expand_inline_thread(socket, top_id, focus: false)}
      _ -> {:halt, socket}
    end
  end

  # The pin broadcasts PinHooks also handles: re-read only while the Pinned
  # page is open, and always let PinHooks have the message.
  defp handle_info({event, _payload}, socket) when event in [:pin_added, :pin_removed] do
    case socket.assigns[:space_sheet] do
      :pinned -> {:cont, load_pins(socket)}
      _ -> {:cont, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # The top-level message a jump lands on, and whether it is in the loaded
  # window. A reply resolves to its thread's parent. Only a live message in
  # the open space resolves; anything else is :none and the jump is a no-op.
  defp jump_target(socket, id) do
    space = socket.assigns[:active_space]

    with %{id: space_id} <- space,
         %Chat.Message{} = msg <- Chat.get_message(id, scope: socket.assigns[:access_scope]),
         true <- msg.space_id == space_id and is_nil(msg.deleted_at),
         top_id when is_binary(top_id) <- top_level_id(msg) do
      rendered = socket.assigns[:rendered_message_ids] || MapSet.new()
      where = if MapSet.member?(rendered, top_id), do: :in_window, else: :outside
      {where, top_id, is_binary(msg.thread_id)}
    else
      _ -> :none
    end
  end

  defp top_level_id(%Chat.Message{thread_id: nil, id: id}), do: id

  defp top_level_id(%Chat.Message{thread_id: thread_id}) do
    case Chat.get_thread(thread_id) do
      %{parent_message_id: parent_id} -> parent_id
      _ -> nil
    end
  end

  defp anchor(socket, top_id, expand?) do
    if expand?, do: send(self(), {:space_sheet_expand_thread, top_id})

    socket
    |> reset()
    |> push_patch(
      to: "/chat/#{Chat.space_path_segment(socket.assigns.active_space)}?message=#{top_id}"
    )
  end

  defp load_page(socket, :pinned), do: load_pins(socket)
  defp load_page(socket, :threads), do: load_threads(socket)
  defp load_page(socket, _page), do: socket

  @doc """
  The open space's files and links into `files_key` / `links_key` (the
  sheet's by default). Once per open surface: a list already there is kept,
  and the surface's reset drops it, so the next open reads again.
  """
  def load_links(socket, files_key \\ :space_sheet_files, links_key \\ :space_sheet_links) do
    case {socket.assigns[links_key], socket.assigns[:active_space]} do
      {links, _space} when is_list(links) ->
        socket

      {_none, %{id: id}} ->
        scope = socket.assigns[:access_scope]

        socket
        |> assign(files_key, Chat.list_space_attachments(id, scope: scope))
        |> assign(links_key, Chat.list_space_links(id, scope: scope))

      _ ->
        socket
    end
  end

  @doc "The open space's pins with their messages into `key` (the sheet's by default)."
  def load_pins(socket, key \\ :space_sheet_pins) do
    case socket.assigns[:active_space] do
      %{id: id} ->
        assign(
          socket,
          key,
          Chat.list_pins_with_messages(id, scope: socket.assigns[:access_scope])
        )

      _ ->
        socket
    end
  end

  @doc "The open space's thread summaries into `key` (the sheet's by default)."
  def load_threads(socket, key \\ :space_sheet_threads) do
    case socket.assigns[:active_space] do
      %{id: id} ->
        assign(
          socket,
          key,
          Chat.list_thread_summaries(id, scope: socket.assigns[:access_scope])
        )

      _ ->
        socket
    end
  end
end
