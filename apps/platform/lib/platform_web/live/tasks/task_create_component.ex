defmodule PlatformWeb.Tasks.TaskCreateComponent do
  @moduledoc """
  New-Task creation — the mobile create FAB, the bottom-sheet form, and
  everything that turns that form into a `%Task{}`. Extracted from
  `PlatformWeb.TasksLive` by task 01a008f6 stage 6.

  ## Ownership

  Assigns owned here, none left in the shell: `:show_task_sheet`,
  `:task_form`, `:sheet_what`, `:sheet_why`, `:sheet_wrong`, `:validation_modes`,
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
  alias Platform.Tasks
  alias Platform.Tasks.Task
  alias PlatformWeb.Tasks.TaskDisplay

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
     |> assign(:sheet_wrong, "")
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
        class={["md:hidden max-lg:hidden", @selected_task && "max-md:hidden"]}
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
          <.input
            field={@task_form[:title]}
            label="Title"
            required
            placeholder="Add unread badges"
          />

          <%!-- Project. Stage 5 of ADR-0042 groups options by their owning org
               via <optgroup>, mirroring the sidebar's grouped layout.

               Masked via @mask_labels (task 01a00cf1 stage 3). An <optgroup>
               label is visible the moment the select is opened and is in the
               DOM the whole time regardless — masking the options alone would
               leave every org name one tap from the shared screen. The `title`
               field above is the user's own keystrokes and is left alone. --%>
          <div>
            <label class="label label-text text-xs font-medium">Project *</label>
            <select name="task[project_id]" class="select select-bordered w-full" required>
              <option value="">Select project</option>
              <optgroup
                :for={{org_slug, org_name, org_projects} <- @projects_by_org}
                label={
                  TaskDisplay.label_for(@mask_labels, @mask_names?, {:org, org_slug}, real: org_name)
                }
              >
                <option
                  :for={project <- org_projects}
                  value={project.id}
                  selected={@task_form[:project_id].value == project.id}
                >
                  {TaskDisplay.label_for(@mask_labels, @mask_names?, {:project, project.id},
                    real: project.name
                  )}
                </option>
              </optgroup>
            </select>
          </div>

          <div>
            <label for="task-kind" class="label label-text text-xs font-medium">Kind *</label>
            <select
              id="task-kind"
              name="task[kind]"
              data-role="task-kind-select"
              class="select select-bordered w-full"
              required
            >
              <option
                :for={kind <- Task.kinds()}
                value={kind}
                selected={(@task_form[:kind].value || "feature") == kind}
              >
                {String.capitalize(kind)}
              </option>
            </select>
            <p class="mt-1 text-[11px] text-subtle">
              Feature · Chore · Bug · Research · Ops
            </p>
          </div>

          <%!-- What --%>
          <.input
            type="textarea"
            kind={:auto_resize}
            id="task-sheet-what"
            name="task[what]"
            value={@sheet_what}
            label="What"
            required
            placeholder="What is being changed or added?"
          />

          <%!-- Why --%>
          <.input
            type="textarea"
            kind={:auto_resize}
            id="task-sheet-why"
            name="task[why]"
            value={@sheet_why}
            label="Why"
            required
            placeholder="Why is this change needed?"
          />

          <%!-- Wrong: a peer of What and Why, deliberately undemoted. Renders LAST
               here and composes FIRST into the body — see compose_description/3. --%>
          <.input
            type="textarea"
            kind={:auto_resize}
            id="task-sheet-wrong"
            name="task[wrong]"
            value={@sheet_wrong}
            label="Wrong"
            required
            placeholder="What would you expect to see if this ticket is wrong?"
          />

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
            class="space-y-2 pl-2 border-l-2 border-edge"
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
            <.input
              :if={MapSet.member?(@validation_modes, "manual")}
              type="textarea"
              kind={:auto_resize}
              id="task-sheet-manual-validation"
              name="task[manual_validation_text]"
              value={@manual_validation_text}
              aria-label="Manual validation criteria"
              placeholder="Describe the validation criteria..."
              class="textarea mt-2 w-full text-sm"
            />
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
              <span class="text-subtle">
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
        |> assign(:sheet_wrong, "")
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
     |> assign(:sheet_wrong, Map.get(params, "wrong", ""))
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

  @doc """
  Composes the task description body from the three sheet fields.

  **`## Wrong` comes FIRST, above the prescriptive What/Why content — this is
  deliberate and it INVERTS the form order. Do not "fix" it.** The form renders
  Wrong last because it is a peer field completing a set (What · Why · Wrong).
  The composed body puts it first because a ticket is not read as a unit: a
  fixer reads it to FIND the instruction and stops scanning once they find one.
  A falsifier placed below the prescription is routable-around by construction,
  and the reader it exists for — the confident one following a stale instruction
  to the letter — never arrives at it.

  Blank sections are dropped; an all-blank result is `nil`.

  Public only so the ordering can be asserted by index in tests rather than
  inferred from a persisted row.

  ## Enforced versus instructed — the split (task 01a0a5f5 stage 5)

  Recorded verbatim here and beside the `@federation_preamble` constant in
  `lib/platform/orchestration/prompt_templates.ex`; both readers need it and
  neither will read the other file.

  > **Falsifier presence and falsifier placement are STRUCTURAL and testable on
  > the human form — a required field, composed first into the description body
  > by `compose_description/3`. On every other filing path they are INSTRUCTION
  > ONLY: the MCP `task_create` body is free-form prose with no composer and no
  > anchor, so nothing enforces presence and nothing can even locate placement.
  > A ticket filed through MCP, a seed, or a script arrives with no falsifier
  > and nothing rejects it. That is the documented state of this feature, not a
  > defect.**

  **Mechanism classes, ranked.** This form field is structural — required, at
  the moment of filing, unskippable, order fixed by this function. The
  agent-side preamble section (`## Filing a ticket — state its falsifier` in
  the `federation.preamble` template) is the weakest class: a sentence in a
  document read earlier. The `task_create` descriptor in
  `Platform.Federation.ToolSurface` sits between them — rendered at the moment
  of the call, still only text. The agent side is text because the ticket's
  scope bound rules out schema and required-field changes, and because the
  alternative remedy — keeping cites fresh — is unmaintainable at the observed
  blast radius: commit `014371a6` (2026-08-26, -4023/+238) invalidated every
  line cite into `chat_live.html.heex` across the whole backlog in one change.
  Four times on this platform a correct note failed to change behaviour because
  nothing made the reader re-read it at the moment of the hazard; Dalton's
  summary of what did work is "the fix that worked was never a better note — it
  was a field on a form nobody could skip." This field is literally that. The
  preamble section is not, and the plan does not pretend otherwise.

  **Efficacy of the agent side is UNMEASURED.** Firing looks like: agent-filed
  tickets after the deploy carry a falsifier at a rate materially above the
  pre-change base rate for the same filers, and at least one reader reports
  stopping on one. Skipped looks like: tickets lacking the sentence, carrying
  boilerplate that names no checkable observation, carrying it below the
  prescription, or carrying one the reader proceeded past anyway. The
  divergence in that rate between the form path and the MCP path is itself the
  measurement of structure-versus-sentence, and is the thing to read once there
  is a sample.

  **The n=1 bound.** The evidence that self-stated falsifiers fail safe is ONE
  ticket (`01a04aec`) that did. An existence proof, not a rate. No artifact in
  this task may assert more.
  """
  def compose_description(wrong, what, why) do
    [{"Wrong", wrong}, {"What", what}, {"Why", why}]
    |> Enum.reject(fn {_h, v} -> String.trim(v || "") == "" end)
    |> Enum.map_join("\n\n", fn {h, v} -> "## #{h}\n#{String.trim(v)}" end)
    |> case do
      "" -> nil
      body -> body
    end
  end

  defp do_create_task_with_assignee(params, socket, status, {assignee_id, assignee_type}) do
    what = Map.get(params, "what", "")
    why = Map.get(params, "why", "")
    wrong = Map.get(params, "wrong", "")

    description = compose_description(wrong, what, why)

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

    # The one creation path (task 01a111bb): TaskAttrs, the UI extras,
    # `create_task/1` and the phase assignees, in that order. The native app's
    # `POST /api/app/tasks` calls the same function.
    #
    # The project, epic and stack ids arrive from the form (task 01a1472d
    # stage 1): one the viewer may not `tasks.write` gets the changeset a
    # nonexistent id gets, so nothing is inserted and the flash is the same.
    create_result =
      case refused_target(socket, params) do
        nil -> Tasks.create_from_request(raw_attrs)
        field -> {:error, refused_changeset(params, field)}
      end

    case create_result do
      {:ok, task} ->
        # Persist attachments. `consume_uploaded_entries/3` MUST run on this
        # socket — the upload is configured here, not in the shell.
        persist_task_attachments(socket, task)

        Tasks.broadcast_board({:task_created, task})

        # Burrow personal context (task 01a111bb): ids only.
        socket =
          PlatformWeb.NativeDonation.push(socket, "task_created", %{
            task_id: task.id,
            project_id: task.project_id
          })

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

      # Task 01a11ec3 stage 1: `Tasks.create_task/2` refuses a quarantined
      # row born into planning/execution with a 3-tuple; without this arm
      # the `case` raises CaseClauseError and the LiveView crashes.
      {:error, :quarantined, _details} ->
        flash(
          :error,
          "Could not create task: quarantined external feedback cannot start planning."
        )

        {:noreply, socket}

      {:error, reason} ->
        # `TaskAttrs.build_task_attrs/3` can return non-changeset shape
        # errors (invalid phase key, invalid current_phase, etc). The UI
        # doesn't currently expose those inputs, so these are defensive
        # — surface a generic error message rather than crashing the LV.
        flash(:error, "Could not create task: #{inspect(reason)}")
        {:noreply, socket}
    end
  end

  @fenced_create_fields [{"project_id", :project}, {"epic_id", :epic}, {"stack_id", :stack}]

  defp refused_target(socket, params) do
    Enum.find_value(@fenced_create_fields, fn {key, type} ->
      case Map.get(params, key) do
        id when is_binary(id) and id != "" ->
          if PlatformWeb.Tasks.Selection.permits?(socket, {type, id}),
            do: nil,
            else: String.to_existing_atom(key)

        _ ->
          nil
      end
    end)
  end

  defp refused_changeset(params, field) do
    %Task{}
    |> Task.changeset(params)
    |> Ecto.Changeset.add_error(field, "does not exist", constraint: :foreign)
    |> Map.put(:action, :insert)
  end

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
