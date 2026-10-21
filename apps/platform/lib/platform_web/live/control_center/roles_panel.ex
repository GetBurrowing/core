defmodule PlatformWeb.ControlCenter.RolesPanel do
  @moduledoc """
  Function component for the Roles sub-view of the Agent Resources page
  (M7 stage 5 of task `019ef65c-87ba-7bff-9189-efe6039a0232`).

  Renders one row per platform-fixed role (4 today, per
  `Platform.Roles.Seeds`). Each row shows:

    * Role icon + name + description
    * The role's responsibility-bundle keys as small `<code>` chips
    * The assigned agent (avatar-ish dot + name + kind pill EXT/FED/LOC)
      OR — when unassigned — an `UNFILLED` badge with a `Fill role`
      button that deep-links into the External Agent onboarding flow
      (stage 6 wires the actual prefill).
    * A row of four cost-stat chips (runs / last / avg / $/run) which
      Decision 5 explicitly defers — these render literally as em-dash
      placeholders for now.

  The "Show advanced" toggle here only flips the assign; stage 6 owns
  the per-responsibility override surface that the flag reveals.
  """
  use Phoenix.Component

  import PlatformWeb.AvatarComponents, only: [agent_avatar: 1]

  alias PlatformWeb.ControlCenter.AgentData
  alias Platform.Access.Agents, as: AgentAccess

  attr(:roles, :list, required: true)
  attr(:role_bundles, :map, required: true)
  attr(:role_assignments_by_key, :map, required: true)
  attr(:show_role_advanced, :boolean, default: false)
  attr(:responsibility_rows, :list, default: [])
  attr(:selectable_agents, :list, default: [])
  attr(:access_scope, :any, default: nil)

  def panel(assigns) do
    ~H"""
    <div class="mx-auto flex w-full max-w-5xl flex-col gap-4 px-4 py-6 sm:px-6 sm:py-8">
      <header class="flex items-start justify-between gap-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
            Platform Roles
          </p>
          <p class="mt-1 text-sm text-base-content">
            Pin one agent per role. Each role bundles a fixed set of responsibilities.
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

      <%!-- Flat-role view (default) --%>
      <ul :if={!@show_role_advanced} class="flex flex-col gap-3">
        <li
          :for={role <- @roles}
          class="flex items-start gap-4 rounded-2xl border border-edge bg-base-100 px-4 py-4"
        >
          <span class={"#{role.icon} h-7 w-7 shrink-0 text-primary"} aria-hidden="true" />

          <div class="flex min-w-0 flex-1 flex-col gap-2">
            <div class="flex flex-col gap-0.5">
              <span class="text-base font-semibold text-base-content">{role.name}</span>
              <span class="text-xs text-subtle">{role.description}</span>
            </div>

            <div class="flex flex-wrap items-center gap-1.5">
              <code
                :for={key <- Map.get(@role_bundles, role.key, [])}
                class="rounded bg-base-200 px-1.5 py-0.5 text-xs font-mono text-base-content"
              >
                {key}
              </code>
            </div>

            <div class="mt-1 flex flex-wrap items-center gap-3 text-xs text-subtle">
              <span>runs —</span>
              <span>last —</span>
              <span>avg —</span>
              <span>$/run —</span>
            </div>
          </div>

          <div class="flex shrink-0 flex-col items-end gap-2">
            <.assignee_cell
              role_key={role.key}
              agent={Map.get(@role_assignments_by_key, role.key)}
              selectable_agents={@selectable_agents}
              access_scope={@access_scope}
            />
          </div>
        </li>
      </ul>

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
                  class="rounded bg-warning/15 px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-widest text-warning"
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

  attr(:role_key, :string, required: true)
  attr(:agent, :any, default: nil)
  attr(:selectable_agents, :list, default: [])
  attr(:access_scope, :any, default: nil)

  defp assignee_cell(%{agent: nil} = assigns) do
    ~H"""
    <span class="badge badge-warning gap-1">
      <span class="hero-exclamation-triangle h-3 w-3" /> UNFILLED
    </span>
    <form :if={@selectable_agents != []} phx-change="assign_role" class="flex items-center gap-2">
      <input type="hidden" name="role_key" value={@role_key} />
      <select
        name="agent_id"
        class="select select-bordered select-sm text-xs"
        aria-label={"Fill #{@role_key} with an agent"}
        data-role="fill-role-picker"
      >
        <option value="" selected>Choose an agent…</option>
        <option :for={agent <- @selectable_agents} value={agent.id}>
          {agent.name} ({AgentData.agent_kind_pill(agent)})
        </option>
        <option value="__new_external__">+ Create new external agent…</option>
      </select>
    </form>
    """
  end

  defp assignee_cell(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <%!-- Who holds this role. This drew `String.slice(name, 0, 2)` — TWO
           letters, the human-shaped treatment that splitting `agent_avatar/1`
           out of `human_avatar/1` exists to stop. `@agent` is a whole
           `%Agent{}` from `AgentData.list_selectable_agents/0`, so the avatar
           was one field read away. --%>
      <.agent_avatar
        name={@agent.name || "Agent"}
        avatar_url={@agent.avatar_url}
        size="md"
        class="shrink-0"
      />
      <div class="flex flex-col">
        <span class="text-sm font-semibold text-base-content">{@agent.name}</span>
        <span class={kind_pill_class(AgentData.agent_kind_pill(@agent))}>
          {AgentData.agent_kind_pill(@agent)}
        </span>
      </div>
      <button
        :if={AgentAccess.may_release?(@access_scope, @agent)}
        type="button"
        phx-click="clear_role_assignment"
        phx-value-role_key={@role_key}
        class="btn btn-ghost btn-xs font-medium text-base-content"
        aria-label={"Clear #{@role_key} assignment"}
        data-role="clear-role-btn"
      >
        Clear
      </button>
    </div>
    """
  end

  defp kind_pill_class("EXT"),
    do:
      "self-start rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-widest bg-purple-500/15 text-purple-700 dark:text-purple-300"

  defp kind_pill_class("FED"),
    do:
      "self-start rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-widest bg-info/15 text-info"

  defp kind_pill_class(_),
    do:
      "self-start rounded px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-widest bg-base-200 text-subtle"
end
