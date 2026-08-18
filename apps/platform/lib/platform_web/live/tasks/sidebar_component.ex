defmodule PlatformWeb.TasksLive.SidebarComponent do
  @moduledoc """
  Sidebar / Projects / Epics for `PlatformWeb.TasksLive`.

  Task 01a008f6 stage 2. This is the FIRST concern extracted from TasksLive,
  and deliberately so: it is the structural twin of ChatLive's SpaceNavigation,
  which was the one concern ADR-0035 left in the shell — after which
  `chat_live.ex` regrew 684 → 4,335 lines, almost entirely sidebar work
  deposited around the residual concern. Whatever large concern stays in a
  shell becomes the deposit site for all future work in its neighbourhood.
  Taking this one out first denies TasksLive that attractor.

  ## Shape

  A `Phoenix.LiveComponent` with its HEEx INLINE in `render/1` (binding
  template decision for every extraction stage of this task —
  `tasks_live.html.heex` remains the shell's composition template and
  shrinks; it is NOT split into a fan of partial `.heex` files).

  The component renders four of the five sidebar render regions in one
  tree: the desktop `<aside>`, the collapsed-sidebar reopen rail, the
  mobile `#project-sheet`, the `#epic-sheet` and the
  `#project-create-sheet`. The three sheets are `fixed`-positioned
  overlays, so hoisting them next to the aside changes nothing visually.

  The fifth region — the epics strip above the board — sits inside the
  board column's flow and cannot move into this tree without moving where
  it renders. It stays in the shell template for now and becomes
  `board_component.ex` markup in stage 7; its toggle button targets THIS
  component (see "Cross-concern ownership" below).

  ## Owned assigns (single writer: this component)

  `:sidebar_open`, `:projects_collapsed`, `:epics_collapsed`,
  `:show_project_sheet`, `:show_project_create_sheet`, `:project_form`,
  `:show_epic_sheet`, `:epic_form`.

  ## Read-only attrs (owned by the shell, never written here)

  `:project_sections`, `:projects_by_org`, `:orgs`, `:fabrikam_admin?`,
  `:lifecycle_menu_key`, `:selected_project_id`, `:selected_epic_id`,
  `:current_user_id`, `:current_user_record`.

  Per the ownership table fixed by this stage and binding on stages 3-7:
  selection state (`selected_project_id` / `selected_epic_id`, and
  `selected_task` for later stages) is shell-owned because it is
  URL/localStorage-driven, exactly the state ADR-0035 leaves in the shell.
  The directory maps (`project_sections`, `projects_by_org`, `orgs`) are
  shell-owned because four other concerns read them and none mutates them.
  Container lifecycle (`lifecycle_menu_key`, archive/delete) is stage 7's;
  its menu markup renders here but its events are untargeted and therefore
  reach the parent LiveView, which is where they still live. Because this
  component does not own the project directory, the lifecycle handlers
  cannot write sidebar state through the back door — the hazard the plan
  called for a PubSub notify to avoid simply does not arise.

  ## Events (all `sidebar_*`-prefixed, renamed at extraction time per
  ADR-0035 — no back-compat aliases, no separate mass-rename PR)

  `sidebar_toggle`, `sidebar_toggle_projects_section`,
  `sidebar_toggle_epics_panel`, `sidebar_select_project`,
  `sidebar_select_epic`, `sidebar_toggle_project_sheet`,
  `sidebar_close_project_sheet`, `sidebar_toggle_project_create_sheet`,
  `sidebar_close_project_create_sheet`, `sidebar_validate_project`,
  `sidebar_create_project`, `sidebar_toggle_epic_sheet`,
  `sidebar_close_epic_sheet`, `sidebar_validate_epic`,
  `sidebar_create_epic`.

  Trigger sites that live OUTSIDE this component's tree (the page-header
  create menu, the mobile create FAB, the epics-strip collapse button, and
  the `LastProject` JS hook) reach it with `phx-target="#tasks-sidebar"` /
  `pushEventTo`, which is why `render/1`'s root element always renders even
  when the sidebar is closed.

  ## Messages sent to the parent

    * `{:sidebar_project_selected, id | nil}` — parent sets
      `selected_project_id`, reloads epics, refreshes the board and pushes
      the corrected id back to `localStorage`
    * `{:sidebar_epic_selected, id | nil}` — parent sets `selected_epic_id`
      and refreshes the board
    * `{:sidebar_epics_collapsed, bool}` — parent mirrors the boolean so the
      board column can render the epics strip. Single writer stays here;
      the mirror becomes a plain attr when the Board component lands.
    * `{:sidebar_projects_changed}` — a project was created; parent re-fetches
      the directory maps it owns
    * `{:sidebar_epic_created}` — parent refreshes the board + epics list
    * `{:sidebar_close_create_menus}` — parent closes the header/FAB create
      menus so picking a menu item dismisses the menu server-side
    * `{:sidebar_flash, kind, msg}` — parent attaches a flash
  """

  use PlatformWeb, :live_component

  alias Platform.Accounts
  alias Platform.Tasks
  alias Platform.Tasks.{Epic, Project}
  alias Platform.Tenancy

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:sidebar_open, true)
     |> assign(:projects_collapsed, false)
     |> assign(:epics_collapsed, false)
     |> assign(:show_project_sheet, false)
     |> assign(:show_project_create_sheet, false)
     |> assign(:show_epic_sheet, false)
     |> assign(:epic_form, to_form(Epic.changeset(%Epic{}, %{}), as: "epic"))}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # The project form's org default depends on the viewer, which only
    # arrives with the first `update/2`. Build it once, then leave it to the
    # event handlers — rebuilding on every parent re-render would discard
    # whatever the user has typed into the open sheet.
    {:ok,
     assign_new(socket, :project_form, fn ->
       to_form(
         Project.changeset(
           %Project{},
           default_project_form_attrs(socket.assigns[:current_user_id])
         ),
         as: "project"
       )
     end)}
  end

  # ── Sidebar chrome ──────────────────────────────────────────────────────

  @impl true
  def handle_event("sidebar_toggle", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("sidebar_toggle_projects_section", _params, socket) do
    {:noreply, assign(socket, :projects_collapsed, !socket.assigns.projects_collapsed)}
  end

  # The epics strip renders in the board column, so the parent keeps a
  # read-only mirror of this boolean. This component stays the only writer.
  def handle_event("sidebar_toggle_epics_panel", _params, socket) do
    collapsed = !socket.assigns.epics_collapsed
    send(self(), {:sidebar_epics_collapsed, collapsed})
    {:noreply, assign(socket, :epics_collapsed, collapsed)}
  end

  # ── Selection (requested from the parent, never written here) ───────────

  def handle_event("sidebar_select_project", %{"id" => project_id}, socket) do
    send(self(), {:sidebar_project_selected, project_id})
    {:noreply, assign(socket, :show_project_sheet, false)}
  end

  def handle_event("sidebar_select_epic", %{"id" => epic_id}, socket) do
    send(self(), {:sidebar_epic_selected, epic_id})
    {:noreply, socket}
  end

  # ── Mobile project filter sheet ─────────────────────────────────────────

  def handle_event("sidebar_toggle_project_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_sheet, !socket.assigns.show_project_sheet)}
  end

  def handle_event("sidebar_close_project_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_sheet, false)}
  end

  # ── New-Project bottom sheet (ADR-0042 stage 5) ─────────────────────────

  def handle_event("sidebar_toggle_project_create_sheet", _params, socket) do
    showing = !socket.assigns.show_project_create_sheet
    send(self(), {:sidebar_close_create_menus})

    socket =
      if showing do
        socket
        |> assign(:show_project_create_sheet, true)
        |> assign(:project_form, blank_project_form(socket))
      else
        assign(socket, :show_project_create_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("sidebar_close_project_create_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_create_sheet, false)}
  end

  def handle_event("sidebar_validate_project", %{"project" => params}, socket) do
    changeset =
      %Project{}
      |> Project.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :project_form, to_form(changeset, as: "project"))}
  end

  def handle_event("sidebar_create_project", %{"project" => params}, socket) do
    case Tasks.create_project(params) do
      {:ok, _project} ->
        # No board-level pubsub for projects yet — the parent owns the
        # directory maps and re-fetches them on this notify.
        send(self(), {:sidebar_projects_changed})
        send(self(), {:sidebar_flash, :info, "Project created."})

        {:noreply,
         socket
         |> assign(:show_project_create_sheet, false)
         |> assign(:project_form, blank_project_form(socket))}

      {:error, changeset} ->
        send(
          self(),
          {:sidebar_flash, :error, "Could not create project. Check the form for errors."}
        )

        {:noreply, assign(socket, :project_form, to_form(changeset, as: "project"))}
    end
  end

  # ── New-Epic bottom sheet ───────────────────────────────────────────────

  def handle_event("sidebar_toggle_epic_sheet", _params, socket) do
    showing = !socket.assigns.show_epic_sheet
    send(self(), {:sidebar_close_create_menus})

    socket =
      if showing do
        socket
        |> assign(:show_epic_sheet, true)
        |> assign(:epic_form, blank_epic_form(socket))
      else
        assign(socket, :show_epic_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("sidebar_close_epic_sheet", _params, socket) do
    {:noreply, assign(socket, :show_epic_sheet, false)}
  end

  def handle_event("sidebar_validate_epic", %{"epic" => params}, socket) do
    changeset =
      %Epic{}
      |> Epic.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :epic_form, to_form(changeset, as: "epic"))}
  end

  def handle_event("sidebar_create_epic", %{"epic" => params}, socket) do
    # Pin project_id when the board is filtered; users picking from the
    # filtered view shouldn't have to re-select it. The form hides the
    # select in that mode, so without this merge the param would be missing.
    attrs =
      case socket.assigns.selected_project_id do
        nil -> params
        id -> Map.put_new(params, "project_id", id)
      end

    case Tasks.create_epic(attrs) do
      {:ok, _epic} ->
        # create_epic/1 already broadcasts {:epic_created, epic}; the parent
        # re-fetches on this notify for immediacy rather than waiting on it.
        send(self(), {:sidebar_epic_created})
        send(self(), {:sidebar_flash, :info, "Epic created."})
        {:noreply, assign(socket, :show_epic_sheet, false)}

      {:error, changeset} ->
        send(
          self(),
          {:sidebar_flash, :error, "Could not create epic. Check the form for errors."}
        )

        {:noreply, assign(socket, :epic_form, to_form(changeset, as: "epic"))}
    end
  end

  # ── Form defaults ───────────────────────────────────────────────────────

  defp blank_epic_form(socket) do
    attrs =
      case socket.assigns[:selected_project_id] do
        nil -> %{}
        id -> %{"project_id" => id}
      end

    to_form(Epic.changeset(%Epic{}, attrs), as: "epic")
  end

  defp blank_project_form(socket) do
    to_form(
      Project.changeset(
        %Project{},
        default_project_form_attrs(socket.assigns[:current_user_id])
      ),
      as: "project"
    )
  end

  # Stage 5 of ADR-0042: pre-populate the New-Project form's org select
  # with the current user's primary membership's org (via
  # `Tenancy.load_membership/1`). Falls back to the Fabrikam root org when no
  # membership exists yet — matches `Tasks.create_project/1`'s server-side
  # default and keeps the form usable for fresh accounts.
  defp default_project_form_attrs(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        fabrikam_default_attrs()

      user ->
        case Tenancy.load_membership(user) do
          %{org: %Tenancy.Org{id: org_id}} -> %{"org_id" => org_id}
          _ -> fabrikam_default_attrs()
        end
    end
  end

  defp default_project_form_attrs(_), do: fabrikam_default_attrs()

  defp fabrikam_default_attrs do
    case Tenancy.get_org_by_slug("fabrikam") do
      %Tenancy.Org{id: id} -> %{"org_id" => id}
      _ -> %{}
    end
  end

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Desktop sidebar --%>
      <aside
        :if={@sidebar_open}
        class="hidden w-56 shrink-0 flex-col border-r border-base-300 bg-base-100 md:flex"
      >
        <div class="flex items-center justify-between border-b border-base-300 px-3 py-3">
          <span class="text-xs font-semibold uppercase tracking-widest text-base-content/60">
            Projects
          </span>
          <div class="flex items-center gap-1">
            <.section_add_button
              phx-click="sidebar_toggle_project_create_sheet"
              phx-target={@myself}
              aria_label="New project"
              data-role="project-create-trigger"
            />
            <button
              phx-click="sidebar_toggle_projects_section"
              phx-target={@myself}
              class="btn btn-ghost btn-xs btn-square"
              title={if @projects_collapsed, do: "Expand projects", else: "Collapse projects"}
            >
              <span class={"size-4 transition-transform #{if @projects_collapsed, do: "hero-chevron-down", else: "hero-chevron-up"}"}>
              </span>
            </button>
            <button
              phx-click="sidebar_toggle"
              phx-target={@myself}
              class="btn btn-ghost btn-xs btn-square"
              title="Close sidebar"
            >
              <span class="hero-chevron-left size-4"></span>
            </button>
          </div>
        </div>

        <%!-- Stage 5 of ADR-0042: project picker grouped by org via collapsible
             <details> sections. Fabrikam first (root), then tenant orgs alphabetically.
             Header carries the scope color dot (Tenancy.scope_color/1, pure +
             DB-free) so users see at a glance which org a section belongs to. --%>
        <div :if={!@projects_collapsed} class="flex-1 overflow-y-auto">
          <details
            :for={{org_slug, _org_name, org_projects} <- @project_sections}
            open
            class="group relative"
            data-role="project-group"
            data-org-slug={org_slug}
          >
            <summary class={[
              "flex items-center gap-2 px-3 py-2 text-xs font-semibold uppercase tracking-widest text-base-content/60 hover:bg-base-200 cursor-pointer select-none",
              (@fabrikam_admin and org_slug not in ["fabrikam", "_unassigned"]) && "pr-9"
            ]}>
              <span class={"size-2 rounded-full bg-current #{Tenancy.scope_color(org_slug)}"}></span>
              <span>{Tenancy.scope_label(org_slug)}</span>
              <span class="ml-auto text-[10px] tracking-normal text-base-content/40">
                {length(org_projects)}
              </span>
            </summary>
            <%!-- Org kebab: a sibling of <summary> (NOT a descendant) positioned
                 over the row's right edge, so clicking it opens the lifecycle
                 menu without toggling the native <details>. Root org (Fabrikam) is
                 never offered — the lifecycle refuses it.

                 Container lifecycle is stage 7's concern: these controls carry
                 NO phx-target, so their events reach the parent LiveView, which
                 still owns them and the directory maps they refresh. --%>
            <.lifecycle_menu
              :if={@fabrikam_admin and org_slug not in ["fabrikam", "_unassigned"]}
              key={"org:#{org_slug}"}
              open={@lifecycle_menu_key == "org:#{org_slug}"}
              type="org"
              id={org_slug}
              name={Tenancy.scope_label(org_slug)}
              class="absolute right-1 top-1.5"
            />
            <div
              :for={project <- org_projects}
              class="group/proj relative flex items-center hover:bg-base-200"
            >
              <button
                phx-click="sidebar_select_project"
                phx-target={@myself}
                phx-value-id={project.id}
                class={"min-w-0 flex-1 text-left px-5 py-2 text-sm truncate #{if @selected_project_id == project.id, do: "bg-base-200 font-medium"}"}
              >
                {project.name}
              </button>
              <.lifecycle_menu
                :if={@fabrikam_admin}
                key={"project:#{project.id}"}
                open={@lifecycle_menu_key == "project:#{project.id}"}
                type="project"
                id={project.id}
                name={project.name}
                class="relative pr-2 opacity-0 focus-within:opacity-100 group-hover/proj:opacity-100"
              />
            </div>
          </details>
        </div>

        <div class="border-t border-base-300 p-2">
          <button
            phx-click="filter_clear"
            phx-target="#tasks-filters"
            class="btn btn-xs btn-ghost w-full"
          >
            All Projects
          </button>
        </div>
      </aside>

      <%!-- Sidebar collapsed toggle (desktop) --%>
      <button
        :if={!@sidebar_open}
        phx-click="sidebar_toggle"
        phx-target={@myself}
        class="hidden md:flex items-center justify-center w-6 shrink-0 border-r border-base-300 hover:bg-base-200"
        title="Expand sidebar"
      >
        <span class="hero-chevron-right size-4 text-base-content/50"></span>
      </button>

      <%!-- Mobile project filter sheet (task 019e0d4b stage 3 sub a). Slides
           in from the left on mobile, hidden entirely on md+ where the project
           filter lives in a different surface. --%>
      <.sheet
        id="project-sheet"
        open={@show_project_sheet}
        placement={:left}
        on_close="sidebar_close_project_sheet"
        on_close_target={@myself}
        class="md:hidden"
      >
        <:title>Projects</:title>
        <%!-- Stage 5 of ADR-0042: grouped by org with the same <details> shape
             as the desktop sidebar so the mobile sheet stays visually consistent. --%>
        <div class="flex flex-col">
          <details
            :for={{org_slug, _org_name, org_projects} <- @project_sections}
            open
            class="relative"
            data-role="project-group"
            data-org-slug={org_slug}
          >
            <summary class={[
              "flex items-center gap-2 px-3 py-2 text-xs font-semibold uppercase tracking-widest text-base-content/60 cursor-pointer select-none",
              (@fabrikam_admin and org_slug not in ["fabrikam", "_unassigned"]) && "pr-9"
            ]}>
              <span class={"size-2 rounded-full bg-current #{Tenancy.scope_color(org_slug)}"}></span>
              <span>{Tenancy.scope_label(org_slug)}</span>
              <span class="ml-auto text-[10px] tracking-normal text-base-content/40">
                {length(org_projects)}
              </span>
            </summary>
            <%!-- Mobile org kebab: same lifecycle_menu + events as the desktop
                 sidebar, keyed with a `mobile-` prefix so its open-state never
                 collides with the desktop menu's data-menu-key in the DOM.
                 Positioned sibling of <summary> so a tap opens the menu without
                 toggling the native <details>. Root org (Fabrikam) is never offered. --%>
            <.lifecycle_menu
              :if={@fabrikam_admin and org_slug not in ["fabrikam", "_unassigned"]}
              key={"mobile-org:#{org_slug}"}
              open={@lifecycle_menu_key == "mobile-org:#{org_slug}"}
              type="org"
              id={org_slug}
              name={Tenancy.scope_label(org_slug)}
              class="absolute right-1 top-1.5"
            />
            <div
              :for={project <- org_projects}
              class="relative flex items-center hover:bg-base-200"
            >
              <button
                phx-click="sidebar_select_project"
                phx-target={@myself}
                phx-value-id={project.id}
                class={"min-w-0 flex-1 text-left px-5 py-2 text-sm truncate #{if @selected_project_id == project.id, do: "bg-base-200 font-medium"}"}
              >
                {project.name}
              </button>
              <%!-- Kebab stays visible on touch (no hover reveal like desktop). --%>
              <.lifecycle_menu
                :if={@fabrikam_admin}
                key={"mobile-project:#{project.id}"}
                open={@lifecycle_menu_key == "mobile-project:#{project.id}"}
                type="project"
                id={project.id}
                name={project.name}
                class="relative pr-2"
              />
            </div>
          </details>
        </div>
        <:actions>
          <button
            phx-click="filter_clear"
            phx-target="#tasks-filters"
            class="btn btn-xs btn-ghost w-full"
          >
            All Projects
          </button>
        </:actions>
      </.sheet>

      <%!-- New-epic sheet (task 019d60ca stage 3). Mirrors the new-task sheet
           wrapper styling so the mobile bottom-sheet pattern stays consistent
           (env(safe-area-inset-bottom) padding, max-h-75vh scroll, rounded-t-2xl
           drawer card). The form is intentionally smaller than tasks: epics are
           containers with no agent / plan / validation knobs at create time. --%>
      <.sheet
        :if={@show_epic_sheet}
        id="epic-sheet"
        open={true}
        placement={:bottom}
        on_close="sidebar_close_epic_sheet"
        on_close_target={@myself}
      >
        <:title>New Epic</:title>
        <.form
          for={@epic_form}
          id="create-epic-form"
          phx-change="sidebar_validate_epic"
          phx-submit="sidebar_create_epic"
          phx-target={@myself}
          class="form-fields space-y-4"
        >
          <%!-- Name --%>
          <.input
            field={@epic_form[:name]}
            label="Name"
            required
            placeholder="Mobile redesign"
          />

          <%!-- Project. When the board is filtered to a single project we hide
               the picker entirely and pin via a hidden input — matches Rowan's
               brief and removes a redundant click. Otherwise show a select. --%>
          <%= if @selected_project_id do %>
            <input type="hidden" name="epic[project_id]" value={@selected_project_id} />
          <% else %>
            <div>
              <label class="label label-text text-xs font-medium">Project *</label>
              <select
                name="epic[project_id]"
                class="select select-bordered w-full"
                required
              >
                <option value="">Select project</option>
                <%!-- Stage 5 of ADR-0042: group by owning org via <optgroup>. --%>
                <optgroup
                  :for={{org_slug, _org_name, org_projects} <- @projects_by_org}
                  label={Tenancy.scope_label(org_slug)}
                >
                  <option
                    :for={project <- org_projects}
                    value={project.id}
                    selected={@epic_form[:project_id].value == project.id}
                  >
                    {project.name}
                  </option>
                </optgroup>
              </select>
              <p
                :for={msg <- Enum.map(@epic_form[:project_id].errors, &translate_error/1)}
                class="mt-1 text-xs text-error"
              >
                {msg}
              </p>
            </div>
          <% end %>

          <%!-- Description (optional) --%>
          <.input
            field={@epic_form[:description]}
            type="textarea"
            kind={:auto_resize}
            label="Description"
            placeholder="What is this epic about?"
          />

          <%!-- Acceptance criteria (optional) --%>
          <.input
            field={@epic_form[:acceptance_criteria]}
            type="textarea"
            kind={:auto_resize}
            label="Acceptance criteria"
            placeholder="How will we know this epic is done?"
          />

          <%!-- Target branch (optional) --%>
          <.input
            field={@epic_form[:target_branch]}
            label="Target branch"
            placeholder="main"
          />

          <%!-- Deploy target (optional) --%>
          <.input
            field={@epic_form[:deploy_target]}
            label="Deploy target"
            placeholder="staging"
          />

          <%!-- Submit + Cancel --%>
          <div class="flex gap-2 pt-2">
            <button
              type="button"
              phx-click="sidebar_close_epic_sheet"
              phx-target={@myself}
              class="btn btn-ghost btn-sm flex-1"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm flex-1"
            >
              Create Epic
            </button>
          </div>
        </.form>
      </.sheet>

      <%!-- New-Project sheet (ADR-0042 stage 5). Mirrors the New-Epic sheet's
           shape: bottom drawer on mobile, modal on desktop (the `.sheet`
           component handles the responsive split). The form requires org_id;
           defaults to the current user's primary membership's org, else Fabrikam. --%>
      <.sheet
        :if={@show_project_create_sheet}
        id="project-create-sheet"
        open={true}
        placement={:bottom}
        on_close="sidebar_close_project_create_sheet"
        on_close_target={@myself}
      >
        <:title>New Project</:title>
        <.form
          for={@project_form}
          id="create-project-form"
          phx-change="sidebar_validate_project"
          phx-submit="sidebar_create_project"
          phx-target={@myself}
          class="form-fields space-y-4"
          data-role="project-create-form"
        >
          <%!-- Name --%>
          <.input
            field={@project_form[:name]}
            label="Name"
            required
            placeholder="Storefront"
          />

          <%!-- Slug (optional — auto-derived from name when blank) --%>
          <div>
            <.input
              field={@project_form[:slug]}
              label="Slug"
              placeholder="storefront"
            />
            <p class="mt-1 text-xs text-base-content/40">
              Leave blank to auto-derive from name.
            </p>
          </div>

          <%!-- Org (required per ADR-0042). --%>
          <div>
            <label class="label label-text text-xs font-medium">Org *</label>
            <select
              name="project[org_id]"
              class="select select-bordered w-full"
              required
              data-role="project-create-org-select"
            >
              <option value="">Select org</option>
              <option
                :for={org <- @orgs}
                value={org.id}
                selected={@project_form[:org_id].value == org.id}
              >
                {Tenancy.scope_label(org.slug)}
              </option>
            </select>
            <p
              :for={msg <- Enum.map(@project_form[:org_id].errors, &translate_error/1)}
              class="mt-1 text-xs text-error"
            >
              {msg}
            </p>
          </div>

          <%!-- Submit + Cancel --%>
          <div class="flex gap-2 pt-2">
            <button
              type="button"
              phx-click="sidebar_close_project_create_sheet"
              phx-target={@myself}
              class="btn btn-ghost btn-sm flex-1"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary btn-sm flex-1"
            >
              Create Project
            </button>
          </div>
        </.form>
      </.sheet>
    </div>
    """
  end
end
