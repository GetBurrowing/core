defmodule PlatformWeb.ChatLive.NewConversationComponent do
  @moduledoc """
  "New Conversation" modal (user/agent picker → DM or group).

  See ADR 0035. Self-contained modal → LiveComponent. Parent owns a
  `:show_new_conversation_modal` activation flag and passes it as the
  `:open` attr; the component fetches its own picker data on open.

  ## Events

    * `"new_conversation_close"` — dismiss
    * `"new_conversation_search"` — refilter picker
    * `"new_conversation_toggle"` — toggle a user/agent selection
    * `"new_conversation_submit"` — create DM/group, request navigation

  ## Messages sent to parent

    * `{:new_conversation_closed}` — parent clears activation flag
    * `{:new_conversation_navigate, path}` — parent `push_navigate`s
    * `{:new_conversation_flash, kind, msg}` — parent attaches a flash

  ## Attrs
    * `:id`       — component id
    * `:open`     — whether the modal is visible
    * `:user_id`  — current user's id (to exclude self from picker)
  """

  use PlatformWeb, :live_component

  alias Platform.Accounts
  alias Platform.Chat

  @impl true
  def update(%{open: true} = assigns, socket) do
    users = Accounts.list_users()
    agents = Chat.list_agents_for_picker()

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:users, users)
     |> assign(:agents, agents)
     |> assign(:query, "")
     |> assign(:selected, [])}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:users, fn -> [] end)
     |> assign_new(:agents, fn -> [] end)
     |> assign_new(:query, fn -> "" end)
     |> assign_new(:selected, fn -> [] end)}
  end

  @impl true
  def handle_event("new_conversation_close", _params, socket) do
    send(self(), {:new_conversation_closed})
    {:noreply, socket}
  end

  def handle_event("new_conversation_search", %{"value" => query}, socket) do
    users = Accounts.list_users(query: query)
    agents = Chat.list_agents_for_picker()

    filtered_agents =
      if query == "" do
        agents
      else
        pattern = String.downcase(query)
        Enum.filter(agents, fn a -> String.contains?(String.downcase(a.name || ""), pattern) end)
      end

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:users, users)
     |> assign(:agents, filtered_agents)}
  end

  def handle_event("new_conversation_toggle", %{"type" => type, "id" => id}, socket) do
    selected = socket.assigns.selected
    entry = %{type: type, id: id}

    updated =
      if Enum.any?(selected, fn s -> s.type == type and s.id == id end) do
        Enum.reject(selected, fn s -> s.type == type and s.id == id end)
      else
        selected ++ [entry]
      end

    {:noreply, assign(socket, :selected, updated)}
  end

  def handle_event("new_conversation_submit", _params, socket) do
    selected = socket.assigns.selected
    user_id = socket.assigns.user_id

    if selected == [] do
      send(self(), {:new_conversation_flash, :error, "Select at least one person or agent."})
      {:noreply, socket}
    else
      specs = Enum.map(selected, fn s -> %{type: s.type, id: s.id} end)

      result =
        if length(specs) == 1 do
          [spec] = specs
          Chat.find_or_create_dm(user_id, spec.type, spec.id)
        else
          Chat.create_group_conversation(user_id, specs)
        end

      case result do
        {:ok, space} ->
          nav_target = space.slug || space.id
          send(self(), {:new_conversation_navigate, "/chat/#{nav_target}"})
          {:noreply, socket}

        {:error, _reason} ->
          send(self(), {:new_conversation_flash, :error, "Could not create conversation."})
          {:noreply, socket}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      >
        <div
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6"
          phx-click-away="new_conversation_close"
          phx-target={@myself}
        >
          <h3 class="text-lg font-bold mb-4">New Conversation</h3>

          <div class="form-control mb-3">
            <input
              type="text"
              class="input input-bordered w-full input-sm"
              placeholder="Search users or agents…"
              phx-keyup="new_conversation_search"
              phx-target={@myself}
              phx-key=""
              value={@query}
            />
          </div>

          <div :if={@selected != []} class="flex flex-wrap gap-1 mb-3">
            <span
              :for={sel <- @selected}
              class="badge badge-primary badge-sm gap-1 cursor-pointer"
              phx-click="new_conversation_toggle"
              phx-target={@myself}
              phx-value-type={sel.type}
              phx-value-id={sel.id}
            >
              {selected_name(sel, @users, @agents)}
              <span class="text-xs">x</span>
            </span>
          </div>

          <div class="max-h-48 overflow-y-auto space-y-1 mb-3">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50 px-1">
              Users
            </p>
            <%= for user <- @users do %>
              <% is_self = user.id == @user_id %>
              <% is_selected =
                Enum.any?(@selected, fn s -> s.type == "user" and s.id == user.id end) %>
              <button
                :if={!is_self}
                type="button"
                phx-click="new_conversation_toggle"
                phx-target={@myself}
                phx-value-type="user"
                phx-value-id={user.id}
                class={[
                  "flex items-center gap-2 w-full px-2 py-1.5 rounded text-sm text-left transition-colors",
                  if(is_selected, do: "bg-primary/10 text-primary", else: "hover:bg-base-200")
                ]}
              >
                <.human_avatar
                  name={user.name || user.email || "User"}
                  avatar_url={user.avatar_url}
                  seed={user.oidc_sub || user.email || user.id}
                  size="sm"
                  class="flex-shrink-0"
                />
                <span class="truncate">{user.name || user.email}</span>
                <span :if={is_selected} class="ml-auto text-xs">selected</span>
              </button>
            <% end %>
          </div>

          <div :if={@agents != []} class="max-h-32 overflow-y-auto space-y-1 mb-4">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50 px-1">
              Agents
            </p>
            <%= for agent <- @agents do %>
              <% is_selected =
                Enum.any?(@selected, fn s -> s.type == "agent" and s.id == agent.id end) %>
              <button
                type="button"
                phx-click="new_conversation_toggle"
                phx-target={@myself}
                phx-value-type="agent"
                phx-value-id={agent.id}
                class={[
                  "flex items-center gap-2 w-full px-2 py-1.5 rounded text-sm text-left transition-colors",
                  if(is_selected, do: "bg-primary/10 text-primary", else: "hover:bg-base-200")
                ]}
              >
                <span class="w-6 h-6 rounded-full bg-accent/20 flex items-center justify-center text-xs font-bold text-accent">
                  {String.first(agent.name || "A") |> String.upcase()}
                </span>
                <span class="truncate">{agent.name}</span>
                <span class="badge badge-xs badge-accent ml-1">bot</span>
                <span :if={is_selected} class="ml-auto text-xs">selected</span>
              </button>
            <% end %>
          </div>

          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="new_conversation_close"
              phx-target={@myself}
              class="btn btn-ghost btn-sm"
            >
              Cancel
            </button>
            <button
              type="button"
              phx-click="new_conversation_submit"
              phx-target={@myself}
              class="btn btn-primary btn-sm"
              disabled={@selected == []}
            >
              {if length(@selected) <= 1, do: "Start DM", else: "Create Group"}
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp selected_name(%{type: "user", id: id}, users, _agents) do
    case Enum.find(users, fn u -> u.id == id end) do
      %{name: name} when is_binary(name) -> name
      %{email: email} -> email
      _ -> "User"
    end
  end

  defp selected_name(%{type: "agent", id: id}, _users, agents) do
    case Enum.find(agents, fn a -> a.id == id end) do
      %{name: name} -> name
      _ -> "Agent"
    end
  end
end
