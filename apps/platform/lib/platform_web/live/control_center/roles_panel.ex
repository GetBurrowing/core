defmodule PlatformWeb.ControlCenter.RolesPanel do
  @moduledoc """
  Function component for the Roles sub-view of the Agent Resources page
  (M7 stage 5 of task `019ef65c-87ba-7bff-9189-efe6039a0232`; regrouped by
  holder in task `01a1b741` stage 4).

  Renders the 10 roles from `Platform.Roles.Seeds`, grouped by who holds them:

    * "Held by Burrow" first. Burrow holds every role no other agent holds, so
      on a fresh install every row sits here. Each row offers the
      "Hand to a specialist" picker (Burrow avatar, arrow, picker), which moves
      the role in one step through `Platform.Roles.reassign_role/3`
      (`hand_role` event). Burrow rows never offer Clear.
    * "Held by specialists", hidden when empty. Each row shows the holder and
      Clear, which hands the role straight back to Burrow.
    * "Not held by any agent", hidden when empty. Only reachable when no
      Burrow exists; the row offers the plain agent picker (`assign_role`).

  Each row shows the role icon (or a blank slot), the role name, its plain
  line from `Platform.Roles.plain_line/1` (the single copy) and the first two
  bundle keys plus "+N"; the full list is in Show advanced.

  A "Why add a specialist?" note sits once above the list when a Burrow
  exists, with a link that opens the owner's conversation with Burrow and
  pre-fills (never sends) a question about splitting roles.

  The "Show advanced" toggle reveals the per-responsibility override surface.
  """
  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias PlatformWeb.ControlCenter.AgentData
  alias Platform.Access.Agents, as: AgentAccess
  alias Platform.Roles

  attr(:roles, :list, required: true)
  attr(:role_bundles, :map, required: true)
  attr(:role_assignments_by_key, :map, required: true)
  attr(:show_role_advanced, :boolean, default: false)
  attr(:responsibility_rows, :list, default: [])
  attr(:selectable_agents, :list, default: [])
  attr(:access_scope, :any, default: nil)
  attr(:can_create_ownerless?, :boolean, default: false)
  attr(:burrow, :any, default: nil)

  def panel(assigns) do
    burrow_id = assigns.burrow && assigns.burrow.id

    groups =
      Enum.group_by(assigns.roles, fn role ->
        case Map.get(assigns.role_assignments_by_key, role.key) do
          nil -> :open
          %{id: ^burrow_id} when not is_nil(burrow_id) -> :burrow
          _ -> :specialist
        end
      end)

    specialists =
      Enum.reject(assigns.selectable_agents, &(burrow_id && &1.id == burrow_id))

    assigns =
      assigns
      |> assign(:burrow_roles, Map.get(groups, :burrow, []))
      |> assign(:specialist_roles, Map.get(groups, :specialist, []))
      |> assign(:open_roles, Map.get(groups, :open, []))
      |> assign(:specialists, specialists)
      |> assign(
        :may_hand_from_burrow?,
        assigns.burrow != nil and AgentAccess.may_release?(assigns.access_scope, assigns.burrow)
      )

    ~H"""
    <div
      id="roles-panel"
      class="mx-auto flex w-full max-w-5xl flex-col gap-4 px-4 py-6 sm:px-6 sm:py-8"
    >
      <header class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Platform Roles
          </p>
          <p class="mt-1 text-sm text-subtle" data-role="roles-subtitle">
            Each role is a set of recurring work. One agent holds each role.
          </p>
        </div>
      </header>

      <div role="tablist" class="tabs tabs-boxed mb-3 inline-flex self-start">
        <button
          type="button"
          role="tab"
          phx-click="switch_control_tab"
          phx-value-tab="roles"
          class="tab tab-active"
          aria-selected="true"
        >
          Roles ({length(@roles)})
        </button>
      </div>

      <%!-- Once above the list, never per row; no icon, no dismiss X. The
           outer base-100 layer plus the inner info/7 layer is "info mixed
           about 7% into base-100" without an arbitrary colour. --%>
      <aside
        :if={@burrow && !@show_role_advanced}
        id="roles-specialist-note"
        class="overflow-hidden rounded-xl border border-l-4 border-info-dim border-l-info bg-base-100"
      >
        <div class="flex flex-col gap-2 bg-info/7 px-4 py-3">
          <h2 class="text-[15px] font-semibold text-info">Why add a specialist?</h2>
          <p class="text-[13px] leading-[1.4] text-base-content">
            Burrow holds every role, so all of this work runs from day one. You can hand any role to a dedicated agent when it suits you. A specialist:
          </p>
          <ul class="ml-5 list-disc text-[13px] leading-[1.4] text-base-content">
            <li>can run a different model or tools</li>
            <li>keeps its context on one kind of work</li>
            <li>works at the same time as Burrow</li>
          </ul>
          <button
            type="button"
            id="ask-burrow-about-roles"
            phx-click="ask_burrow_about_roles"
            class="self-start text-[13px] font-semibold text-primary underline-offset-2 hover:underline focus-visible:underline"
          >
            Ask Burrow about splitting roles
          </button>
        </div>
      </aside>

      <div :if={!@show_role_advanced} class="flex flex-col gap-5">
        <section :if={@burrow_roles != []} id="roles-held-by-burrow" class="flex flex-col gap-3">
          <h3 class="flex items-center gap-2 font-mono text-[11px] text-subtle">
            <.agent_avatar
              name={@burrow.name || "Burrow"}
              avatar_url={@burrow.avatar_url}
              size="xs"
              fallback_class="bg-primary text-primary-content"
            />
            <span data-role="group-label">Held by Burrow</span>
          </h3>
          <ul class="flex flex-col gap-3">
            <.role_row
              :for={role <- @burrow_roles}
              role={role}
              holder="burrow"
              bundle={Map.get(@role_bundles, role.key, [])}
            >
              <.handover_control
                role={role}
                burrow={@burrow}
                specialists={@specialists}
                enabled?={@may_hand_from_burrow?}
                can_create_ownerless?={@can_create_ownerless?}
              />
            </.role_row>
          </ul>
        </section>

        <section
          :if={@specialist_roles != []}
          id="roles-held-by-specialists"
          class="flex flex-col gap-3"
        >
          <h3 class="font-mono text-[11px] text-subtle">
            <span data-role="group-label">Held by specialists</span>
          </h3>
          <ul class="flex flex-col gap-3">
            <.role_row
              :for={role <- @specialist_roles}
              role={role}
              holder="specialist"
              bundle={Map.get(@role_bundles, role.key, [])}
            >
              <.specialist_cell
                role_key={role.key}
                agent={Map.get(@role_assignments_by_key, role.key)}
                access_scope={@access_scope}
              />
            </.role_row>
          </ul>
        </section>

        <section :if={@open_roles != []} id="roles-not-held" class="flex flex-col gap-3">
          <h3 class="font-mono text-[11px] text-subtle">
            <span data-role="group-label">Not held by any agent</span>
          </h3>
          <ul class="flex flex-col gap-3">
            <.role_row
              :for={role <- @open_roles}
              role={role}
              holder="none"
              bundle={Map.get(@role_bundles, role.key, [])}
            >
              <.open_cell
                role_key={role.key}
                selectable_agents={@selectable_agents}
                can_create_ownerless?={@can_create_ownerless?}
              />
            </.role_row>
          </ul>
        </section>
      </div>

      <%!-- Show-advanced view: flat per-responsibility list with overrides --%>
      <section :if={@show_role_advanced} id="roles-advanced-panel" class="flex flex-col gap-3">
        <p class="text-xs text-subtle">
          Each responsibility routes via its role's assigned agent by default. A per-row override
          redirects only the work fired for that responsibility — it does not change which agent
          holds the role, so role-identity lookups (space membership, the wiki write-gate, and
          meeting scribe / triage attention dispatch) still resolve to the role's assigned agent.
        </p>

        <ul class="flex flex-col gap-2">
          <li
            :for={row <- @responsibility_rows}
            class="flex flex-col gap-2 rounded-xl border border-edge bg-base-100 px-3 py-2.5 sm:flex-row sm:items-center sm:gap-3"
          >
            <div class="flex min-w-0 flex-1 flex-col gap-1">
              <div class="flex flex-wrap items-center gap-2">
                <code class="rounded bg-base-200 px-1.5 py-0.5 text-xs font-mono text-base-content">
                  {row.responsibility_key}
                </code>
                <span class="text-xs text-subtle">
                  from <span class="font-medium text-base-content">{row.role_name}</span>
                </span>
                <span
                  :if={row.overridden?}
                  class="rounded bg-base-200 px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-widest text-base-content"
                >
                  OVERRIDE
                </span>
              </div>
              <div class="flex items-center gap-1.5 text-xs text-subtle">
                <%= if row.assignee do %>
                  <span class="hero-user-circle h-3.5 w-3.5" />
                  <span class="font-medium text-base-content">{row.assignee.name}</span>
                <% else %>
                  <span class="text-xs text-subtle">unassigned</span>
                <% end %>
              </div>
            </div>

            <div class="flex shrink-0 items-center gap-2">
              <form
                :if={is_nil(row.assignee) or AgentAccess.may_release?(@access_scope, row.assignee)}
                phx-change="set_responsibility_override"
                class="flex items-center gap-2"
              >
                <input
                  type="hidden"
                  name="responsibility_key"
                  value={row.responsibility_key}
                />
                <select
                  name="agent_id"
                  class="select select-bordered select-xs font-mono text-xs"
                  aria-label={"Override agent for #{row.responsibility_key}"}
                >
                  <option value="" selected={not row.overridden?}>use role default</option>
                  <option
                    :for={agent <- @selectable_agents}
                    value={agent.id}
                    selected={(row.overridden? and row.assignee) && row.assignee.id == agent.id}
                  >
                    {agent.name}
                  </option>
                </select>
              </form>
              <button
                :if={row.overridden? and AgentAccess.may_release?(@access_scope, row.assignee)}
                type="button"
                phx-click="clear_responsibility_override"
                phx-value-key={row.responsibility_key}
                class="btn btn-ghost btn-xs"
              >
                Clear
              </button>
            </div>
          </li>
        </ul>
      </section>

      <footer class="mt-2 flex items-center justify-end">
        <button
          type="button"
          phx-click="toggle_role_advanced"
          class="btn btn-ghost btn-sm gap-1 text-xs"
        >
          <span class="hero-adjustments-horizontal h-4 w-4" />
          {if @show_role_advanced, do: "Hide advanced", else: "Show advanced"}
        </button>
      </footer>
    </div>
    """
  end

  attr(:role, :map, required: true)
  attr(:holder, :string, required: true)
  attr(:bundle, :list, default: [])
  slot(:inner_block, required: true)

  # One role card. The leading slot holds the role's hero icon in
  # text-primary, or nothing at all when the role has no valid icon: never an
  # empty or outlined box (the designer's revision; a square reads as an
  # unchecked to-do). On phone the control wraps below the plain line, inside
  # the text column, so it is indented to the text.
  defp role_row(assigns) do
    {shown, rest} = Enum.split(assigns.bundle, 2)
    assigns = assign(assigns, shown_keys: shown, more_keys: length(rest))

    ~H"""
    <li
      id={"role-row-#{@role.key}"}
      data-role-key={@role.key}
      data-holder={@holder}
      class="flex items-start gap-4 rounded-2xl border border-edge bg-base-100 px-4 py-4"
    >
      <span data-role="role-leading-slot" class="flex h-7 w-7 shrink-0 items-center justify-center">
        <span
          :if={valid_icon?(@role.icon)}
          class={[@role.icon, "h-7 w-7 text-primary"]}
          aria-hidden="true"
        />
      </span>

      <div class="flex min-w-0 flex-1 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
        <div class="flex min-w-0 flex-col gap-1">
          <span class="text-[15px] font-semibold text-base-content">{@role.name}</span>
          <span data-role="role-plain-line" class="text-[13px] leading-[1.4] text-base-content">
            {Roles.plain_line(@role.key)}
          </span>
          <span
            :if={@shown_keys != []}
            data-role="role-bundle-keys"
            class="font-mono text-[11px] text-subtle"
          >
            {Enum.join(@shown_keys, " · ")}<span :if={@more_keys > 0}> · +{@more_keys}</span>
          </span>
        </div>

        <div class="flex shrink-0 items-center gap-2">
          {render_slot(@inner_block)}
        </div>
      </div>
    </li>
    """
  end

  # Role icons come from the database (`Platform.Roles.Seeds`), which Tailwind
  # does not scan, so an icon no other template uses never got its CSS and its
  # row painted a blank slot (hero-signal on Meeting Producer). Listing them
  # here is the safelist; RolesPanelBurrowTest keeps it in step with the seeds:
  # hero-paint-brush hero-book-open hero-signal hero-calendar-days
  # hero-clipboard-document-check hero-shield-check hero-cube-transparent
  # hero-flag hero-beaker hero-wrench-screwdriver
  defp valid_icon?("hero-" <> rest) when rest != "", do: true
  defp valid_icon?(_), do: false

  attr(:role, :map, required: true)
  attr(:burrow, :any, required: true)
  attr(:specialists, :list, default: [])
  attr(:enabled?, :boolean, default: false)
  attr(:can_create_ownerless?, :boolean, default: false)

  # The signature element: Burrow avatar, arrow, then the picker. Choosing an
  # agent fires `hand_role`, which moves the role in one step.
  defp handover_control(assigns) do
    ~H"""
    <form
      phx-change="hand_role"
      class="flex items-center gap-2"
      data-role="handover-control"
    >
      <input type="hidden" name="role_key" value={@role.key} />
      <.agent_avatar
        name={@burrow.name || "Burrow"}
        avatar_url={@burrow.avatar_url}
        size="sm"
        fallback_class="bg-primary text-primary-content"
      />
      <span class="hero-arrow-right h-4 w-4 text-primary" aria-hidden="true" />
      <select
        name="agent_id"
        disabled={!@enabled? or (@specialists == [] and !@can_create_ownerless?)}
        class="select select-sm min-h-11 rounded-lg border-primary bg-base-100 text-sm font-semibold text-primary sm:min-h-8"
        aria-label={"Hand #{@role.name} to a specialist"}
        data-role="hand-to-specialist-picker"
      >
        <option value="" selected>Hand to a specialist</option>
        <option :for={agent <- @specialists} value={agent.id}>{agent.name}</option>
        <option :if={@can_create_ownerless?} value="__new_external__">
          + Create new external agent…
        </option>
      </select>
    </form>
    """
  end

  attr(:role_key, :string, required: true)
  attr(:agent, :any, required: true)
  attr(:access_scope, :any, default: nil)

  defp specialist_cell(assigns) do
    ~H"""
    <div class="flex items-center gap-2" data-role="specialist-holder">
      <.agent_avatar
        name={@agent.name || "Agent"}
        avatar_url={@agent.avatar_url}
        size="sm"
        fallback_class="bg-base-300 text-base-content"
      />
      <span class="text-sm font-semibold text-base-content">{@agent.name}</span>
      <button
        :if={AgentAccess.may_release?(@access_scope, @agent)}
        type="button"
        phx-click="clear_role_assignment"
        phx-value-role_key={@role_key}
        class="btn btn-ghost btn-xs min-h-11 font-medium text-subtle sm:min-h-6"
        aria-label={"Clear #{@role_key} assignment"}
        data-role="clear-role-btn"
      >
        Clear
      </button>
    </div>
    """
  end

  attr(:role_key, :string, required: true)
  attr(:selectable_agents, :list, default: [])
  attr(:can_create_ownerless?, :boolean, default: false)

  defp open_cell(assigns) do
    ~H"""
    <form :if={@selectable_agents != []} phx-change="assign_role" class="flex items-center gap-2">
      <input type="hidden" name="role_key" value={@role_key} />
      <select
        name="agent_id"
        class="select select-bordered select-sm min-h-11 text-xs sm:min-h-8"
        aria-label={"Fill #{@role_key} with an agent"}
        data-role="fill-role-picker"
      >
        <option value="" selected>Choose an agent…</option>
        <option :for={agent <- @selectable_agents} value={agent.id}>
          {agent.name} ({AgentData.agent_kind_pill(agent)})
        </option>
        <%!-- Only for users who may create an ownerless agent (task 01a1ae4b). --%>
        <option :if={@can_create_ownerless?} value="__new_external__">
          + Create new external agent…
        </option>
      </select>
    </form>
    """
  end
end
