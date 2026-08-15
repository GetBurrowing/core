defmodule PlatformWeb.Components.Chat.AddParticipantSheet do
  @moduledoc """
  Search-and-add participant LiveComponent (task 019e2475-4395 stage 3).

  Wraps `PlatformWeb.Components.Sheet` with placement `:bottom` (mobile
  bottom-sheet, desktop side-panel per the Sheet component's responsive
  contract). Search input filters humans + agents; clicking a row calls
  `Platform.Chat.add_participant/2` (or `add_agent_participant/2`)
  against `:space_id` and the row drops out of the list (it's now in the
  roster).

  ## Why a LiveComponent

  The sheet owns its own search query + result list, and the parent only
  needs to know "open" / "closed" + flash on errors. Encapsulating the
  pickers + the add handlers here keeps `MeetingLive` lean (and lets
  ChatLive adopt this same component for "add to existing space" later
  — the planner called for a shared surface so the future add isn't a
  one-off).

  ## Attrs

    * `:id` — required component id, used for the sheet root + form ids.
    * `:open` — whether the sheet is visible.
    * `:space_id` — the chat space to add participants to. Required when
      `:open` is true; the component validates and surfaces a
      flash-via-parent if missing.
    * `:current_roster` — list of `%Platform.Chat.Participant{}` already
      in the space. Used to filter the picker so re-adds don't appear.

  ## Events emitted to parent

    * `{:add_participant_sheet_closed}` — backdrop tap, ESC, Cancel,
      or Close button.
    * `{:add_participant_sheet_added, %Platform.Chat.Participant{}}` —
      a row was added (parent typically already saw the
      `:participant_joined` PubSub broadcast and can no-op the message
      or use it to flash).
    * `{:add_participant_sheet_flash, kind, msg}` — non-fatal
      surface-back to parent (e.g. add_participant returned `{:error, _}`).
  """

  use PlatformWeb, :live_component

  alias Platform.Accounts
  alias Platform.Chat

  import PlatformWeb.AvatarComponents
  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  @impl true
  def update(%{open: true} = assigns, socket) do
    users = Accounts.list_users()
    agents = Chat.list_agents_for_picker()

    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:current_roster, fn -> [] end)
     |> assign(:users, users)
     |> assign(:agents, agents)
     |> assign(:query, "")}
  end

  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:current_roster, fn -> [] end)
     |> assign_new(:users, fn -> [] end)
     |> assign_new(:agents, fn -> [] end)
     |> assign_new(:query, fn -> "" end)}
  end

  @impl true
  def handle_event("add_participant_sheet_close", _params, socket) do
    send(self(), {:add_participant_sheet_closed})
    {:noreply, socket}
  end

  def handle_event("add_participant_sheet_search", %{"value" => query}, socket) do
    users = Accounts.list_users(query: query)

    agents =
      if query == "" do
        Chat.list_agents_for_picker()
      else
        pattern = String.downcase(query)

        Chat.list_agents_for_picker()
        |> Enum.filter(fn a ->
          String.contains?(String.downcase(a.name || ""), pattern)
        end)
      end

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:users, users)
     |> assign(:agents, agents)}
  end

  def handle_event("add_participant_sheet_pick", %{"type" => "user", "id" => user_id}, socket) do
    space_id = socket.assigns[:space_id]

    cond do
      is_nil(space_id) ->
        send(self(), {:add_participant_sheet_flash, :error, "No active space."})
        {:noreply, socket}

      already_in_roster?(socket.assigns.current_roster, "user", user_id) ->
        # No-op: row would have been filtered out, but defend against a
        # racing PubSub-add that re-rendered the picker mid-tap.
        {:noreply, socket}

      true ->
        case Accounts.get_user(user_id) do
          nil ->
            send(self(), {:add_participant_sheet_flash, :error, "User not found."})
            {:noreply, socket}

          user ->
            display_name = display_name_for_user(user)

            attrs = %{
              participant_type: "user",
              participant_id: user.id,
              display_name: display_name,
              joined_at: DateTime.utc_now()
            }

            case Chat.add_participant(space_id, attrs) do
              {:ok, participant} ->
                send(self(), {:add_participant_sheet_added, participant})
                {:noreply, socket}

              {:error, _changeset} ->
                send(
                  self(),
                  {:add_participant_sheet_flash, :error, "Could not add #{display_name}."}
                )

                {:noreply, socket}
            end
        end
    end
  end

  def handle_event("add_participant_sheet_pick", %{"type" => "agent", "id" => agent_id}, socket) do
    space_id = socket.assigns[:space_id]

    cond do
      is_nil(space_id) ->
        send(self(), {:add_participant_sheet_flash, :error, "No active space."})
        {:noreply, socket}

      already_in_roster?(socket.assigns.current_roster, "agent", agent_id) ->
        {:noreply, socket}

      true ->
        case Chat.add_agent_participant(space_id, agent_id) do
          {:ok, participant} ->
            send(self(), {:add_participant_sheet_added, participant})
            {:noreply, socket}

          {:error, :not_found} ->
            send(self(), {:add_participant_sheet_flash, :error, "Agent not found."})
            {:noreply, socket}

          {:error, _other} ->
            send(self(), {:add_participant_sheet_flash, :error, "Could not add agent."})
            {:noreply, socket}
        end
    end
  end

  @impl true
  def render(assigns) do
    addable_users = filter_addable_users(assigns.users, assigns.current_roster)
    addable_agents = filter_addable_agents(assigns.agents, assigns.current_roster)

    assigns =
      assigns
      |> assign(:addable_users, addable_users)
      |> assign(:addable_agents, addable_agents)

    ~H"""
    <div id={@id} data-component="add-participant-sheet">
      <.sheet
        id={"#{@id}-sheet"}
        open={@open}
        placement={:bottom}
        on_close={JS.push("add_participant_sheet_close", target: @myself)}
      >
        <:title>Add to meeting</:title>

        <div class="flex flex-col gap-3">
          <div class="form-control">
            <label class="sr-only" for={"#{@id}-search"}>Search people or agents</label>
            <input
              type="text"
              id={"#{@id}-search"}
              class="input input-bordered w-full input-sm"
              placeholder="Search people or agents..."
              phx-keyup="add_participant_sheet_search"
              phx-target={@myself}
              phx-debounce="120"
              value={@query}
              autocomplete="off"
              data-role="add-participant-search"
            />
          </div>

          <%!-- People section --%>
          <section data-section="people">
            <p class="px-1 pb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              People
            </p>
            <ul class="flex max-h-48 flex-col gap-0.5 overflow-y-auto" role="list">
              <li
                :if={@addable_users == []}
                class="px-2 py-1.5 text-xs text-base-content/40"
                data-role="people-empty-state"
              >
                {if @query == "", do: "No more people to add.", else: "No people match."}
              </li>
              <li :for={user <- @addable_users}>
                <button
                  type="button"
                  phx-click="add_participant_sheet_pick"
                  phx-target={@myself}
                  phx-value-type="user"
                  phx-value-id={user.id}
                  class="group flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm min-h-11 transition-colors hover:bg-base-200"
                  data-role="add-participant-row"
                  data-participant-kind="user"
                  data-user-id={user.id}
                >
                  <.human_avatar
                    name={user.name || user.email || "User"}
                    avatar_url={user.avatar_url}
                    seed={user.oidc_sub || user.email || user.id}
                    size="sm"
                    class="flex-shrink-0"
                  />
                  <span class="min-w-0 flex-1 truncate">
                    {user.name || user.email || "User"}
                  </span>
                  <span
                    class="hero-plus-circle size-5 flex-shrink-0 text-primary opacity-60 group-hover:opacity-100"
                    aria-hidden="true"
                  >
                  </span>
                </button>
              </li>
            </ul>
          </section>

          <%!-- Agents section --%>
          <section data-section="agents">
            <p class="px-1 pb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Agents
            </p>
            <ul class="flex max-h-40 flex-col gap-0.5 overflow-y-auto" role="list">
              <li
                :if={@addable_agents == []}
                class="px-2 py-1.5 text-xs text-base-content/40"
                data-role="agents-empty-state"
              >
                {if @query == "", do: "No more agents to add.", else: "No agents match."}
              </li>
              <li :for={agent <- @addable_agents}>
                <button
                  type="button"
                  phx-click="add_participant_sheet_pick"
                  phx-target={@myself}
                  phx-value-type="agent"
                  phx-value-id={agent.id}
                  class="group flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-sm min-h-11 transition-colors hover:bg-base-200"
                  data-role="add-participant-row"
                  data-participant-kind="agent"
                  data-agent-id={agent.id}
                >
                  <%!-- Twin of the new-conversation picker's Agents section,
                       beside a People section that already calls
                       `human_avatar/1`. Converted for consistency even though
                       this component currently has no `live_component` call
                       site anywhere in `lib/` — an unmounted copy of the
                       hand-rolled pattern is exactly how it gets resurrected. --%>
                  <.agent_avatar
                    name={agent.name || "Agent"}
                    avatar_url={agent.avatar_url}
                    size="sm"
                    class="flex-shrink-0"
                  />
                  <span class="min-w-0 flex-1 truncate">
                    {agent.name}
                  </span>
                  <span class="badge badge-xs badge-accent">bot</span>
                  <span
                    class="hero-plus-circle size-5 flex-shrink-0 text-primary opacity-60 group-hover:opacity-100"
                    aria-hidden="true"
                  >
                  </span>
                </button>
              </li>
            </ul>
          </section>
        </div>

        <:actions>
          <button
            type="button"
            phx-click="add_participant_sheet_close"
            phx-target={@myself}
            class="btn btn-ghost btn-sm"
          >
            Done
          </button>
        </:actions>
      </.sheet>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────────

  defp filter_addable_users(users, roster) do
    user_ids =
      roster
      |> Enum.filter(&(&1.participant_type == "user"))
      |> MapSet.new(& &1.participant_id)

    Enum.reject(users, &MapSet.member?(user_ids, &1.id))
  end

  defp filter_addable_agents(agents, roster) do
    agent_ids =
      roster
      |> Enum.filter(&(&1.participant_type == "agent"))
      |> MapSet.new(& &1.participant_id)

    Enum.reject(agents, &MapSet.member?(agent_ids, &1.id))
  end

  defp already_in_roster?(roster, type, id) do
    Enum.any?(roster, fn p ->
      p.participant_type == type and p.participant_id == id
    end)
  end

  defp display_name_for_user(%{name: name}) when is_binary(name) and name != "", do: name
  defp display_name_for_user(%{email: email}) when is_binary(email), do: email
  defp display_name_for_user(_), do: "User"
end
