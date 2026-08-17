defmodule PlatformWeb.Tasks.TaskCreateComponent do
  @moduledoc """
  New-Task creation — the mobile create FAB, the bottom-sheet form, and
  everything that turns that form into a `%Task{}`. Extracted from
  `PlatformWeb.TasksLive` by task 01a008f6 stage 6.

  ## Ownership

  Assigns owned here, none left in the shell: `:show_task_sheet`,
  `:task_form`, `:sheet_what`, `:sheet_why`, `:validation_modes`,
  `:manual_validation_text`, `:deploy_strategy_type`, `:auto_merge_enabled`,
  `:auto_approve_plan_enabled`, `:merge_method`, `:fab_menu_open`,
  `:default_task_agent_id`, plus the `:task_attachments` upload.

  Nine events, not the plan's seven — the two it missed are
  `taskcreate_toggle_fab` (the FAB is listed in the plan's prose but not
  its count) and `taskcreate_cancel_upload`, which sits eighty lines away
  from its siblings in the old shell under a comment about steering:
  `taskcreate_toggle_sheet`, `taskcreate_close_sheet`,
  `taskcreate_validate`, `taskcreate_toggle_validation_mode`,
  `taskcreate_toggle_auto_merge`, `taskcreate_toggle_auto_approve_plan`,
  `taskcreate_submit`, `taskcreate_cancel_upload`, `taskcreate_toggle_fab`.

  ## The upload moved WITH the form

  `allow_upload(:task_attachments, ...)` is declared in this component's
  `mount/1`, not left behind in the LiveView. A `live_file_input` whose
  `upload` came from the parent's `@uploads` renders fine and uploads
  nothing useful, because `consume_uploaded_entries/3` must run in the
  process/component that configured the upload. Keeping the config in the
  shell would have compiled, rendered, and silently dropped every
  attachment.

  ## Mobile clearance

  The FAB's `env(safe-area-inset-bottom)` + `var(--bottom-nav-height,0px)`
  offsets are NOT written here: they live in the shared
  `PlatformWeb.Components.ActionPatterns.fab_create/1` primitive, so this
  move cannot drop them. `tasks_live_task_create_test.exs` asserts the
  rendered offset anyway — the risk the plan named is real, it just isn't
  in this file, and a hand-rolled replacement FAB is exactly what the
  assertion is there to catch.

  ## Render regions

  `tasks_live.html.heex` 1594-1640 (FAB) and 1650-1984 (sheet) at
  `74448b78`, plus the header split-button trigger at 69-76 which stays in
  the shell and now carries `phx-target="#tasks-create"`. The plan's cited
  ranges (3858-3897, 4268-4598) were written against the pre-stage-2
  4,906-line template and point past its end.
  """
  use PlatformWeb, :live_component

  require Logger

  alias Platform.Chat.AttachmentStorage
  alias Platform.Federation.TaskAttrs
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias Platform.Tenancy

  import PlatformWeb.Tasks.TaskDisplay,
    only: [deploy_target_label: 1, project_deploy_targets: 1]

  @max_upload_entries 5
  @max_upload_size 15_000_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:show_task_sheet, false)
     |> assign(:fab_menu_open, false)
     |> assign(:default_task_agent_id, nil)
     |> assign(:task_form, to_form(Task.changeset(%Task{}, %{}), as: "task"))
     |> assign(:sheet_what, "")
     |> assign(:sheet_why, "")
     |> assign(:validation_modes, MapSet.new())
     |> assign(:manual_validation_text, "")
     |> assign(:deploy_strategy_type, "inherit")
     |> assign(:auto_merge_enabled, false)
     |> assign(:auto_approve_plan_enabled, false)
     |> assign(:merge_method, "squash")
     |> allow_upload(:task_attachments,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size
     )}
  end

  @impl true
  def update(%{close_fab_menu: true}, socket) do
    # The header create-menu and the FAB menu are mutually exclusive; the
    # shell closes this one when the sidebar opens one of its sheets.
    {:ok, assign(socket, :fab_menu_open, false)}
  end

  def update(assigns, socket) do
    socket = assign(socket, assigns)

    # The default agent is derived, not passed: the shell's `:agents` list
    # is the single source and this is the only reader.
    {:ok, assign(socket, :default_task_agent_id, default_task_agent_id(socket.assigns[:agents]))}
  end

  defp default_task_agent_id([agent | _]), do: agent.id
  defp default_task_agent_id(_), do: nil

  defp default_task_form_attrs(nil), do: %{}

  defp default_task_form_attrs(agent_id),
    do: %{"assignee_id" => agent_id, "assignee_type" => "agent"}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Single create FAB + anchored menu (re-skin Phase 2 stage 2, task
           019f51ca) replaces the pre-reskin triple FAB stack. Mobile-only
           (md:hidden) — desktop creates via the page-header split button.
           The `@selected_task && "max-md:hidden"` guard keeps the FAB out of
           the way while the task detail panel is open on mobile. Menu items
           fire the SAME sheet-toggle events the old FABs did; those handlers
           also reset :fab_menu_open so picking an item closes the menu.
           data-role="project-create-fab" stays on the New-Project menu item
           for e2e selector stability.

           The bottom clearance (safe-area inset + --bottom-nav-height) is
           inside `fab_create/1`, not here — see the moduledoc. --%>
      <.fab_create
        id="tasks-create-fab"
        open={@fab_menu_open}
        toggle_event="taskcreate_toggle_fab"
        toggle_target={@myself}
        label="Create"
        class={["md:hidden", @selected_task && "max-md:hidden"]}
        data-role="fab-create"
      >
        <button
          type="button"
          role="menuitem"
          phx-click="taskcreate_toggle_sheet"
          phx-target={@myself}
          class="flex min-h-11 items-center gap-2 rounded-lg px-3 py-2 text-left text-sm font-medium text-primary hover:bg-base-200 focus-visible-ring"
          data-role="fab-new-task"
        >
          <span class="hero-plus size-4"></span> New Task
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="sidebar_toggle_epic_sheet"
          phx-target="#tasks-sidebar"
          class="flex min-h-11 items-center gap-2 rounded-lg px-3 py-2 text-left text-sm hover:bg-base-200 focus-visible-ring"
          data-role="fab-new-epic"
        >
          <span class="hero-rectangle-stack size-4"></span> New Epic
        </button>
        <button
          type="button"
          role="menuitem"
          phx-click="sidebar_toggle_project_create_sheet"
          phx-target="#tasks-sidebar"
          class="flex min-h-11 items-center gap-2 rounded-lg px-3 py-2 text-left text-sm hover:bg-base-200 focus-visible-ring"
          data-role="project-create-fab"
        >
          <span class="hero-folder-plus size-4"></span> New Project
        </button>
      </.fab_create>

      <%!-- New-task sheet (task 019e0d4b stage 3 sub b). Bottom sheet on mobile,
           centered card on desktop per <.sheet> spec §3 @media(min-width: 768px).
           The form lives inside :inner_block; submit buttons stay inside the form
           for proper form-submission semantics (not in :actions slot).

           :if={@show_task_sheet} on the Sheet itself (rather than open={@flag})
           — the form has many select dropdowns (project, epic, agent) that would
           otherwise leak option text into the always-rendered DOM and break
           refute-by-text assertions in the existing test suite (e.g. the epic-
           toggle-collapse test).

           `on_close_target` is not decoration: `sheet.js` pushes the close
           event from a JS hook, and a hook's pushEvent ignores phx-target.
           Without the explicit target the swipe/Escape/scrim close would fire
           into the shell LiveView, which no longer has the clause. --%>
      <.sheet
        :if={@show_task_sheet}
        id="task-sheet"
        open={true}
        placement={:bottom}
        on_close="taskcreate_close_sheet"
        on_close_target={@myself}
      >
        <:title>New Task</:title>
        <.form
          for={@task_form}
          id="create-task-form"
          phx-hook="ButtonLoading"
          phx-change="taskcreate_validate"
          phx-submit="taskcreate_submit"
          phx-target={@myself}
          class="form-fields space-y-4"
        >
          <%!-- Title --%>
          <div>
            <label class="label label-text text-xs font-medium">Title *</label>
            <input
              type="text"
              name="task[title]"
              value={@task_form[:title].value}
              required
              placeholder="Add unread badges"
              class="input input-bordered w-full"
            />
          </div>

          <%!-- Project. Stage 5 of ADR-0042 groups options by their owning org
               via <optgroup>, mirroring the sidebar's grouped layout. --%>
          <div>
            <label class="label label-text text-xs font-medium">Project *</label>
            <select name="task[project_id]" class="select select-bordered w-full" required>
              <option value="">Select project</option>
              <optgroup
                :for={{org_slug, _org_name, org_projects} <- @projects_by_org}
                label={Tenancy.scope_label(org_slug)}
              >
                <option
                  :for={project <- org_projects}
                  value={project.id}
                  selected={@task_form[:project_id].value == project.id}
                >
                  {project.name}
                </option>
              </optgroup>
            </select>
          </div>

          <%!-- What --%>
          <div>
            <label class="label label-text text-xs font-medium">What *</label>
            <textarea
              name="task[what]"
              required
              placeholder="What is being changed or added?"
              style="field-sizing:content"
              class="textarea textarea-bordered w-full min-h-10 max-h-50 leading-normal"
            >{@sheet_what}</textarea>
          </div>

          <%!-- Why --%>
          <div>
            <label class="label label-text text-xs font-medium">Why *</label>
            <textarea
              name="task[why]"
              required
              placeholder="Why is this change needed?"
              style="field-sizing:content"
              class="textarea textarea-bordered w-full min-h-10 max-h-50 leading-normal"
            >{@sheet_why}</textarea>
          </div>

          <%!-- Epic --%>
          <div>
            <label class="label label-text text-xs font-medium">Epic</label>
            <select name="task[epic_id]" class="select select-bordered w-full">
              <option value="">None</option>
              <option
                :for={epic <- @epics}
                value={epic.id}
                selected={@task_form[:epic_id].value == epic.id}
              >
                {epic.name}
              </option>
            </select>
          </div>

          <%!-- Agent --%>
          <div>
            <label class="label label-text text-xs font-medium">Agent</label>
            <select name="task[assignee_id]" class="select select-bordered w-full">
              <option value="">None</option>
              <option
                :for={agent <- @agents}
                value={agent.id}
                selected={@task_form[:assignee_id].value == agent.id}
              >
                {agent.name}
              </option>
            </select>
            <input type="hidden" name="task[assignee_type]" value="agent" />
          </div>

          <%!-- Sponsor — nullable human user who shepherds this task (ADR-0042
               stage 3). Distinct from Agent (technical assignee): a Sponsor is the
               human owner of "does this ship?" not "does this compile?". Defaults
               to No Sponsor for v1 to prevent thoughtless assignment; the acting
               user can pick themselves explicitly. --%>
          <div>
            <label class="label label-text text-xs font-medium">Sponsor</label>
            <select name="task[sponsor_user_id]" class="select select-bordered w-full">
              <option value="" selected={is_nil(@task_form[:sponsor_user_id].value)}>
                No Sponsor
              </option>
              <option
                :for={user <- @users}
                value={user.id}
                selected={@task_form[:sponsor_user_id].value == user.id}
              >
                {user.name}
              </option>
            </select>
          </div>

          <%!-- Auto-approve plan (019f25f2 stage 4) — skips the human plan-review
               step when the plan meets preconditions (every stage has an assignee).
               Backend precondition lives in Platform.Tasks.submit_plan_for_review/1
               (see stage 2). Copy stays in the "stages" mental model even though
               the log path uses the more precise "execution/review assignee" term. --%>
          <div class="space-y-2">
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="task[auto_approve_plan]"
                value="true"
                checked={@auto_approve_plan_enabled}
                class="toggle toggle-sm toggle-primary"
                phx-click="taskcreate_toggle_auto_approve_plan"
                phx-target={@myself}
              />
              <span class="label-text text-xs">Auto-approve plan</span>
              <div
                class="tooltip tooltip-top"
                data-tip="Skip the human approval step when the plan is submitted. Requires every stage to have an assigned agent."
              >
                <span class="hero-information-circle size-3.5 opacity-50"></span>
              </div>
            </label>
          </div>

          <%!-- Deploy target — nullable string; entries come from the selected
               project's deploy_config.deploy_targets. Selector disabled when the
               project has none configured or when no project is selected yet.
               Mirrors the detail-pane deploy_target dropdown. Distinct from
               Deploy Strategy (below) which sets the strategy shape rather than
               the destination. ADR 0044 stage 4 — sheet↔MCP parity. --%>
          <div>
            <label class="label label-text text-xs font-medium">Deploy Target</label>
            <% sheet_project_targets = sheet_project_deploy_targets(@task_form, @projects_by_org) %>
            <select
              name="task[deploy_target]"
              data-role="sheet-deploy-target-select"
              disabled={sheet_project_targets == []}
              class="select select-bordered w-full"
            >
              <option value="" selected={is_nil(@task_form[:deploy_target].value)}>
                {if sheet_project_targets == [], do: "(no targets configured)", else: "(none)"}
              </option>
              <option
                :for={t <- sheet_project_targets}
                value={t}
                selected={@task_form[:deploy_target].value == t}
              >
                {deploy_target_label(t)}
              </option>
            </select>
          </div>

          <%!-- Deploy Strategy --%>
          <div>
            <label class="label label-text text-xs font-medium">Deploy Strategy</label>
            <select
              name="task[deploy_strategy_type]"
              id="deploy-strategy-type"
              class="select select-bordered w-full"
              phx-change="taskcreate_validate"
              phx-target={@myself}
            >
              <option value="inherit">Inherit from project</option>
              <option value="pr_merge">PR Merge</option>
              <option value="docker_deploy">Docker Deploy</option>
              <option value="skill_driven">Skill Driven</option>
              <option value="manual">Manual</option>
              <option value="none">None (skip deploy)</option>
            </select>
          </div>
          <%!-- Auto-merge config — visible only when PR Merge is selected --%>
          <div
            :if={@deploy_strategy_type == "pr_merge"}
            class="space-y-2 pl-2 border-l-2 border-base-300"
          >
            <label class="label cursor-pointer justify-start gap-2">
              <input
                type="checkbox"
                name="task[auto_merge]"
                value="true"
                checked={@auto_merge_enabled}
                class="toggle toggle-sm toggle-primary"
                phx-click="taskcreate_toggle_auto_merge"
                phx-target={@myself}
              />
              <span class="label-text text-xs">
                Auto-merge after CI passes
              </span>
              <div
                class="tooltip tooltip-top"
                data-tip="When enabled, PRs are automatically merged after CI passes. When disabled, a human must click merge."
              >
                <span class="hero-information-circle size-3.5 opacity-50"></span>
              </div>
            </label>
            <div :if={@auto_merge_enabled}>
              <label class="label label-text text-xs font-medium">Merge Method</label>
              <select
                name="task[merge_method]"
                class="select select-bordered select-xs w-full"
              >
                <option value="squash" selected={@merge_method == "squash"}>Squash</option>
                <option value="merge" selected={@merge_method == "merge"}>Merge commit</option>
                <option value="rebase" selected={@merge_method == "rebase"}>Rebase</option>
              </select>
            </div>
          </div>

          <%!-- Validation Mode --%>
          <div>
            <label class="label label-text text-xs font-medium">Validation</label>
            <div class="flex flex-wrap gap-2">
              <button
                type="button"
                phx-click="taskcreate_toggle_validation_mode"
                phx-target={@myself}
                phx-value-mode="show_me"
                class={"btn btn-sm #{if MapSet.member?(@validation_modes, "show_me"), do: "btn-primary", else: "btn-outline"}"}
              >
                Show me
              </button>
              <button
                type="button"
                phx-click="taskcreate_toggle_validation_mode"
                phx-target={@myself}
                phx-value-mode="handle_it"
                class={"btn btn-sm #{if MapSet.member?(@validation_modes, "handle_it"), do: "btn-primary", else: "btn-outline"}"}
              >
                Handle it
              </button>
              <button
                type="button"
                phx-click="taskcreate_toggle_validation_mode"
                phx-target={@myself}
                phx-value-mode="manual"
                class={"btn btn-sm #{if MapSet.member?(@validation_modes, "manual"), do: "btn-primary", else: "btn-outline"}"}
              >
                Manual
              </button>
            </div>
            <textarea
              :if={MapSet.member?(@validation_modes, "manual")}
              name="task[manual_validation_text]"
              placeholder="Describe the validation criteria..."
              style="line-height:1.5;padding:6px 12px;min-height:33px;max-height:200px;overflow-y:auto;field-sizing:content"
              class="textarea textarea-bordered mt-2 w-full text-sm"
            >{@manual_validation_text}</textarea>
          </div>

          <%!-- Attachments --%>
          <div>
            <label class="label label-text text-xs font-medium">Attachments</label>
            <.live_file_input
              upload={@uploads.task_attachments}
              class="file-input file-input-bordered file-input-sm w-full"
            />
            <div
              :for={entry <- @uploads.task_attachments.entries}
              class="mt-2 flex items-center gap-2 text-xs"
            >
              <span class="flex-1 truncate">{entry.client_name}</span>
              <span class="text-base-content/40">
                {Float.round(entry.client_size / 1_000, 1)} KB
              </span>
              <button
                type="button"
                phx-click="taskcreate_cancel_upload"
                phx-target={@myself}
                phx-value-ref={entry.ref}
                class="btn btn-ghost btn-xs btn-square"
              >
                <span class="hero-x-mark size-3"></span>
              </button>
            </div>
            <div
              :for={err <- upload_errors(@uploads.task_attachments)}
              class="mt-1 text-xs text-error"
            >
              {err}
            </div>
          </div>

          <%!-- Submit buttons --%>
          <div class="flex gap-2 pt-2">
            <button
              type="submit"
              name="task[action]"
              value="create"
              class="btn btn-primary btn-sm flex-1"
            >
              Create Task
            </button>
            <button
              type="submit"
              name="task[action]"
              value="create_and_plan"
              class="btn btn-secondary btn-sm flex-1"
            >
              Create & Request Plan
            </button>
          </div>
        </.form>
      </.sheet>
    </div>
    """
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("taskcreate_toggle_fab", _params, socket) do
    {:noreply, assign(socket, :fab_menu_open, !socket.assigns.fab_menu_open)}
  end

  def handle_event("taskcreate_toggle_sheet", _params, socket) do
    showing = !socket.assigns.show_task_sheet

    # The header ▾ create menu is shell-owned and must close too, so the
    # two menus can never be open at once.
    send(self(), {:taskcreate_close_menus})
    socket = assign(socket, :fab_menu_open, false)

    socket =
      if showing do
        socket
        |> assign(:show_task_sheet, true)
        |> assign(
          :task_form,
          to_form(
            Task.changeset(
              %Task{},
              default_task_form_attrs(socket.assigns.default_task_agent_id)
            ),
            as: "task"
          )
        )
        |> assign(:sheet_what, "")
        |> assign(:sheet_why, "")
        |> assign(:validation_modes, MapSet.new())
        |> assign(:manual_validation_text, "")
        |> assign(:deploy_strategy_type, "inherit")
        |> assign(:auto_merge_enabled, false)
        |> assign(:auto_approve_plan_enabled, false)
        |> assign(:merge_method, "squash")
      else
        assign(socket, :show_task_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("taskcreate_close_sheet", _params, socket) do
    {:noreply, assign(socket, :show_task_sheet, false)}
  end

  def handle_event("taskcreate_validate", %{"task" => params}, socket) do
    Logger.debug(
      "[TaskCreateComponent] validate: deploy_strategy_type=#{inspect(Map.get(params, "deploy_strategy_type"))}"
    )

    changeset =
      %Task{}
      |> Task.changeset(params)
      |> Map.put(:action, :validate)

    strategy_type = Map.get(params, "deploy_strategy_type", socket.assigns.deploy_strategy_type)
    auto_merge = Map.get(params, "auto_merge") == "true"
    auto_approve_plan = Map.get(params, "auto_approve_plan") == "true"
    merge_method = Map.get(params, "merge_method", socket.assigns.merge_method)

    {:noreply,
     socket
     |> assign(:task_form, to_form(changeset, as: "task"))
     |> assign(:sheet_what, Map.get(params, "what", ""))
     |> assign(:sheet_why, Map.get(params, "why", ""))
     |> assign(:manual_validation_text, Map.get(params, "manual_validation_text", ""))
     |> assign(:deploy_strategy_type, strategy_type)
     |> assign(:auto_merge_enabled, auto_merge)
     |> assign(:auto_approve_plan_enabled, auto_approve_plan)
     |> assign(:merge_method, merge_method)}
  end

  def handle_event("taskcreate_toggle_validation_mode", %{"mode" => mode}, socket) do
    modes = socket.assigns.validation_modes

    updated =
      if MapSet.member?(modes, mode),
        do: MapSet.delete(modes, mode),
        else: MapSet.put(modes, mode)

    {:noreply, assign(socket, :validation_modes, updated)}
  end

  def handle_event("taskcreate_toggle_auto_merge", _params, socket) do
    {:noreply, assign(socket, :auto_merge_enabled, !socket.assigns.auto_merge_enabled)}
  end

  def handle_event("taskcreate_toggle_auto_approve_plan", _params, socket) do
    {:noreply,
     assign(socket, :auto_approve_plan_enabled, !socket.assigns.auto_approve_plan_enabled)}
  end

  def handle_event("taskcreate_cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :task_attachments, ref)}
  end

  def handle_event("taskcreate_submit", %{"task" => params}, socket) do
    status =
      case Map.get(params, "action") do
        "create_and_plan" -> "planning"
        _ -> "backlog"
      end

    do_create_task(params, socket, status)
  end

  # ── Private — Task creation ─────────────────────────────────────────────

  defp do_create_task(params, socket, status) do
    requested_plan? = status == "planning"

    case normalize_task_assignee(params, socket.assigns.default_task_agent_id, requested_plan?) do
      {:error, :no_agent_available} ->
        flash(:error, "Select an agent before requesting a plan.")
        {:noreply, socket}

      normalized_assignee ->
        do_create_task_with_assignee(params, socket, status, normalized_assignee)
    end
  end

  defp do_create_task_with_assignee(params, socket, status, {assignee_id, assignee_type}) do
    what = Map.get(params, "what", "")
    why = Map.get(params, "why", "")

    description =
      case {String.trim(what), String.trim(why)} do
        {"", ""} -> nil
        {w, ""} -> "## What\n#{w}"
        {"", w} -> "## Why\n#{w}"
        {w, y} -> "## What\n#{w}\n\n## Why\n#{y}"
      end

    # Build validation metadata
    modes = socket.assigns.validation_modes
    manual_text = socket.assigns.manual_validation_text

    validation_meta =
      %{}
      |> then(fn m ->
        if MapSet.size(modes) > 0,
          do: Map.put(m, "validation_modes", MapSet.to_list(modes)),
          else: m
      end)
      |> then(fn m ->
        if MapSet.member?(modes, "manual") && String.trim(manual_text) != "",
          do: Map.put(m, "manual_validation", String.trim(manual_text)),
          else: m
      end)

    existing_meta = Map.get(params, "metadata", %{})
    metadata = Map.merge(existing_meta, validation_meta)

    # Merge deploy_target — convert "" to nil (kept for backward compat)
    deploy_target =
      case Map.get(params, "deploy_target", "") do
        "" -> nil
        v -> v
      end

    # Parse deploy_strategy from form
    deploy_strategy = parse_deploy_strategy(params)

    # Sponsor picker submits "" for "No Sponsor" — coerce to nil so the
    # nullable FK changeset doesn't see an empty string (ADR-0042 stage 3).
    #
    # New tasks always start at the planning phase (per ADR 0044). Route
    # the flat `assignee_id + assignee_type` pair through
    # `TaskAttrs.build_task_attrs/3` with `auto_route_flat_assignee_current_phase: true`
    # so it lands in `phase_assignees["planning"]` — matches the MCP
    # `task_create` path (`tool_surface.ex`). Prior UI writes left
    # `phase_assignees = %{}`, which caused the flat pointer to be lost
    # on the first phase transition. Task 019f42fd bug 1 fix.
    raw_attrs =
      params
      |> Map.put("description", description)
      |> Map.put("status", status)
      |> Map.put("metadata", metadata)
      |> Map.put("deploy_target", deploy_target)
      |> Map.put("deploy_strategy", deploy_strategy)
      |> Map.put("assignee_id", assignee_id)
      |> Map.put("assignee_type", assignee_type)
      |> Map.put("auto_approve_plan", socket.assigns.auto_approve_plan_enabled)
      |> Map.update("sponsor_user_id", nil, fn v -> if v in [nil, ""], do: nil, else: v end)
      |> Map.put("reported_by", socket.assigns.current_user)

    create_result =
      with {:ok, flat_attrs, phase_attrs} <-
             TaskAttrs.build_task_attrs(raw_attrs, :create,
               auto_route_flat_assignee_current_phase: true,
               current_phase: "planning"
             ),
           # `TaskAttrs` drops `metadata` / `deploy_strategy` (not in its
           # canonical field list) — carry them across explicitly so the
           # UI-only form fields still land on the row.
           flat_attrs = merge_ui_extras(flat_attrs, raw_attrs),
           {:ok, task} <- Tasks.create_task(flat_attrs),
           {:ok, task} <- maybe_apply_phase_assignees(task, phase_attrs) do
        {:ok, task}
      end

    case create_result do
      {:ok, task} ->
        # Persist attachments. `consume_uploaded_entries/3` MUST run on this
        # socket — the upload is configured here, not in the shell.
        persist_task_attachments(socket, task)

        Tasks.broadcast_board({:task_created, task})

        flash_message =
          if status == "planning",
            do: "Task created and planning requested.",
            else: "Task created."

        # The board is shell state; ask for the refresh rather than
        # reaching for it.
        send(self(), {:taskcreate_created, flash_message})

        {:noreply, assign(socket, :show_task_sheet, false)}

      {:error, %Ecto.Changeset{} = changeset} ->
        flash(:error, "Could not create task. Check the form for errors.")
        {:noreply, assign(socket, :task_form, to_form(changeset, as: "task"))}

      {:error, reason} ->
        # `TaskAttrs.build_task_attrs/3` can return non-changeset shape
        # errors (invalid phase key, invalid current_phase, etc). The UI
        # doesn't currently expose those inputs, so these are defensive
        # — surface a generic error message rather than crashing the LV.
        flash(:error, "Could not create task: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  # `TaskAttrs.build_task_attrs/3` restricts `flat_attrs` to the canonical
  # field list. The new-task form also carries `metadata`,
  # `deploy_strategy`, and `dependencies` — UI-only concerns not part of
  # the ADR 0044 canonical shape.
  defp merge_ui_extras(flat_attrs, raw_attrs) do
    Enum.reduce(~w(metadata deploy_strategy dependencies), flat_attrs, fn key, acc ->
      case Map.get(raw_attrs, key) do
        nil -> acc
        value -> Map.put(acc, String.to_existing_atom(key), value)
      end
    end)
  end

  defp maybe_apply_phase_assignees(task, nil), do: {:ok, task}

  defp maybe_apply_phase_assignees(task, phase_attrs) when is_map(phase_attrs),
    do: Tasks.set_phase_assignees(task, phase_attrs)

  defp persist_task_attachments(socket, _task) do
    consume_uploaded_entries(socket, :task_attachments, fn %{path: path}, entry ->
      case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
        {:ok, _attrs} -> {:ok, :persisted}
        {:error, _reason} -> {:ok, :failed}
      end
    end)
  end

  # Deploy targets for the New-Task bottom sheet's deploy_target dropdown.
  # Reads the selected project id off the task form (nil when no project
  # picked yet), finds the matching project in the pre-grouped
  # `projects_by_org` structure, and delegates to `project_deploy_targets/1`
  # for the same map/string extraction the detail pane uses.
  defp sheet_project_deploy_targets(task_form, projects_by_org)
       when is_list(projects_by_org) do
    case task_form[:project_id].value do
      nil ->
        []

      "" ->
        []

      project_id ->
        projects_by_org
        |> Enum.flat_map(fn {_slug, _name, projects} -> projects end)
        |> Enum.find(&(&1.id == project_id))
        |> case do
          nil -> []
          project -> project_deploy_targets(project)
        end
    end
  end

  defp sheet_project_deploy_targets(_, _), do: []

  defp normalize_task_assignee(params, default_agent_id, requested_plan?) do
    selected_assignee_id =
      case Map.get(params, "assignee_id", "") do
        "" -> nil
        nil -> nil
        id -> id
      end

    cond do
      is_binary(selected_assignee_id) ->
        {selected_assignee_id, "agent"}

      requested_plan? && is_binary(default_agent_id) ->
        {default_agent_id, "agent"}

      requested_plan? ->
        {:error, :no_agent_available}

      true ->
        {nil, nil}
    end
  end

  defp parse_deploy_strategy(params) do
    case Map.get(params, "deploy_strategy_type", "") do
      "" -> nil
      "inherit" -> nil
      "pr_merge" -> %{"type" => "pr_merge", "config" => parse_pr_merge_config(params)}
      "docker_deploy" -> %{"type" => "docker_deploy", "config" => %{}}
      "skill_driven" -> %{"type" => "skill_driven", "config" => %{}}
      "manual" -> %{"type" => "manual"}
      "none" -> %{"type" => "none"}
      _ -> nil
    end
  end

  defp parse_pr_merge_config(params) do
    base = %{
      "require_ci_pass" => Map.get(params, "require_ci_pass") == "true",
      "auto_merge" => Map.get(params, "auto_merge") == "true",
      "require_review_approval" => Map.get(params, "require_review_approval") == "true"
    }

    # Only include merge_method when auto_merge is enabled
    if base["auto_merge"] do
      method = Map.get(params, "merge_method", "squash")

      if method in ~w(squash merge rebase),
        do: Map.put(base, "merge_method", method),
        else: Map.put(base, "merge_method", "squash")
    else
      base
    end
  end

  # `put_flash/3` from a LiveComponent writes to a socket nothing renders;
  # the shell owns the flash. Same contract as SupersedeComponent.
  defp flash(kind, message), do: send(self(), {:taskcreate_flash, kind, message})
end
