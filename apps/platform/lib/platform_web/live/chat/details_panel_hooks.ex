defmodule PlatformWeb.ChatLive.DetailsPanelHooks do
  @moduledoc """
  Lifecycle hook for the desktop details panel (Burrow redesign 22 stage 3,
  master-desktop.html `#details` L603): the right-hand panel at lg that holds
  the space sheet's sections (`Partials.SpaceSheet.sections/1` with
  `surface={:panel}`), rendered by `Partials.DetailsPanel`. Same shape as
  `SpaceSheetHooks` (ADR 0035), and attached from `SpaceSheetHooks.attach/1`,
  so `chat_live.ex` gains no line.

  Owns `@details_panel`: `nil` (closed: the aside is not rendered and the
  conversation takes the width) or the page it shows, in `@space_sheet`'s
  shapes: `:space`, `{:links, seg}`, `:search`, `:pinned`, `:threads`,
  `:goal`, `:scope`. What the pages read sits in the panel's own assigns,
  `@details_pins`, `@details_threads`, `@details_files`, `@details_links`,
  loaded by `SpaceSheetHooks`' loaders (the same functions, never a copy), so
  shutting the phone sheet never empties an open panel. `@details_space_id`
  is the space those were read for.

  Events:

    * `details_open` (`page`, and `seg` with `page=links`): opens on that
      page; no or an unknown page is the Space segment. Ignored with no open
      space.
    * `details_restore`: the `DetailsPanelState` hook's replay of a remembered
      open; the Space segment, and only while closed.
    * `details_page` (`page`, `seg`): moves an OPEN panel, as
      `space_sheet_page` moves the sheet.
    * `details_back`: from a pushed page back to `:space`.
    * `details_close`: closes it.
    * `members_open` with `details=space` (the refused-summon notice): opens
      a closed panel on Space, unremembered, and continues to the Members
      hook, so the desktop popover has its row to sit under.

  Opening and closing push `details:changed` `%{open: bool}`, which the hook
  writes to the viewer's client state.

  The header's `#chat-title` opens the All segment, `#chat-search` the Search
  page, and `#chat-details` toggles the Space segment (Burrow redesign 22
  stage 4). The rows fire the existing events (`members_open`, `agents_open`,
  `settings_open`, `meeting_join`, `canvas_panel_toggle`, `hide_channel`,
  `close_dm`) without `close_space_sheet`, so the panel stays open. The jump
  rows reuse `SpaceSheetHooks`' jump (`search_open_result` with
  `from=space_sheet`, `space_sheet_open_thread`); an anchored jump resets
  only the sheet.

  Moving to another space (`enter_space/1`, from
  `SpaceSheetHooks.enter_space/1`) keeps an open panel open on the same
  segment, and a pushed page goes back to the Space segment; the new space's
  data is read again.

  The only message handled is the pin broadcast `PinHooks` also takes
  (`{:cont, _}`, re-read while Pinned is shown); nothing new is sent, so
  ChatLive's catch-all sees no unmatched message from here.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_event: 3]

  alias PlatformWeb.ChatLive.SpaceSheetHooks

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

  @doc "Attach the panel's handlers and seed it closed."
  def attach(socket) do
    socket
    |> reset()
    |> attach_hook(:details_panel_events, :handle_event, &handle_event/3)
    |> attach_hook(:details_panel_info, :handle_info, &handle_info/2)
  end

  @doc "Close the panel and drop what its pages read."
  def reset(socket) do
    socket
    |> assign(:details_panel, nil)
    |> assign(:details_space_id, nil)
    |> clear()
  end

  @doc """
  The open space changed (or was re-entered). Closed: nothing. Open on
  another space: the same segment, a pushed page back to `:space`, and the
  new space's data. The same space (an anchored jump's re-entry): unchanged.
  """
  def enter_space(socket) do
    page = socket.assigns[:details_panel]
    space_id = active_space_id(socket)

    cond do
      is_nil(page) ->
        socket

      socket.assigns[:details_space_id] == space_id ->
        socket

      true ->
        page = if strip_page?(page), do: page, else: :space

        socket
        |> clear()
        |> assign(:details_panel, page)
        |> assign(:details_space_id, space_id)
        |> load(page)
    end
  end

  defp handle_event("details_open", params, socket) do
    case {active_space_id(socket), page_from(params)} do
      {nil, _} -> {:halt, socket}
      {_id, :error} -> {:halt, open(socket, :space)}
      {_id, {:ok, page}} -> {:halt, open(socket, page)}
    end
  end

  defp handle_event("details_restore", _params, socket) do
    case {socket.assigns[:details_panel], active_space_id(socket)} do
      {nil, id} when is_binary(id) -> {:halt, open(socket, :space)}
      _ -> {:halt, socket}
    end
  end

  defp handle_event("details_page", params, socket) do
    case {socket.assigns[:details_panel], page_from(params)} do
      {nil, _} -> {:halt, socket}
      {_open, {:ok, page}} -> {:halt, socket |> assign(:details_panel, page) |> load(page)}
      {_open, :error} -> {:halt, socket}
    end
  end

  defp handle_event("details_back", _params, socket) do
    case socket.assigns[:details_panel] do
      nil -> {:halt, socket}
      _page -> {:halt, assign(socket, :details_panel, :space)}
    end
  end

  defp handle_event("details_close", _params, socket) do
    case socket.assigns[:details_panel] do
      nil -> {:halt, socket}
      _page -> {:halt, socket |> reset() |> push_event("details:changed", %{open: false})}
    end
  end

  # The refused-summon notice's "View members" (Burrow redesign 22 stage 4):
  # the desktop Members popover sits under the panel's Members row, so a
  # closed panel opens on the Space segment first. `{:cont, _}`: the Members
  # hook still opens the popover (and, below lg, the sheet). Not remembered
  # (no `details:changed`): it was not the viewer's own open.
  defp handle_event("members_open", %{"details" => "space"}, socket) do
    case {socket.assigns[:details_panel], active_space_id(socket)} do
      {nil, id} when is_binary(id) ->
        {:cont,
         socket
         |> clear()
         |> assign(:details_panel, :space)
         |> assign(:details_space_id, id)
         |> load(:space)}

      _ ->
        {:cont, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  defp handle_info({event, _payload}, socket) when event in [:pin_added, :pin_removed] do
    case socket.assigns[:details_panel] do
      :pinned -> {:cont, SpaceSheetHooks.load_pins(socket, :details_pins)}
      _ -> {:cont, socket}
    end
  end

  defp handle_info(_msg, socket), do: {:cont, socket}

  # Opening reads the thread summaries (the Space page's Threads count) and
  # whatever the page itself lists.
  defp open(socket, page) do
    socket
    |> clear()
    |> assign(:details_panel, page)
    |> assign(:details_space_id, active_space_id(socket))
    |> load(page)
    |> push_event("details:changed", %{open: true})
  end

  defp page_from(%{"page" => "links", "seg" => seg}) do
    case Map.fetch(@segments, seg) do
      {:ok, seg} -> {:ok, {:links, seg}}
      :error -> :error
    end
  end

  defp page_from(%{"page" => key}) when is_binary(key), do: Map.fetch(@pages, key)
  defp page_from(_params), do: :error

  defp load(socket, page) do
    socket = SpaceSheetHooks.load_threads(socket, :details_threads)

    case page do
      {:links, _seg} -> SpaceSheetHooks.load_links(socket, :details_files, :details_links)
      :pinned -> SpaceSheetHooks.load_pins(socket, :details_pins)
      _ -> socket
    end
  end

  defp clear(socket) do
    socket
    |> assign(:details_pins, [])
    |> assign(:details_threads, [])
    |> assign(:details_files, nil)
    |> assign(:details_links, nil)
  end

  defp strip_page?(:space), do: true
  defp strip_page?({:links, _seg}), do: true
  defp strip_page?(_page), do: false

  defp active_space_id(socket) do
    case socket.assigns[:active_space] do
      %{id: id} -> id
      _ -> nil
    end
  end
end
