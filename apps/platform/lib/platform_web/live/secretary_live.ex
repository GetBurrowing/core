defmodule PlatformWeb.SecretaryLive do
  @moduledoc """
  The main view that replaces the Inbox (task 01a1b721 stage 4; mockup
  canvas 01a1b744-5ed4 screen 1, direction canvas 01a1b722-6a9a for intent):
  `/brief` is the brief, the goal groups, the person's own list, the quiet
  band and the no-AI fallback; `/brief/everything` is the raw list the
  secretary read, newest first.

  Everything shown is `Platform.Secretary.View.for_user/2` for the viewer;
  the screen re-reads it on `{:secretary_updated, user_id}`
  (`Platform.Secretary.topic/1`) and on the viewer's inbox events
  (`Platform.Inbox.subscribe/1`, which `PlatformWeb.ShellLive` already did
  for this process). Collections are streams, re-sorted with `reset: true`.

  ## Opening a row keeps today's Inbox semantics

  A row or brief action that maps to an inbox item calls
  `Platform.Inbox.open_item/2` before navigating, exactly as `/inbox` did,
  so the rail and tab badge (`Platform.Inbox.reachable_unread_count/1`,
  unchanged by this task) fall by one. `/brief?open=<item id>` does the same
  for a saved link or a push.

  ## What is deferred

  The why panel, the row menu, the interrupt settings and the nudge path
  are stage 5. The `What … knows` page, `Ask for a summary` and `Ask others
  to unblock my work` belong to child tasks and are deliberately absent.
  """

  use PlatformWeb, :live_view

  import PlatformWeb.Components.NotificationState, only: [notification_state_row: 1]
  import PlatformWeb.AgentPortrait, only: [agent_portrait: 1]

  alias Platform.Access
  alias Platform.Access.Scope
  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Inbox.Item
  alias Platform.Secretary
  alias Platform.Secretary.{Todos, View}
  alias PlatformWeb.Components.InboxItem

  @toast_ttl_ms 2_200

  @impl true
  def mount(_params, session, socket) do
    user_id = session["current_user_id"] || socket.assigns[:current_user_id]
    user = if is_binary(user_id), do: Accounts.get_user(user_id)

    if connected?(socket) and is_binary(user_id) do
      Phoenix.PubSub.subscribe(Platform.PubSub, Secretary.topic(user_id))
    end

    {:ok,
     socket
     |> assign(:page_title, Secretary.name())
     |> assign(:current_path, "/brief")
     |> assign(:current_user_id, user_id)
     |> assign(:viewer, user)
     |> assign(:name, Secretary.name())
     |> assign(:toast, nil)
     |> assign(:toast_nonce, 0)
     |> assign(:quiet_open?, false)
     |> assign(:editing_todo, nil)
     |> assign(:learned, %{})
     |> stream_configure(:groups, dom_id: & &1.id)
     |> stream_configure(:brief, dom_id: & &1.id)
     |> stream_configure(:quiet, dom_id: & &1.id)
     |> stream_configure(:everything, dom_id: &"every-#{&1.id}")
     |> load()}
  end

  @impl true
  def handle_params(%{"open" => id}, _uri, socket) when is_binary(id) do
    {:noreply, open_item(socket, id)}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, load(socket)}
  end

  # ── events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open", %{"ref_type" => "inbox_item", "ref_id" => id}, socket) do
    {:noreply, open_item(socket, id)}
  end

  def handle_event("open", %{"url" => url}, socket) when is_binary(url) and url != "" do
    {:noreply, push_navigate(socket, to: url)}
  end

  def handle_event("open", _params, socket),
    do: {:noreply, toast(socket, "Opens it, right where the ask is")}

  def handle_event("why", _params, socket), do: {:noreply, socket}
  def handle_event("menu", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_quiet", _params, socket),
    do: {:noreply, assign(socket, :quiet_open?, not socket.assigns.quiet_open?)}

  def handle_event("add_todo", %{"title" => title}, socket) do
    case String.trim(title || "") do
      "" ->
        {:noreply, socket}

      title ->
        {:ok, _} = Todos.add_own(socket.assigns.current_user_id, title)

        {:noreply, socket |> load() |> toast("Added. I’ll tie it to a goal if one fits.")}
    end
  end

  def handle_event("todo_toggle", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user_id

    case Todos.get(user_id, id) do
      %{status: "done"} -> Todos.undo(user_id, id)
      %{} -> Todos.mark_done(user_id, id, nil)
      nil -> :ok
    end

    {:noreply, load(socket)}
  end

  def handle_event("todo_undo", %{"id" => id}, socket) do
    Todos.undo(socket.assigns.current_user_id, id)
    {:noreply, socket |> load() |> toast("Undone. Back as it was.")}
  end

  def handle_event("todo_keep", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user_id
    goal = goal_label(socket, id)
    Todos.keep(user_id, id)
    {:noreply, socket |> assign(:editing_todo, nil) |> load() |> toast("Kept. It’s in #{goal}.")}
  end

  def handle_event("todo_edit", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :editing_todo, id)}

  def handle_event("todo_cancel_edit", _params, socket),
    do: {:noreply, assign(socket, :editing_todo, nil)}

  def handle_event("todo_save", %{"id" => id, "title" => title}, socket) do
    user_id = socket.assigns.current_user_id

    case String.trim(title || "") do
      "" -> :ok
      title -> Todos.edit(user_id, id, %{"title" => title})
    end

    Todos.keep(user_id, id)
    {:noreply, socket |> assign(:editing_todo, nil) |> load() |> toast("Kept, with your wording")}
  end

  def handle_event("todo_not", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user_id

    case Todos.dismiss(user_id, id) do
      {:ok, todo} ->
        {:noreply,
         socket
         |> assign(:learned, Map.put(socket.assigns.learned, id, todo))
         |> assign(:editing_todo, nil)
         |> load()
         |> toast("Learned. Undo is on the line.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("todo_not_undo", %{"id" => id}, socket) do
    Todos.undo(socket.assigns.current_user_id, id)

    {:noreply,
     socket
     |> assign(:learned, Map.delete(socket.assigns.learned, id))
     |> load()
     |> toast("Undone. Back as it was.")}
  end

  def handle_event("join", %{"space_id" => space_id}, socket) do
    user = socket.assigns.viewer
    scope = Scope.for_user(user)

    with %{kind: "channel"} = space <- Chat.get_space(space_id, scope: scope),
         true <- Access.can?(scope, "chat.read", {:space, space.id}),
         {:ok, _} <- ensure_participant(space.id, user) do
      {:noreply, socket |> load() |> toast("Joined ##{space.slug || space.name}")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_toast", %{"nonce" => nonce}, socket) do
    if to_string(socket.assigns.toast_nonce) == to_string(nonce),
      do: {:noreply, assign(socket, :toast, nil)},
      else: {:noreply, socket}
  end

  # ── info ────────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:secretary_updated, _user_id}, socket), do: {:noreply, load(socket)}

  def handle_info({evt, _}, socket)
      when evt in [:inbox_item_added, :inbox_item_dismissed, :inbox_item_read, :inbox_changed],
      do: {:noreply, load(socket)}

  def handle_info({:clear_toast, nonce}, socket) do
    if socket.assigns.toast_nonce == nonce,
      do: {:noreply, assign(socket, :toast, nil)},
      else: {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # ── internals ───────────────────────────────────────────────────────────

  defp load(%{assigns: %{viewer: nil}} = socket) do
    socket
    |> assign(:view, nil)
    |> assign(:mode, :ok)
    |> assign(:agent, nil)
    |> assign(:agent_name, Secretary.name())
    |> assign(:catching_up, 0)
    |> assign(:held_fyis, 0)
    |> assign(:fyi_count, 0)
    |> assign(:all_clear?, true)
    |> assign(:quiet_count, 0)
    |> assign(:quiet_summary, nil)
    |> stream(:groups, [], reset: true)
    |> stream(:brief, [], reset: true)
    |> stream(:quiet, [], reset: true)
    |> stream(:everything, [], reset: true)
  end

  defp load(%{assigns: %{live_action: :everything, viewer: user}} = socket) do
    view = View.for_user(user)

    socket
    |> assign_view(view)
    |> stream(:everything, View.everything(user), reset: true)
  end

  defp load(%{assigns: %{viewer: user}} = socket) do
    view = View.for_user(user)

    socket
    |> assign_view(view)
    |> stream(:groups, view.groups, reset: true)
    |> stream(:brief, view.brief, reset: true)
    |> stream(:quiet, view.quiet, reset: true)
  end

  defp assign_view(socket, view) do
    socket
    |> assign(:view, view)
    |> assign(:mode, view.mode)
    |> assign(:agent, view.agent)
    |> assign(:agent_name, view.agent_name)
    |> assign(:catching_up, view.catching_up)
    |> assign(:held_fyis, view.held_fyis)
    |> assign(:fyi_count, view.fyi_count)
    |> assign(:all_clear?, view.all_clear?)
    |> assign(:quiet_count, length(view.quiet))
    |> assign(:quiet_summary, quiet_summary(view.quiet))
  end

  # Opening is reading: `Inbox.open_item/2` first (the badge falls by one),
  # then the item's own url.
  defp open_item(socket, id) do
    user_id = socket.assigns.current_user_id
    result = if is_binary(user_id), do: Inbox.open_item(id, user_id), else: {:error, :not_found}

    case result do
      {:ok, %Item{url: url}} when is_binary(url) and url != "" ->
        push_navigate(socket, to: url)

      _ ->
        socket |> load() |> push_patch(to: ~p"/brief", replace: true)
    end
  end

  defp ensure_participant(space_id, user) do
    existing =
      space_id
      |> Chat.list_participants()
      |> Enum.find(&(&1.participant_type == "user" and &1.participant_id == user.id))

    case existing do
      nil ->
        Chat.add_participant(space_id, %{
          participant_type: "user",
          participant_id: user.id,
          display_name: user.name || user.email,
          joined_at: DateTime.utc_now()
        })

      participant ->
        {:ok, participant}
    end
  end

  defp goal_label(socket, todo_id) do
    case socket.assigns.view do
      %{groups: groups} ->
        Enum.find_value(groups, View.none_group_label(), fn group ->
          if Enum.any?(group.rows, &(&1.ref_type == "todo" and &1.ref_id == todo_id)),
            do: group.label
        end)

      _ ->
        View.none_group_label()
    end
  end

  defp quiet_summary([]), do: nil

  defp quiet_summary(rows) do
    rows
    |> Enum.map(& &1.kind_label)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, n} -> -n end)
    |> Enum.take(3)
    |> Enum.map_join(", ", fn {label, n} -> "#{n} #{String.downcase(label)}" end)
  end

  defp toast(socket, message) do
    nonce = socket.assigns.toast_nonce + 1
    Process.send_after(self(), {:clear_toast, nonce}, @toast_ttl_ms)
    socket |> assign(:toast, message) |> assign(:toast_nonce, nonce)
  end

  # ── template helpers ────────────────────────────────────────────────────

  defp kind_word(%Item{kind: kind}), do: InboxItem.kind_label(kind, :short)
  defp relative_time(at), do: InboxItem.relative_time(at)

  defp item_icon(%Item{kind: kind}), do: InboxItem.kind_icon(kind)

  defp row_icon(%{family?: true}), do: "hero-lock-closed"
  defp row_icon(%{kind: :not_in_space}), do: "hero-eye"
  defp row_icon(%{item: %Item{kind: kind}}), do: InboxItem.kind_icon(kind)
  defp row_icon(%{ref_type: "calendar_event"}), do: "hero-calendar"
  defp row_icon(%{ref_type: "chat_message"}), do: "hero-chat-bubble-left-right"
  defp row_icon(_), do: "hero-inbox"

  defp tag_class("decide"), do: "border-base-content/40 text-base-content"
  defp tag_class("waiting"), do: "border-warning/60 text-warning"
  defp tag_class("fyi"), do: "border-info/60 text-info"
  defp tag_class("not_in_space"), do: "border-dashed border-info/60 text-info"
  defp tag_class(_), do: "border-base-300 text-base-content/70"

  defp brief_tag_class("may_not_know"), do: "border-info/60 text-info"
  defp brief_tag_class("risk"), do: "border-warning/60 text-warning"
  defp brief_tag_class("nobody_flagged"), do: "border-base-300 text-base-content/70"
  defp brief_tag_class(_), do: "border-base-300 text-base-content"

  defp first_brief_id(%{brief: [%{id: id} | _]}), do: id
  defp first_brief_id(_), do: nil

  # Row 19: `from {source} · {why}` for a heard to-do, `you added this` for
  # the person's own; a kept suggestion names who asked and who heard it.
  defp todo_source(%{todo: %{origin: "self"}}, _agent), do: "you added this"

  defp todo_source(%{todo: %{origin: "heard"}} = row, agent) do
    where = if row.space_label, do: " in #{row.space_label}", else: ""
    who = row.author_label || "Someone"
    "#{who} asked#{where} · #{agent} heard it"
  end

  defp todo_source(row, _agent), do: row.source

  defp done_note(%{done_reason: reason}) when is_binary(reason) and reason != "",
    do: "Done, because #{reason}"

  defp done_note(_todo), do: "Done."

  defp fyis_below(n), do: "Nothing needs you right now. #{n} FYIs below."

  defp holding(n), do: "I’m holding #{n} FYIs for tonight, after family dinner."

  defp no_ai_copy(agent) do
    "#{agent} needs an AI login to read for you, so this is sorted by kind, not by what " <>
      "matters to you. Connect your AI login and #{agent} will write you a brief and say why " <>
      "each thing is here."
  end

  defp budget_copy,
    do: "I’ve done my reading for today, so this is sorted by kind until tomorrow."
end
