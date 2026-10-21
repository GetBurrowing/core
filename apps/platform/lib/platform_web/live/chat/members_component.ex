defmodule PlatformWeb.ChatLive.MembersComponent do
  @moduledoc """
  Channel members panel for `PlatformWeb.ChatLive` (task 01a0fd62 stage 3).

  The one channel-side surface for bringing an agent into a channel. It lists
  the space's People and Agents with their roles; a viewer who may bring agents
  in also gets an "Add agent" picker and a Remove button per agent row.

  ## Authorization

  `can_manage?` is `Platform.Chat.can_summon_agents?/2`, the same rule the
  `@[agent]` mention path applies, so the panel and a mention cannot disagree
  about who may add an agent. It is computed on the closed-to-open transition
  (like `SettingsComponent`'s danger zone). It is affordance only:
  `Chat.admin_add_agent/3` and `Chat.admin_remove_agent/3` re-authorize every
  call, so a forged `members_add_agent` from a member's socket is refused by
  the context, not by this module.

  The picker offers `Chat.summonable_agents_query/1` minus the agents already
  present, the same eligibility set the mention path matches against.

  There is no user-add control: adding people to a channel is outside the
  ticket that introduced this panel.

  ## Activation

  The parent owns `:show_members` and passes it as `:open`. The space id used
  by every write comes from the `:space` assign, never from event params.

  ## Events (all namespaced `members_*`)

    * `"members_close"`
    * `"members_add_agent"` — `%{"agent_id" => id}`
    * `"members_remove_agent"` — `%{"participant_id" => id}`

  ## Messages sent to parent

    * `{:members_closed}` — parent clears `:show_members`
    * `{:members_flash, kind, msg}` — parent attaches a flash

  The parent also `send_update`s `refresh: true` when a
  `{:participant_joined}` / `{:participant_left}` broadcast arrives for the
  space on screen, so the lists stay live while the panel is open.
  """

  use PlatformWeb, :live_component

  alias Platform.Chat

  @impl true
  def update(%{refresh: true}, socket) do
    {:ok, load_members(socket)}
  end

  def update(%{open: open, space: space} = assigns, socket) do
    freshly_opened? = open && socket.assigns[:open] != true
    space_changed? = space_id(space) != space_id(socket.assigns[:space])

    socket = assign(socket, assigns)

    socket =
      if open && space && (freshly_opened? || space_changed?) do
        socket
        |> assign(:can_manage?, Chat.can_summon_agents?(space, assigns[:current_user_id]))
        |> load_members()
      else
        socket
        |> assign_new(:can_manage?, fn -> false end)
        |> assign_new(:people, fn -> [] end)
        |> assign_new(:agents, fn -> [] end)
        |> assign_new(:available_agents, fn -> [] end)
      end

    {:ok, socket}
  end

  defp space_id(%{id: id}), do: id
  defp space_id(_), do: nil

  defp load_members(%{assigns: %{space: %{id: space_id} = space}} = socket) do
    participants = Chat.list_participants(space_id)
    agents = Enum.filter(participants, &(&1.participant_type == "agent"))

    available = if socket.assigns[:can_manage?], do: Chat.list_addable_agents(space), else: []

    socket
    |> assign(:people, Enum.filter(participants, &(&1.participant_type == "user")))
    |> assign(:agents, agents)
    |> assign(:available_agents, available)
  end

  defp load_members(socket), do: socket

  @impl true
  def handle_event("members_close", _params, socket) do
    send(self(), {:members_closed})
    {:noreply, socket}
  end

  def handle_event("members_add_agent", params, socket) do
    agent_id = params["agent_id"]

    case current_space(socket) do
      nil ->
        send(self(), {:members_flash, :error, "This channel no longer exists."})
        {:noreply, socket}

      space ->
        case Chat.admin_add_agent(space, socket.assigns[:current_user_id], agent_id) do
          {:ok, participant} ->
            send(self(), {:members_flash, :info, "#{participant.display_name} added."})
            {:noreply, load_members(socket)}

          {:error, :unauthorized} ->
            send(
              self(),
              {:members_flash, :error, "Only a channel admin can bring agents into this channel."}
            )

            {:noreply, socket}

          {:error, :not_found} ->
            send(self(), {:members_flash, :error, "Pick an agent to add."})
            {:noreply, socket}

          {:error, _} ->
            send(self(), {:members_flash, :error, "Could not add the agent."})
            {:noreply, socket}
        end
    end
  end

  def handle_event("members_remove_agent", params, socket) do
    participant_id = params["participant_id"]

    case current_space(socket) do
      nil ->
        send(self(), {:members_flash, :error, "This channel no longer exists."})
        {:noreply, socket}

      space ->
        case Chat.admin_remove_agent(space, socket.assigns[:current_user_id], participant_id) do
          {:ok, removed} ->
            send(self(), {:members_flash, :info, "#{removed.display_name} removed."})
            {:noreply, load_members(socket)}

          {:error, :unauthorized} ->
            send(
              self(),
              {:members_flash, :error,
               "Only a channel admin can remove agents from this channel."}
            )

            {:noreply, socket}

          {:error, _} ->
            send(self(), {:members_flash, :error, "Could not remove the agent."})
            {:noreply, socket}
        end
    end
  end

  # Re-read the space so an authorization decision never rests on a copy the
  # panel was handed before an archive or a kind change.
  defp current_space(socket) do
    case socket.assigns[:space] do
      %{id: id} -> Chat.get_space(id)
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open && @space}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50"
      >
        <%!-- phx-click-away, not an overlay phx-click: see SettingsComponent
             (task 019e95ea) for why an inline stopPropagation breaks every
             phx-click inside the modal in real browsers. --%>
        <div
          data-role="members-panel"
          class="bg-base-100 rounded-xl shadow-xl w-full max-w-md p-6 max-h-[80vh] overflow-y-auto"
          phx-click-away="members_close"
          phx-target={@myself}
        >
          <div class="mb-4 flex items-center justify-between gap-2">
            <h3 class="text-lg font-bold">Members</h3>
            <button
              type="button"
              phx-click="members_close"
              phx-target={@myself}
              class="btn btn-ghost btn-sm min-h-11 min-w-11 md:min-h-0 md:min-w-0"
              aria-label="Close members"
            >
              <span class="hero-x-mark size-4" aria-hidden="true"></span>
            </button>
          </div>

          <section class="mb-5">
            <h4 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content">
              People
            </h4>
            <ul class="flex flex-col gap-1">
              <li
                :for={p <- @people}
                data-role="members-person-row"
                class="flex items-center justify-between gap-2 text-sm text-base-content"
              >
                <span class="min-w-0 truncate">{p.display_name || "Unknown"}</span>
                <span class="shrink-0 text-xs text-subtle">{p.role}</span>
              </li>
            </ul>
            <p :if={@people == []} class="text-sm text-subtle">No people yet.</p>
          </section>

          <section>
            <h4 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content">
              Agents
            </h4>
            <ul class="flex flex-col gap-1">
              <li
                :for={a <- @agents}
                id={"members-agent-#{a.id}"}
                data-role="members-agent-row"
                data-agent-id={a.participant_id}
                class="flex min-h-11 items-center justify-between gap-2 text-sm text-base-content md:min-h-0"
              >
                <span class="min-w-0 truncate">{a.display_name || "Agent"}</span>
                <span class="flex shrink-0 items-center gap-2">
                  <span class="text-xs text-subtle">{a.role}</span>
                  <button
                    :if={@can_manage?}
                    type="button"
                    phx-click="members_remove_agent"
                    phx-value-participant_id={a.id}
                    phx-target={@myself}
                    data-role="members-remove-agent"
                    class="btn btn-ghost btn-xs min-h-11 min-w-11 md:min-h-0 md:min-w-0"
                  >
                    Remove
                  </button>
                </span>
              </li>
            </ul>
            <p :if={@agents == []} data-role="members-no-agents" class="text-sm text-subtle">
              No agents in this channel yet.
            </p>

            <form
              :if={@can_manage?}
              phx-submit="members_add_agent"
              phx-target={@myself}
              data-role="members-add-agent"
              class="mt-4 flex flex-col gap-2 sm:flex-row sm:items-center"
            >
              <label for={"#{@id}-agent-select"} class="sr-only">Add agent</label>
              <select
                id={"#{@id}-agent-select"}
                name="agent_id"
                class="select select-bordered select-sm w-full sm:flex-1"
                disabled={@available_agents == []}
              >
                <option value="">
                  {if @available_agents == [], do: "No agents left to add", else: "Add agent"}
                </option>
                <option :for={agent <- @available_agents} value={agent.id}>{agent.name}</option>
              </select>
              <button
                type="submit"
                class="btn btn-sm btn-primary min-h-11 md:min-h-0"
                disabled={@available_agents == []}
              >
                Add agent
              </button>
            </form>
          </section>
        </div>
      </div>
    </div>
    """
  end
end
