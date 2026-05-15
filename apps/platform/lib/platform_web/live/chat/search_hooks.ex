defmodule PlatformWeb.ChatLive.SearchHooks do
  @moduledoc """
  Lifecycle hook module for the Search feature in `PlatformWeb.ChatLive`.

  See ADR 0035. Search has distributed UI (topbar form + body results
  panel) so it lives as a LifecycleHook. Owns:

    * Assigns: `:search_query`, `:search_results`, `:search_form`,
      `:highlighted_message_id`
    * Events:  `"search_submit"`, `"search_clear"`

  ## Cross-feature note (search_open_result)

  Opening a search result navigates to the message, which — if the
  message lives in a thread — expands the inline thread panel. That
  cross-feature action (Search + Threads + MessageList) stays in the
  parent LiveView's `handle_event("search_open_result", …)` until
  Threads extracts, at which point it becomes a PubSub notification
  instead. The parent calls `set_highlights/3` to update Search-owned
  assigns; Thread assigns remain parent-owned for now.

  ## Usage

      # In ChatLive.mount/3:
      socket = PlatformWeb.ChatLive.SearchHooks.attach(socket)

      # In ChatLive.handle_params/3 on space change:
      socket = PlatformWeb.ChatLive.SearchHooks.reset_for_space(socket)

      # In ChatLive.handle_info for message-list PubSub events:
      socket = PlatformWeb.ChatLive.SearchHooks.maybe_refresh(socket)
  """

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias Platform.Chat
  alias PlatformWeb.ChatLive.MessagesHooks

  @doc "Attach Search handlers. Call from `ChatLive.mount/3`."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:highlighted_message_id, nil)
    |> assign_form("")
    |> attach_hook(:search_events, :handle_event, &handle_event/3)
  end

  @doc "Clear search state on space change."
  @spec reset_for_space(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def reset_for_space(socket), do: clear(socket)

  @doc """
  Re-run the current search. Call from message-list PubSub handlers
  (new/updated/deleted messages, reactions) so the results stay fresh.
  """
  @spec maybe_refresh(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def maybe_refresh(socket) do
    query = socket.assigns.search_query

    if is_binary(query) and String.trim(query) != "" do
      apply_search(socket, query)
    else
      socket
    end
  end

  @doc """
  Update search-owned highlight assigns. Called from the parent's
  `search_open_result` handler while Threads is still parent-owned.
  """
  @spec set_highlights(Phoenix.LiveView.Socket.t(), binary() | nil) ::
          Phoenix.LiveView.Socket.t()
  def set_highlights(socket, message_id) do
    old_id = socket.assigns[:highlighted_message_id]

    socket
    |> assign(:highlighted_message_id, message_id)
    |> reinsert_for_highlight_change(old_id, message_id)
  end

  # ── Hook callbacks ────────────────────────────────────────────────────

  defp handle_event("search_submit", %{"search" => %{"query" => query}}, socket) do
    {:halt, apply_search(socket, query)}
  end

  defp handle_event("search_clear", _params, socket) do
    {:halt, clear(socket)}
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # ── Internals ────────────────────────────────────────────────────────

  defp apply_search(socket, query) do
    trimmed = String.trim(query || "")
    old_id = socket.assigns[:highlighted_message_id]

    results =
      case socket.assigns.active_space do
        %{id: space_id} when trimmed != "" ->
          Chat.search_messages(space_id, trimmed, limit: 12)

        _ ->
          []
      end

    socket
    |> assign(:search_query, trimmed)
    |> assign(:search_results, results)
    |> assign(:highlighted_message_id, nil)
    |> assign_form(trimmed)
    |> reinsert_for_highlight_change(old_id, nil)
  end

  defp clear(socket) do
    old_id = socket.assigns[:highlighted_message_id]

    socket
    |> assign(:search_query, "")
    |> assign(:search_results, [])
    |> assign(:highlighted_message_id, nil)
    |> assign_form("")
    |> reinsert_for_highlight_change(old_id, nil)
  end

  defp assign_form(socket, query) do
    assign(socket, :search_form, to_form(%{"query" => query}, as: :search))
  end

  # Reinsert the rows whose highlight glow needs to flip (old to clear,
  # new to apply). Filters through `:rendered_message_ids` (maintained
  # by MessagesHooks per PR #355) so we never call stream_insert on a
  # message that isn't currently in the DOM — otherwise
  # `stream_reinsert_with_day_label` would fall through to
  # `stream_insert_with_day_label` and silently INSERT a non-DOM message
  # (e.g. a search-jump target older than the loaded window) out-of-order
  # in the stream. See task 019e2740 Stage 1 recon for the architect
  # analysis.
  defp reinsert_for_highlight_change(socket, old_id, new_id) do
    rendered = socket.assigns[:rendered_message_ids] || MapSet.new()

    ids =
      [old_id, new_id]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(rendered, &1))

    MessagesHooks.reinsert_stream_messages(socket, ids)
  end
end
