defmodule PlatformWeb.ChatLive.MembersComponent do
  @moduledoc """
  The Members sheet for `PlatformWeb.ChatLive` (task 01a0fd62 stage 3,
  reshaped into a sheet and a popover by task 01a1557a-8f80 stage 3).

  It lists the space's People as online or away and its Agents as awake or
  silenced. A viewer who may bring agents in also gets an "Add agent" picker
  and a Remove button per agent row.

  ## Two surfaces, two instances

  `surface` picks what an instance renders:

    * `:sheet` — the phone bottom sheet (`<.sheet>`, `lg:hidden`), rendered by
      `chat_live.html.heex` and opened from the space sheet's Members row.
    * `:popover` — the desktop popover (`hidden lg:flex`), rendered inside the
      header beside the `members-open` button it is anchored under, closed by
      a click outside or Esc.

  A LiveComponent renders in one place, and the popover has to sit in the
  header while the sheet cannot (the header's icon row is `lg`-only), so the
  two are two instances (`instance_ids/0`). Each reads only while open.

  ## Presence

  People come from `Chat.space_member_presence/2`: ONLINE is online anywhere
  in Burrow the viewer can see, or the viewer; AWAY is every other member. A
  failed presence read renders "Presence unavailable" and lists the people
  with no online or away word at all: it never renders as everybody away.
  The dot is decoration (`aria-hidden`); the word carries the state. Online
  is `bg-success`; away and unavailable are `bg-subtle`, as is a silenced
  agent's ring: `--edge` and `--color-neutral` measured under 3:1 on base-100
  (stage 4, `agents_members_sheets_contrast_guard_test.exs`).

  ## Authorization

  `can_manage?` is `Platform.Chat.can_summon_agents?/2`, the same rule the
  `@[agent]` mention path applies, so the sheet and a mention cannot disagree
  about who may add an agent. It is affordance only: `Chat.admin_add_agent/3`
  and `Chat.admin_remove_agent/3` re-authorize every call, so a forged
  `members_add_agent` from a member's socket is refused by the context.

  The picker offers `Chat.list_addable_agents/1`, the same eligibility set the
  mention path matches against. There is no people-add control.

  ## Activation

  The parent owns `:show_members` (`PlatformWeb.ChatLive.MembersSheetHooks`)
  and passes it as `:open`. The space id used by every write comes from the
  `:space` assign, never from event params.

  ## Events (all namespaced `members_*`)

    * `"members_close"`
    * `"members_add_agent"` — `%{"agent_id" => id}`
    * `"members_remove_agent"` — `%{"participant_id" => id}`

  ## Messages sent to parent

    * `{:members_closed}` — parent clears `:show_members`
    * `{:members_flash, kind, msg}` — parent attaches a flash

  The parent `send_update`s `refresh: true` to both instances when a
  `{:participant_joined}` / `{:participant_left}` broadcast or a presence diff
  arrives, so the lists stay live while the sheet is open.
  """

  use PlatformWeb, :live_component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias Platform.Agents.ColorPalette
  alias Platform.Chat

  @instance_ids ["chat-members", "chat-members-popover"]

  @doc "The DOM/component ids of the two instances: the phone sheet, then the desktop popover."
  @spec instance_ids() :: [String.t()]
  def instance_ids, do: @instance_ids

  @doc """
  The sheet's title and accessible name: `\"Members · <space name>\"`.

  Takes the DISPLAY name the call site already resolved through
  `space_header_name/4` + `space_mask/1`, never `space.name`: the popover
  renders inside the conversation `<header>`, so a raw name here spells a
  masked org's channel out under screen-share masking
  (`PlatformWeb.ChatLiveMaskTitleTest`).
  """
  @spec title(String.t() | nil) :: String.t()
  def title(name) when is_binary(name) and name != "", do: "Members · " <> name
  def title(_name), do: "Members"

  @doc """
  The header entry's and the space sheet row's people count, from the
  participant list ChatLive already holds: `\"3 people\"`, `\"1 person\"`.
  """
  @spec people_label([map()]) :: String.t()
  def people_label(participants) do
    case Enum.count(participants, &(&1.participant_type == "user")) do
      1 -> "1 person"
      n -> "#{n} people"
    end
  end

  @impl true
  def update(%{refresh: true}, socket) do
    {:ok, if(socket.assigns[:open], do: load_members(socket), else: socket)}
  end

  def update(%{open: open, space: space} = assigns, socket) do
    freshly_opened? = open && socket.assigns[:open] != true
    space_changed? = space_id(space) != space_id(socket.assigns[:space])

    socket = socket |> assign(assigns) |> assign_new(:space_name, fn -> nil end)

    socket =
      if open && space && (freshly_opened? || space_changed?) do
        socket
        |> assign(:can_manage?, Chat.can_summon_agents?(space, assigns[:current_user_id]))
        |> load_members()
      else
        socket
        |> assign_new(:can_manage?, fn -> false end)
        |> assign_new(:people, fn -> [] end)
        |> assign_new(:presence, fn -> {:ok, %{online: [], away: []}} end)
        |> assign_new(:attention, fn -> nil end)
        |> assign_new(:available_agents, fn -> [] end)
      end

    {:ok, socket}
  end

  defp space_id(%{id: id}), do: id
  defp space_id(_), do: nil

  defp load_members(%{assigns: %{space: %{id: space_id} = space}} = socket) do
    viewer_id = socket.assigns[:current_user_id]
    viewer = socket.assigns[:viewer] || %{id: viewer_id}

    people =
      space_id
      |> Chat.list_participants(participant_type: "user")
      |> Enum.map(&Chat.member_row(&1, viewer_id))
      |> Chat.sort_members()

    available = if socket.assigns[:can_manage?], do: Chat.list_addable_agents(space), else: []

    socket
    |> assign(:people, people)
    |> assign(:presence, Chat.space_member_presence(space_id, viewer))
    |> assign(:attention, Chat.agent_attention_state(space_id))
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
  def render(%{surface: :sheet} = assigns) do
    ~H"""
    <div id={@id}>
      <.sheet
        id="members-sheet"
        open={@open && @space != nil}
        placement={:bottom}
        on_close="members_close"
        on_close_target={@myself}
        class="members-sheet lg:hidden"
        handle_close
        swipe_dismiss
      >
        <:title>{title(@space_name)}</:title>
        <div :if={@open && @space} class="flex flex-col pb-2" data-role="members-sheet-body">
          <p class="px-4 pb-1 text-base font-semibold text-base-content" aria-hidden="true">
            {title(@space_name)}
          </p>
          <.body
            surface={:sheet}
            id={@id}
            myself={@myself}
            people={@people}
            presence={@presence}
            attention={@attention}
            can_manage?={@can_manage?}
            available_agents={@available_agents}
          />
        </div>
      </.sheet>
    </div>
    """
  end

  def render(%{surface: :popover} = assigns) do
    ~H"""
    <div id={@id}>
      <div
        :if={@open && @space}
        id="members-popover"
        role="dialog"
        aria-labelledby="members-popover-title"
        phx-click-away="members_close"
        phx-window-keydown="members_close"
        phx-key="Escape"
        phx-target={@myself}
        class="absolute right-0 top-full z-40 mt-1 hidden max-h-[70vh] w-80 min-w-[280px] max-w-[360px] flex-col overflow-y-auto rounded-box border border-edge bg-base-100 py-2 shadow lg:flex"
      >
        <p id="members-popover-title" class="px-4 pb-1 text-base font-semibold text-base-content">
          {title(@space_name)}
        </p>
        <.body
          surface={:popover}
          id={@id}
          myself={@myself}
          people={@people}
          presence={@presence}
          attention={@attention}
          can_manage?={@can_manage?}
          available_agents={@available_agents}
        />
      </div>
    </div>
    """
  end

  attr(:surface, :atom, required: true)
  attr(:id, :string, required: true)
  attr(:myself, :any, required: true)
  attr(:people, :list, required: true)
  attr(:presence, :any, required: true)
  attr(:attention, :any, required: true)
  attr(:can_manage?, :boolean, required: true)
  attr(:available_agents, :list, required: true)

  defp body(assigns) do
    assigns = assign(assigns, :rows, person_rows(assigns.presence, assigns.people))

    ~H"""
    <section data-role="members-people">
      <p class="px-4 pb-1 text-[13px] font-semibold text-subtle">People</p>
      <div
        :if={match?({:error, _}, @presence)}
        data-role="members-presence-unavailable"
        class="flex min-h-11 items-center gap-3 px-4 py-2"
      >
        <span class="inline-block size-2 shrink-0 rounded-full bg-subtle" aria-hidden="true"></span>
        <span class="text-[13px] text-subtle">Presence unavailable</span>
      </div>
      <ul class="flex flex-col">
        <li
          :for={{person, state} <- @rows}
          data-role="members-person-row"
          data-presence={state}
          data-user-id={person.user_id}
          class={["flex min-h-11 items-center gap-3 px-4 py-2", row_press(@surface)]}
        >
          <span
            :if={state != "unknown"}
            aria-hidden="true"
            class={["inline-block size-2 shrink-0 rounded-full", dot_class(state)]}
          >
          </span>
          <span class="flex min-w-0 flex-1 flex-col">
            <span class="truncate text-[15px] text-base-content">{person.name}</span>
            <span :if={state != "unknown"} class="text-[13px] text-subtle">{state}</span>
          </span>
          <span :if={person.you?} data-role="members-you" class="text-[13px] text-subtle">
            you
          </span>
        </li>
      </ul>
      <p :if={@people == []} class="px-4 py-2 text-[13px] text-subtle">No people yet.</p>
    </section>

    <section class="mt-2 border-t border-edge pt-2" data-role="members-agents">
      <p class="px-4 pb-1 text-[13px] font-semibold text-subtle">Agents</p>
      <ul :if={@attention} class="flex flex-col">
        <.agent_row
          :for={agent <- @attention.agents}
          agent={agent}
          paused?={!@attention.agents_awake}
          surface={@surface}
          can_manage?={@can_manage?}
          myself={@myself}
          id={@id}
        />
      </ul>
      <p
        :if={@attention == nil or @attention.agents == []}
        data-role="members-no-agents"
        class="px-4 py-2 text-[13px] text-subtle"
      >
        No agents in this space yet.
      </p>

      <form
        :if={@can_manage?}
        phx-submit="members_add_agent"
        phx-target={@myself}
        data-role="members-add-agent"
        class="mt-2 flex items-center gap-2 px-4"
      >
        <label for={"#{@id}-agent-select"} class="sr-only">Add agent</label>
        <select
          id={"#{@id}-agent-select"}
          name="agent_id"
          class="select select-sm min-h-11 flex-1 border-edge bg-base-100 text-base-content lg:min-h-0"
          disabled={@available_agents == []}
        >
          <option value="">
            {if @available_agents == [], do: "No agents left to add", else: "Add agent"}
          </option>
          <option :for={agent <- @available_agents} value={agent.id}>{agent.name}</option>
        </select>
        <button
          type="submit"
          class="btn btn-sm btn-primary min-h-11 lg:min-h-0"
          disabled={@available_agents == []}
        >
          Add agent
        </button>
      </form>
    </section>
    """
  end

  attr(:agent, :map, required: true)
  attr(:paused?, :boolean, required: true)
  attr(:surface, :atom, required: true)
  attr(:can_manage?, :boolean, required: true)
  attr(:myself, :any, required: true)
  attr(:id, :string, required: true, doc: "the instance id, so the two surfaces' row ids differ")

  defp agent_row(assigns) do
    assigns = assign(assigns, :row_state, agent_state(assigns.agent.silenced, assigns.paused?))

    ~H"""
    <li
      id={"#{@id}-agent-#{@agent.participant_id}"}
      data-role="members-agent-row"
      data-agent-id={@agent.agent_id}
      data-state={@row_state}
      data-agent-slot={@row_state == "awake" && ColorPalette.slot_for(@agent.slot)}
      class={["flex min-h-11 items-center gap-3 px-4 py-2", row_press(@surface)]}
    >
      <span
        aria-hidden="true"
        class={[
          "flex size-7 shrink-0 items-center justify-center rounded-full border-2 bg-base-200 text-xs font-semibold",
          if(@row_state == "awake",
            do: "border-(--ag) text-(--ag-text)",
            else: "border-subtle text-subtle"
          )
        ]}
      >
        {initial(@agent.name)}
      </span>
      <span class="flex min-w-0 flex-1 flex-col">
        <span class={[
          "truncate text-[15px]",
          if(@row_state == "awake", do: "text-(--ag-text)", else: "text-subtle")
        ]}>
          {@agent.name}
        </span>
        <span class="text-[13px] text-subtle">{agent_meta(@row_state)}</span>
      </span>
      <button
        :if={@can_manage?}
        type="button"
        phx-click="members_remove_agent"
        phx-value-participant_id={@agent.participant_id}
        phx-target={@myself}
        data-role="members-remove-agent"
        aria-label={"Remove #{@agent.name}"}
        class="btn btn-ghost btn-xs min-h-11 min-w-11 text-base-content lg:min-h-0 lg:min-w-0"
      >
        Remove
      </button>
    </li>
    """
  end

  # `{person, state}` per person row. A failed read is "unknown" for every
  # row: no dot, no word, so it can never read as away.
  defp person_rows({:ok, %{online: online, away: away}}, _people),
    do: Enum.map(online, &{&1, "online"}) ++ Enum.map(away, &{&1, "away"})

  defp person_rows(_failed, people), do: Enum.map(people, &{&1, "unknown"})

  defp dot_class("online"), do: "bg-success"
  defp dot_class("away"), do: "bg-subtle"

  defp agent_state(_silenced, true), do: "paused"
  defp agent_state(true, false), do: "silenced"
  defp agent_state(false, false), do: "awake"

  defp agent_meta("paused"), do: "Paused for this space"
  defp agent_meta(state), do: state

  # Phone rows press; only the desktop popover gets a hover fill.
  defp row_press(:sheet), do: "active:bg-base-200"
  defp row_press(:popover), do: "active:bg-base-200 lg:hover:bg-base-200"

  defp initial(name) when is_binary(name) and name != "",
    do: name |> String.first() |> String.upcase()

  defp initial(_name), do: "A"
end
