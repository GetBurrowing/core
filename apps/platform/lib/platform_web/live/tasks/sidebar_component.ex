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

  `:project_sections`, `:projects_by_org`, `:orgs`, `:root_admin?`,
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

  ## Read-only masking attrs (task 01a00cf1 stage 2)

  `mask_names?`, `revealed_rail_ids` and `mask_labels` arrive as ATTRS and are
  never written here. The shell owns them, and the three controls this
  component renders for them (`toggle_mask_names`, `reveal_rail_item`,
  `remask_all`) carry NO `phx-target` so their events reach the shell — the
  same arrangement the org lifecycle controls already use.

  `mask_labels` is precomputed by `LifecycleHooks.assign_mask_labels/1` on the
  same pass that assigns `project_sections`. No render site in this module may
  call `Platform.Chat.SidebarMask` or `Tenancy.scope_label/1` for a rail row:
  one resolved string per entity is what keeps the attribute surface and the
  text surface from disagreeing.

  Stage 3 carried the same treatment into the mobile `#project-sheet` (rows,
  `data-org-slug`, both `lifecycle_menu` names, per-item reveals AND the mode
  strip — the state, not only its effect), and into the two `<optgroup>`-bearing
  project pickers plus the project-create sheet's org `<select>`. The
  `project[name]` input in that sheet is NOT masked and never should be: it is
  the user's own keystrokes, not a name the app is putting on screen.

  Surfaces this component does NOT mask: none remain. The breadcrumb and the
  scope-rail chips live in `PlatformWeb.Tasks.FiltersComponent`; task titles and
  epic names on the board are free text and are out of the feature's scope
  entirely.
  """

  use PlatformWeb, :live_component

  alias Platform.Accounts
  alias Platform.Tasks
  alias Platform.Tasks.{Epic, Project}
  alias Platform.Tenancy
  alias PlatformWeb.Tasks.TaskDisplay

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
    socket =
      socket
      |> assign(assigns)
      # Resolved ONCE per component lifetime, not per rendered org row:
      # `Tenancy.root_org_slug/0` may fall back to a DB read of the root org.
      |> assign_new(:root_org_slug, fn -> Tenancy.root_org_slug() end)

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
    case create_project(socket, params) do
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

    case create_epic(socket, attrs) do
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

  # ── Fenced creates (task 01a1472d stage 1) ──────────────────────────────
  #
  # The org and project ids arrive from the form, so a forged submit can name
  # any of them. A target the viewer may not `tasks.write` gets the
  # changeset a nonexistent id gets (the foreign-key "does not exist" error),
  # so the flash and the form read exactly as they do for a random UUID, and
  # nothing is inserted.

  defp create_project(socket, params) do
    if project_org_permitted?(socket, params),
      do: Tasks.create_project(params),
      else: {:error, refused(Project.changeset(%Project{}, params), :org_id)}
  end

  # A fenced viewer must NAME an org inside the fence: `Tasks.create_project/1`
  # defaults a missing `org_id` to the root org. Unfenced viewers keep that
  # default, unchanged.
  defp project_org_permitted?(socket, params) do
    case {blank_to_nil(params["org_id"]), socket.assigns[:access_scope]} do
      {nil, %Platform.Access.Scope{} = scope} -> Platform.Access.org_fence(scope) == :unfenced
      {nil, _no_scope} -> true
      {org_id, _} -> PlatformWeb.Tasks.Selection.permits?(socket, {:org, org_id})
    end
  end

  defp create_epic(socket, attrs) do
    case blank_to_nil(attrs["project_id"]) do
      nil ->
        Tasks.create_epic(attrs)

      project_id ->
        if PlatformWeb.Tasks.Selection.permits?(socket, {:project, project_id}),
          do: Tasks.create_epic(attrs),
          else: {:error, refused(Epic.changeset(%Epic{}, attrs), :project_id)}
    end
  end

  defp refused(changeset, field) do
    changeset
    |> Ecto.Changeset.add_error(field, "does not exist", constraint: :foreign)
    |> Map.put(:action, :insert)
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

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
  # `Tenancy.load_membership/1`). Falls back to the root org when no
  # membership exists yet — matches `Tasks.create_project/1`'s server-side
  # default and keeps the form usable for fresh accounts.
  defp default_project_form_attrs(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      nil ->
        root_default_attrs()

      user ->
        case Tenancy.load_membership(user) do
          %{org: %Tenancy.Org{id: org_id}} -> %{"org_id" => org_id}
          _ -> root_default_attrs()
        end
    end
  end

  defp default_project_form_attrs(_), do: root_default_attrs()

  defp root_default_attrs do
    case Tenancy.get_root_org() do
      %Tenancy.Org{id: id} -> %{"org_id" => id}
      _ -> %{}
    end
  end

  # Right padding for an org <summary>: one class covering however many
  # absolutely-positioned controls overlay the row's right edge (the lifecycle
  # kebab, the per-item reveal, both, or neither).
  defp summary_pad(true, true), do: "pr-16"
  defp summary_pad(true, false), do: "pr-9"
  defp summary_pad(false, true), do: "pr-9"
  defp summary_pad(false, false), do: nil

  # ── Render ──────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Desktop sidebar --%>
      <aside
        :if={@sidebar_open}
        class="hidden w-56 shrink-0 flex-col border-r border-edge bg-base-100 md:flex"
      >
        <div class="flex items-center justify-between border-b border-edge px-3 py-3">
          <span class="text-xs font-semibold uppercase tracking-widest text-base-content/60">
            Projects
          </span>
          <div class="flex items-center gap-1">
            <%!-- Screen-share name masking (task 01a00cf1 stage 2). NO
                 phx-target: the shell owns the state, matching the org
                 lifecycle controls below. Posts the DESIRED next state rather
                 than a flip, so a duplicated event from a render race is
                 idempotent.

                 EYE ONLY. No padlock and no shield anywhere in this feature —
                 an icon would make the same overclaim the forbidden words
                 would (this is a presentation aid, not a security control).
                 The icon swap is deliberately NOT the feature's signal; the
                 mode strip below is. --%>
            <button
              type="button"
              phx-click="toggle_mask_names"
              phx-value-masked={to_string(!@mask_names?)}
              class="channel-mask-toggle"
              aria-pressed={to_string(@mask_names?)}
              aria-label="Hide workspace names for sharing"
              data-role="rail-mask-toggle"
            >
              <span
                class={[if(@mask_names?, do: "hero-eye-slash", else: "hero-eye"), "size-4"]}
                aria-hidden="true"
              >
              </span>
            </button>
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
             <details> sections. The root org first, then tenant orgs alphabetically.
             Header carries the scope color dot (Tenancy.scope_color/1, pure +
             DB-free) so users see at a glance which org a section belongs to. --%>
        <%!-- Mode strip (task 01a00cf1 stage 2). THE STRIP IS THE SIGNAL, NOT
             THE ICON STATE: an eye and a crossed-out eye differ by a few
             pixels of stroke, read in a half-second glance while a share
             dialog is going up. `.channel-mask-strip` wraps rather than
             truncates — chat found the single-line form clipped to "Names
             hidden for s…" at rail width, and a truncated mode label is worse
             than none. Copy is about PRESENTING, never privacy. --%>
        <div :if={@mask_names?} class="channel-mask-strip" data-role="rail-mask-strip">
          <span class="hero-eye-slash size-3.5 flex-shrink-0" aria-hidden="true"></span>
          <span class="min-w-0 flex-1">
            {if MapSet.size(@revealed_rail_ids) > 0,
              do: "Names hidden · #{MapSet.size(@revealed_rail_ids)} showing",
              else: "Names hidden for sharing"}
          </span>
          <button
            type="button"
            phx-click="remask_all"
            class="channel-mask-strip-action"
            data-role="rail-mask-remask-all"
          >
            Show all
          </button>
        </div>

        <div :if={!@projects_collapsed} class="flex-1 overflow-y-auto">
          <%!-- Every name-bearing surface on these rows reads @mask_labels via
               TaskDisplay.rail_label/2 — never Tenancy.scope_label/1 or
               project.name directly, and never SidebarMask itself. One
               resolved string per entity, so the attribute surface and the
               text surface cannot disagree. That divergence is the defect that
               cost the sibling task 01a00c66 a full review cycle.

               THE ORG ROW'S FOUR ROUTING ATTRIBUTES FOLLOW THE LABEL TOO —
               `phx-value-id` on the reveal button, `phx-value-key` /
               `data-menu-key` on the kebab. Each carried `soylent` verbatim
               under a row reading `Workspace B`, which is the one surface left
               in this feature routing by a human-readable name: project rows
               have keyed by UUID all along. They now carry the per-session
               placeholder slug out of the same map, and the handlers resolve
               it with `TaskDisplay.real_org_slug/2` before acting.

               `Tenancy.scope_color/1` DELIBERATELY keeps the real slug: it
               produces a CSS utility class and no name. Class names cannot be
               regenerated per session, they are invisible on a screen share,
               and `Platform.MaskAssertions` excludes `class` for exactly that
               reason. This is a named limitation, not a miss. --%>
          <details
            :for={{org_slug, _org_name, org_projects} <- @project_sections}
            open
            class="group relative"
            data-role="project-group"
            data-org-slug={TaskDisplay.rail_org_slug(@mask_labels, org_slug)}
          >
            <summary class={
              [
                "flex items-center gap-2 px-3 py-2 text-xs font-semibold uppercase tracking-widest text-base-content/60 hover:bg-base-200 cursor-pointer select-none",
                # ONE padding class, never two: `["pr-9", "pr-16"]` both land in
                # the attribute and which wins is Tailwind's stylesheet order,
                # not the list's — the row's padding would be decided somewhere
                # other than here. Kebab and reveal each claim a slot; the row
                # reserves exactly as many as it renders.
                summary_pad(
                  @root_admin? and org_slug not in [@root_org_slug, "_unassigned"],
                  @mask_names? and not MapSet.member?(@revealed_rail_ids, org_slug)
                )
              ]
            }>
              <span
                class={"size-2 rounded-full scope-dot-current #{Tenancy.scope_color(org_slug)}"}
                data-scope={
                  if(@mask_names? and not MapSet.member?(@revealed_rail_ids, org_slug),
                    do: nil,
                    else: org_slug
                  )
                }
              >
              </span>
              <span>{TaskDisplay.rail_label(@mask_labels, {:org, org_slug})}</span>
              <span class="ml-auto text-[10px] tracking-normal text-base-content/40">
                {length(org_projects)}
              </span>
            </summary>
            <%!-- Per-item reveal for the org row. A SIBLING of <summary>, not a
                 descendant, for the same reason the kebab beside it is one: a
                 button inside <summary> toggles the native <details> on click,
                 so revealing a name would also collapse the section.

                 ALWAYS IN THE DOM while this row is masked, never hover-gated.
                 `@media (hover: hover)` never matches on a touch device and a
                 hover affordance would vanish there entirely. Offset left of
                 the kebab's slot when the kebab is also rendered. --%>
            <button
              :if={@mask_names? and not MapSet.member?(@revealed_rail_ids, org_slug)}
              type="button"
              class={[
                "channel-section-reveal-button absolute top-1.5",
                if(@root_admin? and org_slug not in [@root_org_slug, "_unassigned"],
                  do: "right-8",
                  else: "right-1"
                )
              ]}
              phx-click="reveal_rail_item"
              phx-value-kind="org"
              phx-value-id={TaskDisplay.rail_org_slug(@mask_labels, org_slug)}
              aria-label="Show this workspace name"
              data-role="rail-reveal-org"
            >
              <span class="hero-eye size-3.5" aria-hidden="true"></span>
            </button>
            <%!-- Org kebab: a sibling of <summary> (NOT a descendant) positioned
                 over the row's right edge, so clicking it opens the lifecycle
                 menu without toggling the native <details>. The root org is
                 never offered — the lifecycle refuses it.

                 Container lifecycle is stage 7's concern: these controls carry
                 NO phx-target, so their events reach the parent LiveView, which
                 still owns them and the directory maps they refresh. --%>
            <.lifecycle_menu
              :if={@root_admin? and org_slug not in [@root_org_slug, "_unassigned"]}
              key={"org:#{TaskDisplay.rail_org_slug(@mask_labels, org_slug)}"}
              open={@lifecycle_menu_key == "org:#{TaskDisplay.rail_org_slug(@mask_labels, org_slug)}"}
              type="org"
              id={TaskDisplay.rail_org_slug(@mask_labels, org_slug)}
              name={TaskDisplay.rail_label(@mask_labels, {:org, org_slug})}
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
                {TaskDisplay.rail_label(@mask_labels, {:project, project.id})}
              </button>
              <%!-- Per-item reveal for a project row. In normal flow here (not
                   absolutely positioned): this row is a <div>, so a nested
                   button has no <details> to toggle. --%>
              <button
                :if={@mask_names? and not MapSet.member?(@revealed_rail_ids, project.id)}
                type="button"
                class="channel-section-reveal-button mr-1"
                phx-click="reveal_rail_item"
                phx-value-kind="project"
                phx-value-id={project.id}
                aria-label="Show this project name"
                data-role="rail-reveal-project"
              >
                <span class="hero-eye size-3.5" aria-hidden="true"></span>
              </button>
              <%!-- A DERIVED-STRING LEAK if it took `project.name`: the menu
                   renders `name` into `aria-label`, the menu's own
                   `aria-label`, `phx-value-name` and from there the confirm
                   modal and the flash. It takes the RESOLVED label. --%>
              <.lifecycle_menu
                :if={@root_admin?}
                key={"project:#{project.id}"}
                open={@lifecycle_menu_key == "project:#{project.id}"}
                type="project"
                id={project.id}
                name={TaskDisplay.rail_label(@mask_labels, {:project, project.id})}
                class="relative pr-2 opacity-0 focus-within:opacity-100 group-hover/proj:opacity-100"
              />
            </div>
          </details>
        </div>

        <div class="border-t border-edge p-2">
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
        class="hidden md:flex items-center justify-center w-6 shrink-0 border-r border-edge hover:bg-base-200"
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
        <%!-- THE MODE STRIP RENDERS HERE TOO (task 01a00cf1 stage 3), not only
             on the desktop aside. Someone who turned masking on at a laptop and
             then opened this sheet on a phone must be able to see the STATE, not
             only its effect — a rail of `Workspace A` rows with no explanation
             reads as a data-loading bug, and the person deciding whether it is
             safe to keep sharing has nothing on screen to decide from. Distinct
             data-roles from the desktop strip: the two are never both visible,
             but both are in the DOM at once and a shared role makes every
             selector ambiguous (the same reasoning as the settings sheet's). --%>
        <div :if={@mask_names?} class="channel-mask-strip" data-role="rail-mask-strip-mobile">
          <span class="hero-eye-slash size-3.5 flex-shrink-0" aria-hidden="true"></span>
          <span class="min-w-0 flex-1">
            {if MapSet.size(@revealed_rail_ids) > 0,
              do: "Names hidden · #{MapSet.size(@revealed_rail_ids)} showing",
              else: "Names hidden for sharing"}
          </span>
          <button
            type="button"
            phx-click="remask_all"
            class="channel-mask-strip-action"
            data-role="rail-mask-remask-all-mobile"
          >
            Show all
          </button>
        </div>
        <%!-- Stage 5 of ADR-0042: grouped by org with the same <details> shape
             as the desktop sidebar so the mobile sheet stays visually consistent.

             Every name-bearing surface reads @mask_labels through
             TaskDisplay.rail_label/2, exactly as the desktop rows do — the SAME
             map, so the phone and the laptop cannot letter an org differently.
             `data-org-slug` follows the label here too; it is the leak that
             `refute html =~ "Wayne-Tech"` cannot see. --%>
        <div class="flex flex-col">
          <details
            :for={{org_slug, _org_name, org_projects} <- @project_sections}
            open
            class="relative"
            data-role="project-group"
            data-org-slug={TaskDisplay.rail_org_slug(@mask_labels, org_slug)}
          >
            <summary class={[
              "flex items-center gap-2 px-3 py-2 text-xs font-semibold uppercase tracking-widest text-base-content/60 cursor-pointer select-none",
              summary_pad(
                @root_admin? and org_slug not in [@root_org_slug, "_unassigned"],
                @mask_names? and not MapSet.member?(@revealed_rail_ids, org_slug)
              )
            ]}>
              <span
                class={"size-2 rounded-full scope-dot-current #{Tenancy.scope_color(org_slug)}"}
                data-scope={
                  if(@mask_names? and not MapSet.member?(@revealed_rail_ids, org_slug),
                    do: nil,
                    else: org_slug
                  )
                }
              >
              </span>
              <span>{TaskDisplay.rail_label(@mask_labels, {:org, org_slug})}</span>
              <span class="ml-auto text-[10px] tracking-normal text-base-content/40">
                {length(org_projects)}
              </span>
            </summary>
            <%!-- Per-item reveal, a POSITIONED SIBLING of <summary> and not a
                 descendant: a <button> inside <summary> toggles the native
                 <details>, so revealing a name would collapse the section under
                 the finger that tapped it. The desktop rail hit this first. --%>
            <button
              :if={@mask_names? and not MapSet.member?(@revealed_rail_ids, org_slug)}
              type="button"
              class={[
                "channel-section-reveal-button absolute top-1.5",
                if(@root_admin? and org_slug not in [@root_org_slug, "_unassigned"],
                  do: "right-8",
                  else: "right-1"
                )
              ]}
              phx-click="reveal_rail_item"
              phx-value-kind="org"
              phx-value-id={TaskDisplay.rail_org_slug(@mask_labels, org_slug)}
              aria-label="Show this workspace name"
              data-role="rail-reveal-org-mobile"
            >
              <span class="hero-eye size-3.5" aria-hidden="true"></span>
            </button>
            <%!-- Mobile org kebab: same lifecycle_menu + events as the desktop
                 sidebar, keyed with a `mobile-` prefix so its open-state never
                 collides with the desktop menu's data-menu-key in the DOM.
                 Positioned sibling of <summary> so a tap opens the menu without
                 toggling the native <details>. The root org is never offered. --%>
            <.lifecycle_menu
              :if={@root_admin? and org_slug not in [@root_org_slug, "_unassigned"]}
              key={"mobile-org:#{TaskDisplay.rail_org_slug(@mask_labels, org_slug)}"}
              open={
                @lifecycle_menu_key ==
                  "mobile-org:#{TaskDisplay.rail_org_slug(@mask_labels, org_slug)}"
              }
              type="org"
              id={TaskDisplay.rail_org_slug(@mask_labels, org_slug)}
              name={TaskDisplay.rail_label(@mask_labels, {:org, org_slug})}
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
                {TaskDisplay.rail_label(@mask_labels, {:project, project.id})}
              </button>
              <%!-- In normal flow: this row is a <div>, so a nested button has
                   no <details> to toggle. --%>
              <button
                :if={@mask_names? and not MapSet.member?(@revealed_rail_ids, project.id)}
                type="button"
                class="channel-section-reveal-button mr-1"
                phx-click="reveal_rail_item"
                phx-value-kind="project"
                phx-value-id={project.id}
                aria-label="Show this project name"
                data-role="rail-reveal-project-mobile"
              >
                <span class="hero-eye size-3.5" aria-hidden="true"></span>
              </button>
              <%!-- Kebab stays visible on touch (no hover reveal like desktop).
                   Takes the RESOLVED label: `name` reaches aria-label,
                   phx-value-name, the confirm modal and the archive flash. --%>
              <.lifecycle_menu
                :if={@root_admin?}
                key={"mobile-project:#{project.id}"}
                open={@lifecycle_menu_key == "mobile-project:#{project.id}"}
                type="project"
                id={project.id}
                name={TaskDisplay.rail_label(@mask_labels, {:project, project.id})}
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
                <%!-- Stage 5 of ADR-0042: group by owning org via <optgroup>.

                     AN OPTGROUP LABEL IS ON SCREEN whenever the select is open,
                     and it is in the DOM always — masking the options and
                     leaving the group headings would put the org names back on
                     the shared screen the moment someone opened the picker.
                     Both follow @mask_labels (task 01a00cf1 stage 3). --%>
                <optgroup
                  :for={{org_slug, _org_name, org_projects} <- @projects_by_org}
                  label={
                    TaskDisplay.label_for(@mask_labels, @mask_names?, {:org, org_slug},
                      real: Tenancy.scope_label(org_slug)
                    )
                  }
                >
                  <option
                    :for={project <- org_projects}
                    value={project.id}
                    selected={@epic_form[:project_id].value == project.id}
                  >
                    {TaskDisplay.label_for(@mask_labels, @mask_names?, {:project, project.id},
                      real: project.name
                    )}
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
           defaults to the current user's primary membership's org, else the root org. --%>
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

          <%!-- Org (required per ADR-0042).

               The `project[name]` input above is NOT masked and must not be:
               it is a form field the user is typing into, its value is their
               own keystrokes, and blanking or rewriting it would destroy the
               thing being created. Masking is about names the app puts on
               screen, not names the user is putting there.

               `@orgs` is a WIDER set than `@project_sections` — it includes
               orgs with no projects, which have no entry in @mask_labels. Those
               fall through `rail_label/2`'s fail-closed branch to a bare
               `Workspace`, so several options can read identically while masked.
               That is the correct direction to be wrong in and it is
               recoverable in one click (turn the mode off to pick), whereas the
               other direction puts a real org name on a shared screen. --%>
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
                {TaskDisplay.label_for(@mask_labels, @mask_names?, {:org, org.slug},
                  real: Tenancy.scope_label(org.slug)
                )}
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
