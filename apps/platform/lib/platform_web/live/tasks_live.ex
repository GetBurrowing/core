defmodule PlatformWeb.TasksLive do
  use PlatformWeb, :live_view

  require Logger

  import Ecto.Query

  alias Platform.Accounts
  alias Platform.Chat
  alias Platform.Chat.Canvas
  alias Platform.Chat.AttachmentStorage
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Federation.TaskAttrs
  alias Platform.Orchestration.ExecutionSpace
  alias Platform.Repo
  alias Platform.Skills
  alias Platform.Tasks
  alias Platform.Tasks.CanvasAttachments
  alias Platform.Tasks.ChatPins
  alias Platform.Tasks.MergeControl
  alias Platform.Tasks.PlanRejection
  alias Platform.Tasks.{Epic, Plan, Project, ReviewRequest, ReviewRequests, Stack, Stacks, Task}
  alias Platform.Tenancy
  alias PlatformWeb.LifecycleActions

  # Desktop kanban columns (Stage 2 of Tasks v2 plan, 2026-05-19). Seven
  # explicit buckets — planning + blocked are split out from Backlog so
  # users can see and act on them directly, and `cancelled` folds into
  # Done (handled by `Platform.Tasks.list_by_status/1`).
  #
  # Column render order is the visual reading order across the board.
  # String keys keep the template's HTML id / data-column / `phx-value-*`
  # plumbing unchanged (atoms would serialize as ":backlog").
  @kanban_columns [
    {"backlog", "Backlog"},
    {"planning", "Planning"},
    {"in_progress", "In Progress"},
    {"blocked", "Blocked"},
    {"in_review", "In Review"},
    {"deploying", "Deploying"},
    {"done", "Done"}
  ]

  # Mobile pill order — INTENTIONALLY left at the pre-Stage-2 5-bucket
  # shape per the responsive-scope contract on the Stage 2 dispatch
  # ("Mobile keeps the existing list view unchanged — DO NOT touch the
  # mobile render path"). Planning + blocked tasks continue to roll up
  # under the "Backlog" mobile pill via `@mobile_column_statuses`.
  @mobile_columns [
    {"backlog", "Backlog"},
    {"in_progress", "In Progress"},
    {"in_review", "In Review"},
    {"deploying", "Deploying"},
    {"done", "Done"}
  ]

  # Statuses that map into each MOBILE kanban pill / section (5-bucket
  # shape, unchanged for Stage 2). `forming` (stack rollup status) +
  # planning + blocked all fold into the Backlog pill on mobile so
  # forming/early-stage work stays visible from the moment it's created.
  @mobile_column_statuses %{
    "backlog" => ~w(backlog planning blocked forming),
    "in_progress" => ~w(in_progress),
    "in_review" => ~w(in_review),
    "deploying" => ~w(deploying),
    "done" => ~w(done)
  }

  # Statuses that map into each DESKTOP kanban column (7-bucket shape).
  # Mirrors `Platform.Tasks.list_by_status/1` so the stack-bucketing
  # helper below produces consistent buckets for the desktop board.
  # `forming` lives under Planning (a fresh stack is being planned);
  # `cancelled` folds into Done (matches the Stage 1 helper).
  @desktop_column_statuses %{
    "backlog" => ~w(backlog),
    "planning" => ~w(planning forming),
    "in_progress" => ~w(in_progress),
    "blocked" => ~w(blocked),
    "in_review" => ~w(in_review),
    "deploying" => ~w(deploying),
    "done" => ~w(done cancelled)
  }

  # Back-compat alias kept ONLY for any external callers / tests that
  # referenced the old name. Internal call sites use the explicit
  # mobile/desktop maps directly.
  @column_statuses @mobile_column_statuses

  @max_upload_entries 5
  @max_upload_size 15_000_000

  @impl true
  def mount(_params, session, socket) do
    if connected?(socket) do
      Tasks.subscribe_board()
      # Pin-to-Chat stage 4 (task 019f62a1): subscribe to the global
      # space-lifecycle topic so `{:task_pin_added, ...}` /
      # `{:task_pin_removed, ...}` broadcasts from `Platform.Tasks.ChatPins`
      # reach every open detail panel — the pin button re-renders solid /
      # outline in step with the truth on disk without requiring the sponsor
      # to refresh (or to be the one who fired the pin, in the future when
      # agents can auto-pin on behalf of a mentioned user).
      ChatPubSub.subscribe_spaces()
    end

    # Stage 5 of ADR-0042: preload `:org` so the sidebar can group projects
    # by `project.org.slug` + light up the org color tokens via
    # `Tenancy.scope_label/1` + `scope_color/1` — both pure, DB-free.
    projects = Tasks.list_projects_for_user(socket.assigns[:current_user_record], preload: :org)
    all_tasks = Tasks.list_all_tasks()
    # Stage-5 of task 019e2c25: subscribe to per-task ReviewRequests topics
    # so the badge live-updates within 2s when a manual_approval review_request
    # fires while a stack-detail panel is open. Tracked in
    # `:review_request_subscriptions` (MapSet of task_ids) so `refresh_board/1`
    # can diff and (re)subscribe as the board's task set changes.
    initial_task_ids = MapSet.new(all_tasks, & &1.id)

    if connected?(socket) do
      Enum.each(initial_task_ids, &ReviewRequests.subscribe_for_task/1)
    end

    # Pin-to-Chat stage 4: hydrate the current user's email once (pins are
    # keyed by email for user participants — see `ChatPins.pin/3` and the
    # stage-3 mention-propagation pass in `Platform.Chat`) and seed the
    # pin-button MapSet. `MapSet` gives O(1) membership checks so the detail
    # panel's `pinned_by_me?/3` helper stays a pure lookup, not a Repo query,
    # across every re-render.
    current_user_email = fetch_user_email(session["current_user_id"])

    my_pinned_task_ids =
      case current_user_email do
        nil ->
          MapSet.new()

        email ->
          ChatPins.pinned_task_ids_for(%{kind: "user", id: email})
          |> MapSet.new()
      end

    stack_entries = Stacks.list_stacks_with_members(%{})
    {stack_board_data, stacks} = split_stack_entries(stack_entries)
    users = Accounts.list_users()
    users_by_id = Map.new(users, &{&1.id, &1})
    agents = Chat.list_agents_for_picker()
    agents_by_id = Map.new(agents, &{&1.id, &1})
    default_task_agent_id = default_task_agent_id(agents)

    {:ok,
     socket
     |> assign(:page_title, "Tasks")
     |> assign(:current_user_id, session["current_user_id"])
     # Pin-to-Chat stage 4: email backs the pin-participant identity for
     # `ChatPins.pin/3` (which stores user pins by email) and the socket-side
     # MapSet driving the header pin-toggle button state per task.
     |> assign(:current_user_email, current_user_email)
     |> assign(:my_pinned_task_ids, my_pinned_task_ids)
     |> assign(:projects, projects)
     # Stage 5 of ADR-0042: pre-bucketed `[{org_slug, org_name, [project]}]`
     # list used by the sidebar `<details>` sections. Computed once at mount
     # and re-computed any time `:projects` changes (after create-project,
     # the board PubSub doesn't fan that out yet — we recompute inline in
     # the create handler).
     |> assign(:projects_by_org, group_projects_by_org(projects))
     # Navigation sidebar (desktop + mobile sheet): every active org the viewer
     # belongs to, even at zero projects, so an org's header + kebab survive
     # archiving its last project. The <select>s above stay on the
     # project-derived list.
     |> assign(
       :project_sections,
       project_sections(projects, socket.assigns[:current_user_record])
     )
     # Org dropdown options for the New-Project form. Stable for the
     # lifetime of the mount (no live org-edit surface exists yet).
     # ADR-0042: surfaced in canonical tenant-priority order so the FAB's
     # <select> agrees with the sidebar grouping (Fabrikam → Soylent →
     # Wayne-Tech → SXI → Paragon).
     |> assign(:orgs, Tenancy.list_orgs_in_priority_order())
     |> assign(:selected_project_id, nil)
     |> assign(:selected_epic_id, nil)
     |> assign(:sidebar_open, true)
     |> assign(:projects_collapsed, false)
     |> assign(:show_project_sheet, false)
     # Stage 5 of ADR-0042: New-Project bottom sheet + form state. Mirrors
     # the `:show_epic_sheet` / `:epic_form` lifecycle.
     |> assign(:show_project_create_sheet, false)
     |> assign(
       :project_form,
       to_form(
         Project.changeset(%Project{}, default_project_form_attrs(session["current_user_id"])),
         as: "project"
       )
     )
     |> assign(:all_tasks, all_tasks)
     |> assign(:stacks, stacks)
     |> assign(:stack_board_data, stack_board_data)
     # `:columns` carries the DESKTOP 7-bucket task map produced by
     # `Platform.Tasks.list_by_status/1` (Stage 1 helper). Keys are
     # atoms (`:backlog`, `:planning`, …, `:done`). The Stage-2 desktop
     # kanban template iterates `@kanban_columns` (string keys) and
     # looks up each column via `Map.get(@columns, String.to_atom(key),
     # [])`. Cancelled tasks fold into `:done` (per the helper).
     #
     # `:board_items` keeps the legacy 5-bucket MOBILE shape (string
     # keys, planning+blocked+forming rolled up under "backlog"). The
     # mobile pill nav + section list read from this map and must not
     # be reshaped at Stage 2 — see the responsive-scope contract on
     # the Stage 2 dispatch ("DO NOT touch the mobile render path").
     #
     # `:desktop_stacks_by_column` parallels `:columns` for stacks:
     # 7-bucket string-keyed map of `%Stack{}` lists. The desktop
     # template merges tasks + stacks per column and sorts by
     # `updated_at` desc inline.
     |> assign(:columns, Tasks.list_by_status())
     |> assign(:desktop_stacks_by_column, group_desktop_stacks(stack_entries))
     |> assign(:board_items, group_board_items(all_tasks, stack_entries))
     # Ephemeral expansion state: ids of stacks the user has clicked open
     # on the board (ADR 0041 acceptance criterion 3). MUST reset on
     # every list refetch — see `refresh_board/1`.
     |> assign(:expanded_stacks, MapSet.new())
     |> assign(:kanban_columns, @kanban_columns)
     |> assign(:mobile_columns, @mobile_columns)
     |> assign(:active_status_filter, "in_progress")
     # Stage-3 of Tasks v2 (scope-filter rail, desktop only): `:scope_filter`
     # is one of `:all`, `:fabrikam`, `:soylent`, `:wayne_tech`, `:sxi`,
     # `:paragon`. Default `:all` keeps the board unchanged on first load.
     # `:scope_counts` is the per-scope task count map computed by
     # `Platform.Tasks.count_by_scope/0` (today-state: everything folds
     # under :fabrikam until `tasks.org_id` lands). The mobile pill nav is
     # unaffected — the rail is `hidden lg:flex` only.
     |> assign(:scope_filter, :all)
     |> assign(:scope_counts, Tasks.count_by_scope())
     # DB-computed copy survives search narrowing so clearing a query can
     # restore the rail badges without another round-trip (Marlowe 2026-07-12:
     # all on-screen counts must match the filtered board during search).
     |> assign(:scope_counts_db, Tasks.count_by_scope())
     # nil = "no narrowed count yet" — the template falls back to
     # length(@all_tasks). First paint skips refresh_board (handle_params
     # only refreshes when the sponsor filter CHANGED), so a static default
     # here would render a wrong badge; nil keeps the fallback authoritative
     # until a search or board refresh computes the real visible count.
     |> assign(:visible_task_count, nil)
     # Stage-2 of task 019f3f22 (ADR-0042 sponsor visibility): `:sponsor_filter`
     # is one of `:all` or `:mine`. Default `:all` keeps the board unchanged
     # on first paint. `:mine` narrows both the desktop kanban (via
     # `Platform.Tasks.list_by_status/1` `sponsor_user_id:` opt) and the
     # mobile section list (via `list_all_tasks/1`) to tasks whose
     # `sponsor_user_id` equals `@current_user_id`. The URL param
     # `?sponsor=mine` is authoritative — `handle_params/3` decodes it on
     # mount + toggle, matching the existing `?project=` shareability
     # contract. LocalStorage / session persistence is intentionally out
     # of scope per the ADR non-goals.
     |> assign(:sponsor_filter, :all)
     # Re-skin Phase 2 stage 2 (task 019f51ca): `:task_search_query` backs
     # the page-header search input. Non-blank queries narrow `:columns`,
     # `:board_items` and `:desktop_stacks_by_column` IN-MEMORY (no DB
     # round-trip per keystroke) via `rebuild_board_shapes/1`; the
     # unfiltered sources stay in `:all_tasks` / `:stacks` /
     # `:stack_board_data`. `:create_menu_open` / `:fab_menu_open` drive
     # the desktop header ▾ menu and the mobile create-FAB menu — plain
     # styled divs whose open state is server-owned.
     |> assign(:task_search_query, "")
     |> assign(:create_menu_open, false)
     |> assign(:fab_menu_open, false)
     # Task 019fed1e: the admin-only Tasks settings menu (one row today,
     # Pipeline). Server-owned open state like the two above; the trigger
     # itself only renders behind `@fabrikam_admin?`, and the destination is
     # gated again by `live_session :admin`.
     |> assign(:settings_menu_open, false)
     # Container-lifecycle UI state (task 019f4eaa stage 6). `:active_scope_keys`
     # is the data-driven scope-rail source — the seeded slugs of every
     # non-archived tenant THE VIEWER BELONGS TO (Fabrikam admins see all), as
     # atoms, so an archived org drops off the rail. `:lifecycle_menu_key` is the single open
     # kebab menu (org/project); `:delete_modal` is `nil` or the
     # `%{type:, id:, name:}` the Schedule-deletion confirm dialog targets.
     |> assign(:active_scope_keys, active_scope_keys(socket.assigns[:current_user_record]))
     |> assign(:lifecycle_menu_key, nil)
     |> assign(:delete_modal, nil)
     # `:undo_archive` is nil (no toast) or the %{type:, id:, name:, hidden:}
     # the archive undo toast targets.
     |> assign(:undo_archive, nil)
     |> assign(:pending_plan_count, count_pending_plans(all_tasks))
     |> assign(:review_counts, pending_review_counts(all_tasks))
     |> assign(:review_request_subscriptions, initial_task_ids)
     |> assign(:selected_task, nil)
     |> assign(:selected_task_canvases, [])
     |> assign(:merge_control, nil)
     |> assign(:show_detail, false)
     # Stack detail panel state (T8 stage 1). `:selected_stack` is the
     # `%Platform.Tasks.Stack{}` whose detail panel is open, with
     # `:members` preloaded for downstream stages (DAG, members list).
     # `:show_stack_detail` gates the slide-in container.
     |> assign(:selected_stack, nil)
     |> assign(:selected_stack_members, [])
     # Stage-2 of task 019e2c25: per-member pending-review counts powering the
     # "Needs review" / "Plan ready" badge on stack-detail member rows.
     # Keyed by member task id → integer count of open review_requests.
     |> assign(:selected_stack_member_review_counts, %{})
     # Stage-2 of task 019e2c27 (Stack-Level Review Rollup): rollup count of
     # pending review_requests across every member of the open stack. Drives
     # the "Needs feedback (N)" pill on the stack-detail panel chrome.
     # Computed via `Stacks.count_pending_reviews/1` whenever the panel is
     # (re)loaded or `:review_request_pending` / `:review_request_resolved`
     # PubSub fires. Hidden entirely when 0 — see the chrome-pill template.
     # Mount-time defaults for the three assigns that back the stack
     # rollup pill + overlay; see `assign_stack_review_state/2` for the
     # canonical writer used by every subsequent state transition.
     # The trio:
     #
     #   * `:selected_stack_pending_review_count` — pill count.
     #   * `:selected_stack_open_review_requests` — list of `%ReviewRequest{}`
     #     (preloaded items + virtual `:member_task`) the overlay enumerates.
     #     Rendered by the stack-feedback overlay when
     #     `:show_stack_feedback_overlay` is true.
     #   * `:selected_stack_open_review_canvases` — `%{canvas_id => %Canvas{}}`
     #     for every canvas referenced by an item, so the overlay renders
     #     each canvas inline via the same `CanvasRenderer.canvas_document`
     #     component the per-task `active_review_canvas` modal uses
     #     (gold-standard pattern at tasks_live.html.heex ~line 2378).
     |> assign(:selected_stack_pending_review_count, 0)
     |> assign(:selected_stack_open_review_requests, [])
     |> assign(:selected_stack_open_review_canvases, %{})
     # Stage-5 of task 019e2c27: per-stack-member review_requests:<task_id>
     # subscription set. The board-level `:review_request_subscriptions`
     # already follows every task on the current project/epic view, but the
     # stack-detail panel can hold open members that fall outside the
     # board's filter (e.g. a project switch happens while the panel is
     # open). Track stack-scoped subscriptions here so `open_stack_detail`
     # can guarantee live-refresh for every member regardless of the
     # board's subscription set, and `close_stack_detail` can unwind them
     # WITHOUT clobbering any overlap with the board's set. MapSet of
     # task_ids the stack panel is responsible for keeping subscribed.
     |> assign(:stack_review_request_subscriptions, MapSet.new())
     # Toggled by `open_stack_feedback_overlay` (the chrome-pill click).
     # Stage 3 renders the rollup overlay (modal that floats OVER the
     # stack pane, not inline) against this assign.
     |> assign(:show_stack_feedback_overlay, false)
     # Stage-4 of task 019e2c27: per-item reject-feedback toggle + text
     # buffer, scoped to the stack-feedback overlay. Mirrors the per-task
     # `:review_feedback_open` / `:review_items_feedback` pair but lives
     # under a separate key so opening the reject textarea on a row in the
     # overlay does not visually flip anything in the (hidden) per-task
     # review panel underneath. Reset whenever the overlay closes.
     |> assign(:stack_feedback_reject_open, MapSet.new())
     |> assign(:stack_feedback_reject_text, %{})
     |> assign(:show_stack_detail, false)
     # Plan revision folding state — IDs of plans the user has explicitly
     # toggled open. Active (non-rejected) plans are expanded by default
     # via `default_expanded_plan_ids/1` whenever `:selected_task` changes.
     |> assign(:expanded_plans, MapSet.new())
     # Plan reject-with-feedback inline UI (stage 1 of task 019e30be).
     # `:reject_plan_open` is the plan_id currently expanded inline (nil
     # when collapsed); only one plan's reject drawer is open at a time
     # since the pending_review card itself is exclusive per task. The
     # `:reject_plan_feedback_text` buffer holds the in-flight draft so
     # keystrokes survive LV re-renders without re-rendering the whole
     # plan card on every character. The pair mirrors the per-review-item
     # `:review_feedback_open` / `:review_items_feedback` pattern (~line
     # 242), scaled down to the single-plan case.
     |> assign(:reject_plan_open, nil)
     |> assign(:reject_plan_feedback_text, "")
     # Execution log state
     |> assign(:execution_space_id, nil)
     |> assign(:execution_log, [])
     |> assign(:execution_log_collapsed, false)
     # Steering input state
     |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
     |> assign(:execution_participant, nil)
     |> assign(:steering_feedback, nil)
     |> assign(:steering_upload_previews, [])
     |> assign(:steering_attachment_intended, false)
     # Bottom sheet state
     |> assign(:show_task_sheet, false)
     # Per-row task-actions sheet (3-dot menu): nil = closed, task.id = sheet open for that row
     |> assign(:open_task_actions_id, nil)
     # Per-phase assignee modal
     |> assign(:show_assignee_modal, false)
     |> assign(:assignee_modal_mode, :simple)
     # Stack-level assignee modal (ADR 0041 — assign agents at the stack
     # level; the default fans out to un-overridden members). Mirrors the
     # per-task assignee modal's simple/advanced segmented pattern.
     |> assign(:show_stack_assignee_modal, false)
     |> assign(:stack_assignee_modal_mode, :simple)
     # Reopen-with-feedback modal (done tasks). Reset to closed/empty on
     # mount; reopened tasks return to `planning`, where a new plan is
     # authored, so this state lives only as long as the modal is open.
     |> assign(:show_reopen_modal, false)
     |> assign(:reopen_reason, "")
     # Return-to-planning modal (in-flight tasks). Mirrors the reopen
     # pair above but targets `in_progress` / `in_review` / `deploying`
     # and calls Tasks.supersede_current_plan/3.
     |> assign(:show_supersede_modal, false)
     |> assign(:supersede_reason, "")
     |> assign(:default_task_agent_id, default_task_agent_id)
     |> assign(
       :task_form,
       to_form(Task.changeset(%Task{}, default_task_form_attrs(default_task_agent_id)),
         as: "task"
       )
     )
     |> assign(:sheet_what, "")
     |> assign(:sheet_why, "")
     # New-Epic bottom sheet (mirrors :show_task_sheet / :task_form). Stage 3
     # of task 019d60ca: a second FAB stacked above the Create-Task FAB opens
     # this sheet; submit calls Tasks.create_epic/1 which broadcasts on success.
     |> assign(:show_epic_sheet, false)
     |> assign(
       :epic_form,
       to_form(Epic.changeset(%Epic{}, %{}), as: "epic")
     )
     |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
     |> assign(:epics_collapsed, false)
     |> assign(:agents, agents)
     |> assign(:agent_names, Map.new(agents, fn a -> {a.id, a.name} end))
     # `:users` powers the Sponsor picker in the New-Task bottom sheet (stage 3
     # of ADR-0042). `:users_by_id` remains for detail-panel + row lookups.
     |> assign(:users, users)
     |> assign(:users_by_id, users_by_id)
     |> assign(:agents_by_id, agents_by_id)
     |> assign(:agent_names, Map.new(agents, fn a -> {a.id, a.name} end))
     |> assign(:users_by_id, users_by_id)
     |> assign(:agents_by_id, agents_by_id)
     |> assign(:validation_modes, MapSet.new())
     |> assign(:manual_validation_text, "")
     |> assign(:deploy_strategy_type, "inherit")
     |> assign(:auto_merge_enabled, false)
     |> assign(:auto_approve_plan_enabled, false)
     |> assign(:merge_method, "squash")
     |> assign(:pending_reviews, [])
     |> assign(:superseded_reviews, [])
     |> assign(:review_canvases, %{})
     |> assign(:review_output_ids, MapSet.new())
     |> assign(:output_canvases, [])
     |> assign(:active_review_canvas, nil)
     # Stack dep-graph fullscreen modal (stage 3 of task 019f487e). Purely
     # ephemeral socket state — no ClientState persistence, no hook — and
     # MUST be cleared alongside `:active_review_canvas` on every drawer
     # reset path so the modal cannot outlive its underlying
     # `:selected_stack_members`.
     |> assign(:stack_graph_expanded, false)
     |> assign(:review_feedback_open, MapSet.new())
     # Task 019fed8d stage 3: disclosure state for the "N earlier submissions"
     # line. Collapsed by default — an earlier submission is history, not
     # something the reviewer is being asked to read.
     |> assign(:superseded_reviews_expanded, false)
     |> assign(:review_items_feedback, %{})
     |> assign(:attached_skills, [])
     |> assign(:available_skills, Skills.list_skills())
     |> assign(:confirm_delete, false)
     # Inline-edit state — id of task whose title is being edited (kanban card or
     # detail panel). nil when no edit in progress. Description has its own
     # boolean assign to keep the state minimal.
     |> assign(:editing_task_title_id, nil)
     |> assign(:editing_description, false)
     # Detail-panel edit-mode toggle. When false, the panel is read-only;
     # when true, inline-edit affordances become interactive (gating wired in
     # stage 2). Reset to false on task switch and on close_detail so each
     # selection starts read-only.
     |> assign(:edit_mode, false)
     |> allow_upload(:task_attachments,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size
     )
     |> allow_upload(:steering_attachments,
       accept: :any,
       auto_upload: true,
       max_entries: @max_upload_entries,
       max_file_size: @max_upload_size,
       progress: &handle_steering_attachment_progress/3
     )}
  end

  @impl true
  def handle_params(%{"task_id" => task_id}, _url, socket) do
    # Platform.UUID.cast/1, NOT Ecto.UUID.cast/1, at all six guards in this
    # module. These are FABRICATED-VALUE sites, not raise sites: the {:ok, _}
    # output flows on, so a bare cast hex-encodes a 16-character LiveView
    # param into a well-formed but INVENTED uuid that silently misses
    # instead of being rejected. Nothing raises — an assert_raise-shaped
    # test cannot see this. Assert the :error branch is taken.
    case Platform.UUID.cast(task_id) do
      {:ok, _} ->
        task = Tasks.get_task_detail(task_id)

        if task do
          # Unsubscribe from previous execution space if any
          unsubscribe_execution_space(socket)

          # Load execution log for this task
          {space_id, log} = load_execution_log(task_id)

          # Subscribe to real-time updates if space exists
          if space_id, do: Chat.PubSub.subscribe(space_id)

          pending_reviews = ReviewRequests.list_pending_for_task(task.id)
          superseded_reviews = ReviewRequests.list_superseded_for_task(task.id)
          review_canvases = load_review_canvases(pending_reviews)
          review_output_ids = review_canvas_ids(pending_reviews)
          output_canvases = load_output_canvases(space_id)
          attached_skills = Skills.resolve_skills(task.id)

          # Lazily resolve participant for the execution space
          execution_participant =
            if space_id do
              resolve_execution_participant(space_id, socket.assigns.current_user_id)
            else
              nil
            end

          {:noreply,
           socket
           |> assign_selected_task(task)
           |> assign(:show_detail, true)
           |> assign(:execution_space_id, space_id)
           |> assign(:execution_log, log)
           |> assign(:execution_participant, execution_participant)
           |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
           |> assign(:steering_feedback, nil)
           |> assign(:steering_upload_previews, [])
           |> assign(:steering_attachment_intended, false)
           |> assign(:pending_reviews, pending_reviews)
           |> assign(:superseded_reviews, superseded_reviews)
           |> assign(:review_canvases, review_canvases)
           |> assign(:review_output_ids, review_output_ids)
           |> assign(:output_canvases, output_canvases)
           |> assign(:active_review_canvas, nil)
           |> assign(:stack_graph_expanded, false)
           |> assign(:attached_skills, attached_skills)
           |> assign(:available_skills, Skills.list_skills())
           |> assign(:page_title, "Tasks · #{task.title}")}
        else
          # Task ID valid-shape but the row is gone (deleted, cross-tenant
          # 404). Client's saved `route_resume:tasks` still points at this
          # URL; signal the hook to clear it so the next Tasks-tile click
          # falls back to `/tasks` instead of re-loading the tombstone.
          {:noreply,
           socket
           |> handle_route_stale("tasks")
           |> assign(:selected_task, nil)
           |> assign(:show_detail, false)
           |> assign(:execution_space_id, nil)
           |> assign(:execution_log, [])
           |> assign(:execution_participant, nil)
           |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
           |> assign(:steering_feedback, nil)
           |> assign(:steering_upload_previews, [])
           |> assign(:steering_attachment_intended, false)
           |> assign(:pending_reviews, [])
           |> assign(:superseded_reviews, [])
           |> assign(:review_canvases, %{})
           |> assign(:review_output_ids, MapSet.new())
           |> assign(:output_canvases, [])
           |> assign(:active_review_canvas, nil)
           |> assign(:stack_graph_expanded, false)
           |> put_flash(:error, "Task not found.")}
        end

      :error ->
        # Malformed UUID in the URL — same "stale saved URL" story: the
        # saved value can't ever resolve, so clear it client-side.
        {:noreply,
         socket
         |> handle_route_stale("tasks")
         |> assign(:selected_task, nil)
         |> assign(:show_detail, false)
         |> assign(:execution_space_id, nil)
         |> assign(:execution_log, [])
         |> assign(:execution_participant, nil)
         |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
         |> assign(:steering_feedback, nil)
         |> assign(:steering_upload_previews, [])
         |> assign(:steering_attachment_intended, false)
         |> assign(:pending_reviews, [])
         |> assign(:superseded_reviews, [])
         |> assign(:review_canvases, %{})
         |> assign(:review_output_ids, MapSet.new())
         |> assign(:output_canvases, [])
         |> assign(:active_review_canvas, nil)
         |> assign(:stack_graph_expanded, false)
         |> put_flash(:error, "Invalid task ID.")}
    end
  end

  def handle_params(params, _url, socket) do
    # Stage-2 of task 019f3f22: `?sponsor=mine` is the authoritative
    # source of truth for the "Sponsored by me" filter — decoded here so
    # both push_patch toggles and direct URL loads (share-a-URL, refresh)
    # land in the same state. Any other value (missing, "", "all", garbage)
    # resolves to `:all` so we can't hang on malformed input.
    new_sponsor_filter = decode_sponsor_param(params)
    prev_sponsor_filter = socket.assigns[:sponsor_filter]

    socket = assign(socket, :sponsor_filter, new_sponsor_filter)

    socket =
      if new_sponsor_filter != prev_sponsor_filter do
        refresh_board(socket)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> assign(:show_detail, false)}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :sidebar_open, !socket.assigns.sidebar_open)}
  end

  def handle_event("toggle_project_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_sheet, !socket.assigns.show_project_sheet)}
  end

  # ── Board search (re-skin Phase 2 stage 2, task 019f51ca) ─────────────
  # Fired by the page-header `<.search_input>`: live phx-change (debounced
  # 200ms, params carry "q"), Enter submit (same params) and Escape
  # keydown (params carry "key" — treated as clear). Filtering is fully
  # in-memory over the already-loaded board sources.

  def handle_event("search_tasks", params, socket) do
    query =
      case params do
        # Defensive: only Escape clears — phx-key filters client-side today,
        # but a future binding change must not turn every keydown into a clear.
        %{"key" => key} when is_binary(key) ->
          if String.downcase(key) == "escape", do: "", else: socket.assigns.task_search_query

        %{"q" => q} when is_binary(q) ->
          q

        %{"value" => q} when is_binary(q) ->
          q

        _ ->
          ""
      end

    {:noreply,
     socket
     |> assign(:task_search_query, query)
     |> rebuild_board_shapes()}
  end

  # ── Create menus (re-skin Phase 2 stage 2, task 019f51ca) ─────────────
  # Desktop header ▾ split-button menu and the mobile create-FAB menu.
  # The three create-sheet toggles below also reset both flags so picking
  # a menu item closes its menu server-side.

  def handle_event("toggle_create_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:create_menu_open, !socket.assigns.create_menu_open)
     |> assign(:settings_menu_open, false)}
  end

  # Task 019fed1e — the admin-only settings menu in the Tasks header.
  # Mirrors `toggle_create_menu` above, and closes the create menu on the
  # way so the two can never be open at once.
  def handle_event("toggle_settings_menu", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_menu_open, !socket.assigns.settings_menu_open)
     |> assign(:create_menu_open, false)}
  end

  # ── Container lifecycle (task 019f4eaa stage 6) ───────────────────────
  # Fabrikam-admin-only archive / schedule-deletion for the orgs + projects in
  # the sidebar. The controls only render behind `@fabrikam_admin?`, and every
  # call re-authorizes underneath in `Platform.Tenancy.Lifecycle`, so a
  # forged event from a non-admin still gets `{:error, :unauthorized}`.

  def handle_event("toggle_lifecycle_menu", %{"key" => key}, socket) do
    next = if socket.assigns.lifecycle_menu_key == key, do: nil, else: key
    {:noreply, assign(socket, :lifecycle_menu_key, next)}
  end

  def handle_event("archive_container", %{"type" => type, "id" => id} = params, socket) do
    case LifecycleActions.archive(socket.assigns.current_user_record, type, id) do
      {:ok, resource} ->
        # An undo toast rather than a flash (Marlowe, 2026-07-16). Archive stays
        # instant + dialog-free — recoverable by default, undo not consent —
        # but it now SAYS what it took and keeps the reversal one click away.
        # Labels are read AFTER the archive on purpose: cascade_hidden reads
        # the provenance marker, which only exists once the cascade has run.
        {:noreply,
         socket
         |> assign(:lifecycle_menu_key, nil)
         |> refresh_containers()
         |> assign(:undo_archive, %{
           type: type,
           id: id,
           name: params["name"] || Map.get(resource, :name, "it"),
           hidden: LifecycleActions.cascade_hidden_labels(type, id)
         })}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:lifecycle_menu_key, nil)
         |> put_flash(:error, LifecycleActions.error_message(reason))}
    end
  end

  def handle_event("undo_archive", _params, socket) do
    case socket.assigns[:undo_archive] do
      nil ->
        {:noreply, socket}

      %{type: type, id: id} ->
        case LifecycleActions.unarchive(socket.assigns.current_user_record, type, id) do
          {:ok, _resource} ->
            {:noreply,
             socket
             |> assign(:undo_archive, nil)
             |> refresh_containers()
             |> put_flash(:info, "Restored.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:undo_archive, nil)
             |> put_flash(:error, LifecycleActions.error_message(reason))}
        end
    end
  end

  def handle_event("dismiss_undo_archive", _params, socket) do
    {:noreply, assign(socket, :undo_archive, nil)}
  end

  # Orgs open the "surface & choose" checklist (task 019f7600 stage 5): deleting
  # an org takes every child with it, so enumerate them ALL (active, cascade-
  # hidden, hand-archived) and let the admin keep any. NB: `id` is an org SLUG on
  # this surface; LifecycleActions resolves it.
  def handle_event(
        "open_delete_modal",
        %{"type" => "org" = type, "id" => id, "name" => name},
        socket
      ) do
    modal = build_org_delete_modal(id, name, LifecycleActions.purge_preview(type, id))

    {:noreply, socket |> assign(:lifecycle_menu_key, nil) |> assign(:delete_modal, modal)}
  end

  # Projects have no children — the simple confirm (empty `preview`).
  def handle_event("open_delete_modal", %{"type" => type, "id" => id, "name" => name}, socket) do
    {:noreply,
     socket
     |> assign(:lifecycle_menu_key, nil)
     |> assign(:delete_modal, %{
       type: type,
       id: id,
       name: name,
       preview: LifecycleActions.cascade_preview(type, id)
     })}
  end

  def handle_event("close_delete_modal", _params, socket) do
    {:noreply, assign(socket, :delete_modal, nil)}
  end

  def handle_event("delete_modal_change", params, socket) do
    {:noreply, update_delete_modal(socket, &delete_modal_apply_change(&1, params))}
  end

  def handle_event("delete_keep_all", _params, socket) do
    {:noreply, update_delete_modal(socket, &delete_modal_keep_all/1)}
  end

  def handle_event("delete_include_all", _params, socket) do
    {:noreply, update_delete_modal(socket, &delete_modal_include_all/1)}
  end

  def handle_event("confirm_schedule_deletion", _params, socket) do
    case socket.assigns.delete_modal do
      # Org: honor the include/keep choices, gated on the acknowledgement.
      %{type: "org", acknowledged: true, id: id, kept: kept} ->
        keep_ids = MapSet.to_list(kept)

        result =
          LifecycleActions.schedule_deletion(
            socket.assigns.current_user_record,
            "org",
            id,
            keep_ids
          )

        {:noreply, finish_schedule_deletion(socket, result)}

      # Gate not armed — ignore the submit, leave the modal open.
      %{type: "org"} ->
        {:noreply, socket}

      %{type: type, id: id} ->
        result =
          LifecycleActions.schedule_deletion(socket.assigns.current_user_record, type, id)

        {:noreply, finish_schedule_deletion(socket, result)}

      _ ->
        {:noreply, assign(socket, :delete_modal, nil)}
    end
  end

  # Only orgs carry the include/keep modal state; a project modal is a no-op here.
  defp update_delete_modal(socket, fun) do
    case socket.assigns.delete_modal do
      %{type: "org"} = modal -> assign(socket, :delete_modal, fun.(modal))
      _ -> socket
    end
  end

  defp finish_schedule_deletion(socket, {:ok, _resource}) do
    socket
    |> assign(:delete_modal, nil)
    |> refresh_containers()
    |> put_flash(:info, "Scheduled for deletion. You can still restore it before then.")
  end

  defp finish_schedule_deletion(socket, {:error, reason}) do
    socket
    |> assign(:delete_modal, nil)
    |> put_flash(:error, LifecycleActions.error_message(reason))
  end

  def handle_event("toggle_fab_menu", _params, socket) do
    {:noreply, assign(socket, :fab_menu_open, !socket.assigns.fab_menu_open)}
  end

  def handle_event("close_project_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_sheet, false)}
  end

  # ── New-Project bottom sheet (ADR-0042 stage 5) ───────────────────────
  # Mirrors the new-epic sheet quartet (toggle/close/validate/create). The
  # form lets the user pick which org owns the new project — required per
  # ADR-0042. Defaults to the current user's primary membership's org via
  # `default_project_form_attrs/1`, else Fabrikam root.

  def handle_event("toggle_project_create_sheet", _params, socket) do
    showing = !socket.assigns.show_project_create_sheet
    socket = close_create_menus(socket)

    socket =
      if showing do
        socket
        |> assign(:show_project_create_sheet, true)
        |> assign(
          :project_form,
          to_form(
            Project.changeset(
              %Project{},
              default_project_form_attrs(socket.assigns[:current_user_id])
            ),
            as: "project"
          )
        )
      else
        assign(socket, :show_project_create_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("close_project_create_sheet", _params, socket) do
    {:noreply, assign(socket, :show_project_create_sheet, false)}
  end

  def handle_event("validate_project", %{"project" => params}, socket) do
    changeset =
      %Project{}
      |> Project.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :project_form, to_form(changeset, as: "project"))}
  end

  def handle_event("create_project", %{"project" => params}, socket) do
    case Tasks.create_project(params) do
      {:ok, _project} ->
        # No board-level pubsub for projects yet — re-fetch the list with
        # the `:org` preload and recompute the grouped buckets inline so
        # the sidebar updates immediately.
        projects =
          Tasks.list_projects_for_user(socket.assigns[:current_user_record], preload: :org)

        {:noreply,
         socket
         |> assign(:projects, projects)
         |> assign(:projects_by_org, group_projects_by_org(projects))
         |> assign(
           :project_sections,
           project_sections(projects, socket.assigns[:current_user_record])
         )
         |> assign(:show_project_create_sheet, false)
         |> assign(
           :project_form,
           to_form(
             Project.changeset(
               %Project{},
               default_project_form_attrs(socket.assigns[:current_user_id])
             ),
             as: "project"
           )
         )
         |> put_flash(:info, "Project created.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:project_form, to_form(changeset, as: "project"))
         |> put_flash(:error, "Could not create project. Check the form for errors.")}
    end
  end

  # Open the per-row task-actions sheet (Sheet-based replacement for the
  # DaisyUI dropdown that was inert on mobile — task 019e0d4b stage 2).
  def handle_event("open_task_actions", %{"id" => task_id}, socket) do
    {:noreply, assign(socket, :open_task_actions_id, task_id)}
  end

  def handle_event("close_task_actions", _params, socket) do
    {:noreply, assign(socket, :open_task_actions_id, nil)}
  end

  def handle_event("select_project", %{"id" => project_id}, socket) do
    # Stale-id fallback: a restored localStorage value may reference a project
    # that has since been deleted, been ARCHIVED, or that the current user can
    # no longer see. We drop back to the All Projects view rather than render a
    # board the sidebar no longer offers.
    #
    # Archived counts as stale (task 019f4eaa): `last_project.js` replays the
    # stored id via this event on EVERY mount, so filtering archived projects
    # out of the sidebar isn't enough on its own — whoever had the project
    # selected when it was archived would keep getting a live, interactive
    # board for it on every visit. Falling through here also self-heals the
    # stored value, because `push_selected_project_changed/1` writes the
    # corrected id back to localStorage.
    project = Tasks.get_project(project_id)

    if is_nil(project) or Platform.Projects.archived?(project) do
      {:noreply,
       socket
       |> assign(:selected_project_id, nil)
       |> assign(:selected_epic_id, nil)
       |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
       |> assign(:show_project_sheet, false)
       |> refresh_board()
       |> push_selected_project_changed()}
    else
      epics = enrich_epics(Tasks.list_epics_for_project(project_id))

      {:noreply,
       socket
       |> assign(:selected_project_id, project_id)
       |> assign(:selected_epic_id, nil)
       |> assign(:epics, epics)
       |> assign(:show_project_sheet, false)
       |> refresh_board()
       |> push_selected_project_changed()}
    end
  end

  def handle_event("select_epic", %{"id" => epic_id}, socket) do
    new_id = if socket.assigns.selected_epic_id == epic_id, do: nil, else: epic_id

    {:noreply,
     socket
     |> assign(:selected_epic_id, new_id)
     |> refresh_board()}
  end

  def handle_event("toggle_projects_section", _params, socket) do
    {:noreply, assign(socket, :projects_collapsed, !socket.assigns.projects_collapsed)}
  end

  def handle_event("toggle_epics_panel", _params, socket) do
    {:noreply, assign(socket, :epics_collapsed, !socket.assigns.epics_collapsed)}
  end

  # Mobile-only: status-filter pill bar above the section-grouped task list.
  # Validates the incoming status against @mobile_columns to ignore garbage.
  def handle_event("filter_by_status", %{"status" => status}, socket) do
    if Enum.any?(@mobile_columns, fn {key, _label} -> key == status end) do
      {:noreply, assign(socket, :active_status_filter, status)}
    else
      {:noreply, socket}
    end
  end

  # Desktop-only: scope-filter rail (Stage 3 of Tasks v2, 2026-05-19). Click
  # narrows the kanban to a single sub-org scope; the "All" chip resets to
  # the unfiltered view. The scope arrives as a string (Phoenix serializes
  # `phx-value-scope={@scope}` from an atom into its string name), so we
  # parse it against the canonical @scope_keys list — anything outside the
  # known set is ignored rather than blowing up `String.to_existing_atom/1`.
  #
  # The rail is `hidden lg:flex` in the template; this handler only fires
  # from the desktop rail and from the implicit "All" chip. Mobile pill nav
  # is untouched per the responsive-scope contract.
  def handle_event("scope_filter", %{"scope" => scope}, socket) do
    case parse_scope(scope) do
      {:ok, parsed} ->
        {:noreply, assign(socket, :scope_filter, parsed)}

      :error ->
        {:noreply, socket}
    end
  end

  # No-scope variant: the "All" chip in the rail dispatches without a
  # phx-value-scope so users can reset the filter from a single click.
  def handle_event("scope_filter", _params, socket) do
    {:noreply, assign(socket, :scope_filter, :all)}
  end

  # Stage-2 of task 019f3f22 (ADR-0042 sponsor visibility): flip the
  # "Sponsored by me" filter between `:all` and `:mine`, then push_patch
  # so the URL stays authoritative. Going back to `:all` DROPS the
  # `?sponsor` param entirely to preserve the canonical URL (a
  # `?sponsor=all` URL is never emitted). Query-string decoding lives in
  # `handle_params/3` — that clause updates the assign + re-queries the
  # board; this handler is a thin push_patch shim so a share-a-URL loader
  # and a click loader end up in the same state.
  def handle_event("toggle_sponsor_filter", _params, socket) do
    next_filter =
      case socket.assigns[:sponsor_filter] do
        :mine -> :all
        _ -> :mine
      end

    path =
      case next_filter do
        :mine -> ~p"/tasks?sponsor=mine"
        _ -> ~p"/tasks"
      end

    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_project_id, nil)
     |> assign(:selected_epic_id, nil)
     |> assign(:epics, enrich_epics(Tasks.list_epics_for_project(nil)))
     |> assign(:show_project_sheet, false)
     |> refresh_board()
     |> push_selected_project_changed()}
  end

  # Push the canonical post-handler selection back to the client so the
  # LastProject JS hook can keep localStorage in sync. This MUST fire after
  # both `select_project` (including the stale-UUID fallback path) and
  # `clear_filters` — relying solely on a wrapper-attribute DOM diff misses
  # the case where the server-side state was already at the same value
  # (e.g. fallback from a stale UUID → nil when nil was the initial render).
  defp push_selected_project_changed(socket) do
    id = socket.assigns.selected_project_id || "__all__"
    push_event(socket, "selected_project_changed", %{id: id})
  end

  # Merge the selected task's branch from the panel.
  #
  # Delegates to `MergeControl.merge/3`, which resolves the branch's open
  # PR on demand and hands it to `AutoMerger.execute_merge/4` — the same
  # entry point the auto-merge webhook path uses, carrying the
  # planning-gate refusal and the stack-member deferral. There is no
  # second merge implementation and this adds no new GitHub write access.
  #
  # It does NOT touch the `pr_merged` validation. That gate auto-passes on
  # the `pull_request.closed` webhook; passing it from the click would
  # pass it on a merge that might not have landed.
  #
  # Every failure — including a missing `gh` — lands in the state band as
  # a named sentence rather than a flash, a crash, or a vanishing button.
  def handle_event("merge_task_branch", _params, socket) do
    case {socket.assigns.selected_task, socket.assigns.merge_control} do
      {%Task{} = task, %{} = control} ->
        actor = %{id: socket.assigns.current_user_id, org_id: nil}

        case MergeControl.merge(task, control, actor) do
          {:ok, _sha} ->
            {:noreply,
             socket
             |> put_flash(:info, "Merge requested for #{control.branch}.")
             |> assign_selected_task(Tasks.get_task_detail(task.id))}

          {:error, band} ->
            {:noreply, assign(socket, :merge_control, %{control | band: band})}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("select_task", %{"id" => task_id}, socket) do
    # T8 stage 4: clicking a stack member row (or any other select_task
    # source) should close the stack detail panel so the two slide-ins
    # don't fight for the same screen real-estate. The per-task panel
    # then opens via push_patch → handle_params/3.
    {:noreply,
     socket
     |> assign(:selected_stack, nil)
     |> assign(:selected_stack_members, [])
     |> assign(:selected_stack_member_review_counts, %{})
     |> assign_stack_review_state(nil)
     |> assign(:show_stack_feedback_overlay, false)
     |> assign(:show_stack_detail, false)
     |> assign(:stack_graph_expanded, false)
     |> push_patch(to: ~p"/tasks/#{task_id}")}
  end

  # Toggle a stack card's expansion state on the kanban board (T7 stage 2).
  #
  # Stage 2 only manages the `:expanded_stacks` MapSet — the rendered
  # expansion (indented member rows + dep annotations) lands in stage 3.
  # Clicking the collapsed card flips the chevron orientation; the row
  # list itself does not appear until stage 3 wires the heex.
  #
  # No-op if the id is not currently in `:stacks` (defensive against
  # stale DOM after PubSub refresh removed the stack).
  def handle_event("toggle_stack_expand", %{"id" => stack_id}, socket) do
    known? = Enum.any?(socket.assigns.stacks, &(&1.id == stack_id))

    if known? do
      expanded = socket.assigns.expanded_stacks

      next =
        if MapSet.member?(expanded, stack_id) do
          MapSet.delete(expanded, stack_id)
        else
          MapSet.put(expanded, stack_id)
        end

      {:noreply, assign(socket, :expanded_stacks, next)}
    else
      {:noreply, socket}
    end
  end

  # Open the stack detail slide-in panel (T8 stage 1).
  #
  # Loads the stack + its members (ordered by `stack_position`) and
  # flips `:show_stack_detail` true. The dedicated per-task detail
  # panel is closed first so the two slide-ins don't overlap.
  #
  # Defensive: a click on a stale DOM node whose stack id no longer
  # exists in the database is a no-op rather than a crash.
  def handle_event("open_stack_detail", %{"id" => stack_id}, socket) do
    case Stacks.get_stack(stack_id) do
      nil ->
        {:noreply, socket}

      %Stack{} = stack ->
        {members, counts} = load_stack_member_panel_data(stack)

        {:noreply,
         socket
         |> assign(:selected_stack, stack)
         |> assign(:selected_stack_members, members)
         |> assign(:selected_stack_member_review_counts, counts)
         |> assign_stack_review_state(stack)
         |> assign(:show_stack_feedback_overlay, false)
         |> assign(:show_stack_detail, true)
         # Close the per-task panel so the two slide-ins don't stack.
         |> assign(:selected_task, nil)
         |> assign(:show_detail, false)}
    end
  end

  # Close the stack detail panel (T8 stage 1).
  def handle_event("close_stack_detail", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_stack, nil)
     |> assign(:selected_stack_members, [])
     |> assign(:selected_stack_member_review_counts, %{})
     |> assign_stack_review_state(nil)
     |> assign(:show_stack_feedback_overlay, false)
     |> assign(:show_stack_detail, false)
     |> assign(:stack_graph_expanded, false)}
  end

  # Stage-3 of task 019e2c27 (Stack-Level Review Rollup): toggle the
  # rollup-overlay visibility from the chrome "Needs feedback (N)" pill.
  # The overlay reads from `:selected_stack_open_review_requests` +
  # `:selected_stack_open_review_canvases`, both maintained by
  # `assign_stack_review_state/2` on every panel state transition (open,
  # member status change, PubSub reload). When the user clicks the pill we
  # refresh the snapshot once more so a long-open panel sees the freshest
  # data the moment the overlay appears — cheap (it's the same two queries
  # the pill already runs on PubSub) and removes a stale-state class of
  # bugs from this surface.
  def handle_event("open_stack_feedback_overlay", _params, socket) do
    next = !socket.assigns.show_stack_feedback_overlay

    socket =
      if next and socket.assigns.selected_stack do
        assign_stack_review_state(socket, socket.assigns.selected_stack)
      else
        socket
      end

    {:noreply, assign(socket, :show_stack_feedback_overlay, next)}
  end

  # Stage-3 of task 019e2c27: explicit close handler for the rollup
  # overlay. Backdrop click + overlay X + close button all wire here so
  # the dismiss path is one event regardless of the trigger. We only
  # touch `:show_stack_feedback_overlay` — the stack panel itself stays
  # open behind the overlay so closing the overlay returns the user
  # directly to the stack pane.
  def handle_event("close_stack_feedback_overlay", _params, socket) do
    {:noreply, reset_stack_feedback_overlay(socket)}
  end

  # Stage-4 of task 019e2c27: approve a single review item from the stack-
  # feedback overlay. Reuses `ReviewRequests.approve_item/2` (the same
  # entry point the per-task review panel uses — `approve_review_item`
  # handler at ~line 1480), then:
  #
  #   1. Optimistically drops the item from
  #      `:selected_stack_open_review_requests` so the row vanishes
  #      immediately (the request itself is dropped when its last pending
  #      item is removed — matches `maybe_resolve_request/1`'s contract).
  #   2. Decrements `:selected_stack_pending_review_count` only when the
  #      request itself was resolved (i.e. the optimistic removal dropped
  #      a whole RR), so the chrome pill mirrors the overlay list.
  #   3. Server-state convergence still happens via the existing
  #      `:review_request_resolved` PubSub handler (`reload_selected_stack`
  #      → `assign_stack_review_state`), so if our optimistic guess is
  #      off the next broadcast snaps everything back into shape.
  def handle_event("stack_feedback_approve_item", %{"id" => item_id}, socket) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.approve_item(item_id, reviewed_by) do
      {:ok, _item} ->
        {:noreply, drop_overlay_item(socket, item_id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to approve review item.")}
    end
  end

  # Stage-4 of task 019e2c27: toggle the reject feedback textarea on a
  # specific item in the stack-feedback overlay. Mirrors the per-task
  # `toggle_review_feedback` shape (a MapSet of "open" item ids) but
  # scoped to the overlay so a row's textarea state does not bleed into
  # the per-task review panel below.
  def handle_event("toggle_stack_feedback_reject", %{"id" => item_id}, socket) do
    open = socket.assigns.stack_feedback_reject_open

    next =
      if MapSet.member?(open, item_id),
        do: MapSet.delete(open, item_id),
        else: MapSet.put(open, item_id)

    {:noreply, assign(socket, :stack_feedback_reject_open, next)}
  end

  # Stage-4 of task 019e2c27: capture textarea keystrokes for an item's
  # reject-feedback buffer. Lives in a Map keyed by item id so multiple
  # rows can be in-flight simultaneously without their drafts colliding.
  def handle_event(
        "update_stack_feedback_reject_text",
        %{"id" => item_id, "value" => text},
        socket
      ) do
    {:noreply,
     assign(
       socket,
       :stack_feedback_reject_text,
       Map.put(socket.assigns.stack_feedback_reject_text, item_id, text)
     )}
  end

  # Stage-4 of task 019e2c27: submit a reject + feedback for a single
  # review item from the overlay. Reuses `ReviewRequests.reject_item/3`
  # (same call the per-task `submit_review_feedback` handler makes). On
  # success applies the same optimistic drop + count decrement as the
  # approve handler and clears the in-flight draft for this item id; the
  # `:review_request_resolved` PubSub handler still wins on conflict.
  def handle_event(
        "stack_feedback_reject_item",
        %{"id" => item_id} = params,
        socket
      ) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    feedback =
      Map.get(params, "feedback") ||
        Map.get(socket.assigns.stack_feedback_reject_text, item_id, "")

    case ReviewRequests.reject_item(item_id, reviewed_by, feedback) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(
           :stack_feedback_reject_open,
           MapSet.delete(socket.assigns.stack_feedback_reject_open, item_id)
         )
         |> assign(
           :stack_feedback_reject_text,
           Map.delete(socket.assigns.stack_feedback_reject_text, item_id)
         )
         |> drop_overlay_item(item_id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to submit feedback.")}
    end
  end

  # Stub abandon handler (T8 stage 1). Calls Stacks.abandon_stack/2 and
  # closes the panel on success. Confirm-modal UX is deferred — for
  # stage 1 we wire the event end-to-end so the button is functional.
  def handle_event("abandon_stack", _params, %{assigns: %{selected_stack: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("abandon_stack", _params, socket) do
    case Stacks.abandon_stack(socket.assigns.selected_stack) do
      {:ok, _stack} ->
        {:noreply,
         socket
         |> assign(:selected_stack, nil)
         |> assign(:selected_stack_members, [])
         |> assign(:selected_stack_member_review_counts, %{})
         |> assign_stack_review_state(nil)
         |> assign(:show_stack_feedback_overlay, false)
         |> assign(:show_stack_detail, false)
         |> assign(:stack_graph_expanded, false)
         |> put_flash(:info, "Stack abandoned.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not abandon stack.")}
    end
  end

  # Stack-level "Start Planning" cascade (T8 stage 3). Mirrors the per-task
  # "Start Planning" button at the stack level: calls Stacks.start_planning/1.
  # Under Stack v2 wave-gated dispatch (ADR 0045 / task 019f487e), manual
  # mode dispatches wave 0 only; downstream waves advance when each
  # member's plan approves. On success/partial, reloads `:selected_stack` +
  # `:selected_stack_members` so the panel reflects new member statuses.
  # `:noop` short-circuits are surfaced as an :info flash without touching
  # any member.
  def handle_event("start_stack_planning", _params, %{assigns: %{selected_stack: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("start_stack_planning", _params, socket) do
    case Stacks.start_planning(socket.assigns.selected_stack) do
      {:ok, %{stack: stack, planning: planning}} ->
        {members, counts} = load_stack_member_panel_data(stack)

        {:noreply,
         socket
         |> assign(:selected_stack, stack)
         |> assign(:selected_stack_members, members)
         |> assign(:selected_stack_member_review_counts, counts)
         |> assign_stack_review_state(stack)
         |> put_flash(
           :info,
           "Started planning for #{length(planning)} #{member_word(length(planning))}."
         )}

      {:partial, %{stack: stack, planning: planning, errors: errors}} ->
        {members, counts} = load_stack_member_panel_data(stack)

        {:noreply,
         socket
         |> assign(:selected_stack, stack)
         |> assign(:selected_stack_members, members)
         |> assign(:selected_stack_member_review_counts, counts)
         |> assign_stack_review_state(stack)
         |> put_flash(
           :error,
           "Started planning for #{length(planning)} #{member_word(length(planning))}; " <>
             "#{length(errors)} failed to transition."
         )}

      {:noop, :already_in_flight} ->
        {:noreply, put_flash(socket, :info, "Planning is already in flight for this stack.")}

      {:error, :cycle, _path} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot start planning: this stack has a dependency cycle."
         )}

      {:error, :cross_stack_dep, _payload} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Cannot start planning: a member depends on a task outside this stack."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start planning for this stack.")}
    end
  end

  def handle_event("close_detail", _params, socket) do
    unsubscribe_execution_space(socket)

    {:noreply,
     socket
     |> assign(:selected_task, nil)
     |> assign(:selected_task_canvases, [])
     |> assign(:show_detail, false)
     |> assign(:execution_space_id, nil)
     |> assign(:execution_log, [])
     |> assign(:execution_participant, nil)
     |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
     |> assign(:steering_upload_previews, [])
     |> assign(:steering_attachment_intended, false)
     |> assign(:pending_reviews, [])
     |> assign(:superseded_reviews, [])
     |> assign(:review_canvases, %{})
     |> assign(:review_output_ids, MapSet.new())
     |> assign(:output_canvases, [])
     |> assign(:active_review_canvas, nil)
     |> assign(:stack_graph_expanded, false)
     |> assign(:confirm_delete, false)
     |> assign(:edit_mode, false)
     |> push_patch(to: ~p"/tasks")}
  end

  # Linked-canvases strip — × button on each chip (stage 5 of
  # task_attach_canvas). Delegates to the CanvasAttachments context,
  # refreshes the local strip, and broadcasts `:task_updated` on the
  # board topic so any sibling LiveView session viewing the same task
  # (multi-tab, multi-user) re-renders its strip within the 2s budget.
  # Idempotent — `{:error, :not_found}` from a duplicate click is a
  # no-op (the strip is already in the correct state).
  #
  # `detach_canvas/3` takes the actor explicitly (task 019fb581 stage 3);
  # a `{:error, :task_forbidden}` from a session that can see the task but
  # may not write it lands in the same no-op arm the duplicate click does,
  # and the re-read below puts the chip straight back.
  def handle_event("detach_canvas", %{"canvas-id" => canvas_id}, socket) do
    case socket.assigns[:selected_task] do
      %Task{id: task_id} = task ->
        actor = {:user, socket.assigns[:current_user_id]}
        _ = CanvasAttachments.detach_canvas(actor, task_id, canvas_id)
        Tasks.broadcast_board({:task_updated, task})

        {:noreply, assign(socket, :selected_task_canvases, load_attached_canvases(task_id))}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Inline edit events (title / generic field / description) ────────────

  # Detail-panel edit-mode toggle. Flips `:edit_mode`. When toggling OFF,
  # also clear any in-progress inline edits (`:editing_task_title_id`,
  # `:editing_description`) so disengaging edit mode doesn't leave a
  # stranded textarea visible. The actual gating of edit affordances on
  # `@edit_mode` happens in stage 2; stage 1 only wires the toggle state.
  def handle_event("toggle_edit_mode", _params, socket) do
    new_edit_mode = !socket.assigns.edit_mode

    socket =
      if new_edit_mode do
        assign(socket, :edit_mode, true)
      else
        socket
        |> assign(:edit_mode, false)
        |> assign(:editing_task_title_id, nil)
        |> assign(:editing_description, false)
      end

    {:noreply, socket}
  end

  # Configure-a-deploy-target affordance fires when the readonly value block
  # is in `:none` state (see `deploy_target_display/1`). Flips the detail pane
  # into `edit_mode` so the existing edit-mode dropdown at the deploy_target
  # form becomes interactive. Landing in edit mode is enough — scrolling to
  # the form is out of scope for the consolidation stage.
  def handle_event("open_deploy_target_config", _params, socket) do
    {:noreply, assign(socket, :edit_mode, true)}
  end

  # Server-side defense-in-depth: when @edit_mode is false, the detail-panel
  # affordances that would emit these events aren't rendered (gated in
  # tasks_live.html.heex), but a stray invocation from elsewhere (kanban,
  # legacy hook, devtools) must not be able to mutate the task. Each
  # write-path handler below has a `%{assigns: %{edit_mode: false}}` clause
  # that no-ops before the v1 implementation runs.
  def handle_event("start_edit_title", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event("start_edit_title", %{"task-id" => task_id}, socket) do
    {:noreply, assign(socket, :editing_task_title_id, task_id)}
  end

  # Meeting-triage `promote_task` (task 019f5e2b-8d29 stage 2 + M5b/019f6e2c stage 2).
  # Clears the `needs_promotion` flag on a filed-under-cap task via
  # `Platform.Tasks.promote/1` — the standard `update_task/2` broadcast
  # fires, so the kanban badge disappears without a full reload. When
  # the task was still in `backlog`, `promote/1` also transitions
  # `status: "planning"` atomically so the router dispatches a planner
  # without a second write — surface a `Promoted to planning` info flash
  # iff the status actually moved. Non-transition promotions (already
  # in planning, etc.) are silent — the badge disappears is feedback enough.
  #
  # Guarded on `needs_promotion == true`: promoting an already-clear
  # task is a no-op (idempotent) and does not spam kanban subscribers
  # with a redundant :task_updated. Unknown ids surface a flash;
  # non-flagged tasks silently no-op (button ought not to render, but
  # this is defense-in-depth against a stale client).
  def handle_event("promote_task", %{"id" => task_id}, socket) do
    socket =
      case Tasks.get_task_record(task_id) do
        nil ->
          put_flash(socket, :error, "Task not found.")

        %{needs_promotion: false} ->
          # Already promoted — nothing to do. Refresh the board so a
          # stale card that shipped a lingering badge disappears.
          refresh_board(socket)

        task ->
          case Tasks.promote(task) do
            {:ok, updated} ->
              socket
              |> refresh_board()
              |> reload_selected_task()
              |> maybe_flash_promotion_transition(task, updated)

            {:error, _changeset} ->
              put_flash(socket, :error, "Could not promote task.")
          end
      end

    {:noreply, socket}
  end

  # Only flash on an actual status change (backlog → planning) so a
  # promote-in-planning is silent. The badge-disappears + kanban card
  # reflow is sufficient feedback for the flag-only case.
  defp maybe_flash_promotion_transition(socket, %{status: same}, %{status: same}), do: socket

  defp maybe_flash_promotion_transition(socket, %{status: "backlog"}, %{status: "planning"}),
    do: put_flash(socket, :info, "Promoted to planning.")

  defp maybe_flash_promotion_transition(socket, _before, _after), do: socket

  def handle_event("update_task_title", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event("update_task_title", %{"value" => raw_title, "task-id" => task_id}, socket) do
    new_title = String.trim(raw_title)

    socket =
      cond do
        new_title == "" ->
          socket
          |> assign(:editing_task_title_id, nil)
          |> put_flash(:error, "Title cannot be empty.")

        true ->
          case Tasks.get_task_record(task_id) do
            nil ->
              socket
              |> assign(:editing_task_title_id, nil)
              |> put_flash(:error, "Task not found.")

            task ->
              if task.title == new_title do
                # No-op: same title, just clear the editing state.
                assign(socket, :editing_task_title_id, nil)
              else
                case Tasks.update_task(task, %{title: new_title}) do
                  {:ok, _updated} ->
                    # Refresh the originating session immediately. The broadcast
                    # also fires for any other connected LV sessions.
                    socket
                    |> assign(:editing_task_title_id, nil)
                    |> refresh_board()
                    |> reload_selected_task()

                  {:error, _changeset} ->
                    socket
                    |> assign(:editing_task_title_id, nil)
                    |> put_flash(:error, "Could not update title.")
                end
              end
          end
      end

    {:noreply, socket}
  end

  # ── Generic field update (priority / deploy_target / sponsor_user_id) ──
  #
  # Whitelisted to avoid arbitrary attribute writes from the wire. Empty
  # strings normalize to `nil` (used by deploy_target's "(none)" option
  # and by sponsor_user_id's "No Sponsor" option). Other unknown fields
  # flash a generic error.
  #
  # `assignee_id` is intentionally NOT in this list. Per ADR 0044, the
  # canonical writer for assignee is `save_assignees` (Configure modal),
  # which routes through `Tasks.set_phase_assignees/2` so the write
  # survives the next phase transition. The detail pane's "Current
  # assignee" badge is a read-only derived view.

  @editable_task_fields ~w(priority deploy_target sponsor_user_id)

  def handle_event("update_task_field", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event(
        "update_task_field",
        %{"field" => field, "value" => value, "task-id" => task_id},
        socket
      )
      when field in @editable_task_fields do
    normalized = if value == "", do: nil, else: value

    attrs = %{String.to_existing_atom(field) => normalized}

    socket =
      case Tasks.get_task_record(task_id) do
        nil ->
          put_flash(socket, :error, "Task not found.")

        task ->
          # Thread the acting human as the actor so the M4 (019f9251)
          # sponsor-assigned producer can skip the self-sponsor case (a user
          # assigning themselves gets no inbox row / push).
          actor = {:user, socket.assigns[:current_user_id]}

          case Tasks.update_task(task, attrs, actor: actor) do
            {:ok, _updated} ->
              # Refresh the originating session immediately so the change is
              # visible without waiting for the broadcast round-trip.
              socket
              |> refresh_board()
              |> reload_selected_task()

            {:error, %Ecto.Changeset{} = cs} ->
              put_flash(
                socket,
                :error,
                "Could not update #{field}: #{changeset_error(cs, field)}"
              )

            {:error, _} ->
              put_flash(socket, :error, "Could not update #{field}.")
          end
      end

    {:noreply, socket}
  end

  def handle_event("update_task_field", %{"field" => field}, socket) do
    {:noreply, put_flash(socket, :error, "Field '#{field}' is not editable.")}
  end

  # ── Description editor events (toggle render ↔ textarea) ───────────────
  #
  # Boolean assign rather than per-task id because only one detail panel is
  # open at a time. Save persists via Tasks.update_task/2 (broadcast then
  # refreshes the description for any other connected LV session); Cancel
  # just discards local state without touching the DB.

  def handle_event("start_edit_description", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event("start_edit_description", _params, socket) do
    {:noreply, assign(socket, :editing_description, true)}
  end

  def handle_event("cancel_edit_description", _params, socket) do
    {:noreply, assign(socket, :editing_description, false)}
  end

  def handle_event("save_description", _params, %{assigns: %{edit_mode: false}} = socket),
    do: {:noreply, socket}

  def handle_event("save_description", %{"description" => new_desc}, socket) do
    task = socket.assigns.selected_task

    socket =
      cond do
        is_nil(task) ->
          assign(socket, :editing_description, false)

        task.description == new_desc ->
          # No-op when unchanged; just close the editor.
          assign(socket, :editing_description, false)

        true ->
          case Tasks.update_task(task, %{description: new_desc}) do
            {:ok, _updated} ->
              # Update the local assigns immediately so the LV re-renders the
              # new markdown in the same response — the broadcast also fires
              # but lands as a separate handle_info on this and other LV
              # sessions; relying on it for the originating session would
              # leave the textarea visible until the next tick.
              socket
              |> assign(:editing_description, false)
              |> reload_selected_task()

            {:error, _changeset} ->
              socket
              |> assign(:editing_description, false)
              |> put_flash(:error, "Could not save description.")
          end
      end

    {:noreply, socket}
  end

  # ── Task deletion events ────────────────────────────────────────────────

  def handle_event("request_delete_task", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, true)}
  end

  def handle_event("select_task_and_delete", %{"id" => task_id}, socket) do
    {:noreply,
     socket
     |> assign(:confirm_delete, true)
     |> assign(:open_task_actions_id, nil)
     |> push_patch(to: ~p"/tasks/#{task_id}")}
  end

  def handle_event("cancel_delete_task", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, false)}
  end

  def handle_event("confirm_delete_task", _params, socket) do
    task = socket.assigns.selected_task

    socket =
      if task do
        case Tasks.soft_delete_task(task) do
          {:ok, _deleted} ->
            unsubscribe_execution_space(socket)

            socket
            |> assign(:selected_task, nil)
            |> assign(:show_detail, false)
            |> assign(:confirm_delete, false)
            |> assign(:execution_space_id, nil)
            |> assign(:execution_log, [])
            |> assign(:execution_participant, nil)
            |> put_flash(:info, "Task deleted.")
            |> refresh_board()
            |> push_patch(to: ~p"/tasks")

          {:error, :restricted_status} ->
            socket
            |> assign(:confirm_delete, false)
            |> put_flash(:error, "Cannot delete a task that is #{status_label(task.status)}.")

          {:error, _reason} ->
            socket
            |> assign(:confirm_delete, false)
            |> put_flash(:error, "Failed to delete task.")
        end
      else
        assign(socket, :confirm_delete, false)
      end

    {:noreply, socket}
  end

  def handle_event("transition_task", %{"id" => task_id, "status" => new_status}, socket) do
    task = Tasks.get_task_detail(task_id)

    socket =
      if task do
        # LiveView is user-facing regardless of session state — thread the
        # `{:user, _}` actor through so `Tasks.require_approved_plan_for/3`
        # can fire the sponsor-bypass rule (ADR 0042 §sponsor-bypass, task
        # 019f6380). If `current_user_id` is `nil` (defensive edge), the
        # actor is `{:user, nil}` which still pattern-matches `{:user, _}`;
        # bypass eligibility is protected by the sponsor+no-agent
        # predicate, not by session authentication.
        case Tasks.transition_task(task, new_status, {:user, socket.assigns[:current_user_id]}) do
          {:ok, updated} ->
            socket
            |> put_flash(:info, "Task moved to #{new_status}.")
            |> refresh_board()
            |> assign_selected_task(Tasks.get_task_detail(updated.id))

          {:error, :invalid_transition} ->
            put_flash(socket, :error, "Cannot transition to #{new_status} from #{task.status}.")

          {:error, :no_approved_plan} ->
            put_flash(
              socket,
              :error,
              "Cannot start execution: this task has no approved plan. Create and approve a plan first."
            )

          {:error, :no_deploy_target_resolved} ->
            put_flash(
              socket,
              :error,
              "Cannot deploy: no deploy target set. Set one on this task or configure a project default."
            )

          {:error, reason} ->
            put_flash(socket, :error, "Transition failed: #{inspect(reason)}")
        end
      else
        put_flash(socket, :error, "Task not found.")
      end

    {:noreply, socket}
  end

  # ── Per-phase assignee modal ─────────────────────────────────────────────

  def handle_event("open_assignee_modal", _params, socket) do
    initial_mode =
      case socket.assigns.selected_task do
        %{phase_assignees: pa} when is_map(pa) and map_size(pa) > 0 ->
          if all_phases_same_agent?(pa), do: :simple, else: :advanced

        _ ->
          :simple
      end

    {:noreply,
     socket
     |> assign(:show_assignee_modal, true)
     |> assign(:assignee_modal_mode, initial_mode)}
  end

  def handle_event("close_assignee_modal", _params, socket) do
    {:noreply, assign(socket, :show_assignee_modal, false)}
  end

  def handle_event("set_assignee_modal_mode", %{"mode" => mode}, socket) do
    next =
      case mode do
        "advanced" -> :advanced
        _ -> :simple
      end

    {:noreply, assign(socket, :assignee_modal_mode, next)}
  end

  def handle_event("save_assignees", %{"assignees" => params}, socket) do
    task = socket.assigns.selected_task

    if is_nil(task) do
      {:noreply, socket}
    else
      mode = socket.assigns.assignee_modal_mode

      attrs_by_phase =
        case mode do
          :simple ->
            id = Map.get(params, "all", "")
            entry = phase_entry(id)
            %{"planning" => entry, "execution" => entry, "review" => entry}

          :advanced ->
            %{
              "planning" => phase_entry(Map.get(params, "planning", "")),
              "execution" => phase_entry(Map.get(params, "execution", "")),
              "review" => phase_entry(Map.get(params, "review", ""))
            }
        end

      # An individual assignment from this modal protects the task from
      # stack-level fan-out — stamp `metadata["assignee_override"] = true`
      # so `Stacks.set_stack_phase_assignees/2` skips it.
      result =
        with {:ok, updated} <- Tasks.set_phase_assignees(task, attrs_by_phase) do
          Tasks.update_task(updated, %{
            metadata: Map.put(updated.metadata || %{}, "assignee_override", true)
          })
        end

      case result do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:show_assignee_modal, false)
           |> refresh_board()
           |> assign_selected_task(Tasks.get_task_detail(task.id))
           |> put_flash(:info, "Assignees saved.")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save assignees.")}
      end
    end
  end

  # ── Reopen-with-feedback modal ──────────────────────────────────────────

  def handle_event("open_reopen_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reopen_modal, true)
     |> assign(:reopen_reason, "")}
  end

  def handle_event("close_reopen_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_reopen_modal, false)
     |> assign(:reopen_reason, "")}
  end

  def handle_event("reopen_reason_changed", params, socket) do
    # The textarea phx-change can ship the value either as a top-level
    # `"reason"` string or wrapped under a form prefix; accept either to
    # stay defensive against changes to the wrapping form shape.
    reason =
      cond do
        is_binary(Map.get(params, "reason")) -> Map.get(params, "reason")
        is_binary(Map.get(params, "value")) -> Map.get(params, "value")
        true -> ""
      end

    {:noreply, assign(socket, :reopen_reason, reason)}
  end

  def handle_event("submit_reopen", params, socket) do
    task = socket.assigns.selected_task

    # Allow the form-submitted `reason` to override the assign for the rare
    # race where phx-change hasn't landed yet, but fall back to the assign
    # if the form payload omits it.
    reason =
      case Map.get(params, "reason") do
        v when is_binary(v) -> v
        _ -> socket.assigns.reopen_reason
      end

    cond do
      is_nil(task) ->
        {:noreply,
         socket
         |> assign(:show_reopen_modal, false)
         |> assign(:reopen_reason, "")
         |> put_flash(:error, "No task selected.")}

      String.trim(reason || "") == "" ->
        # Defensive: the Submit button is disabled client-side, but if the
        # event makes it through we keep the modal open and surface the
        # validation error rather than silently no-oping.
        {:noreply, put_flash(socket, :error, "A reason is required to reopen the task.")}

      true ->
        by_user_id = socket.assigns[:current_user_id]

        case Tasks.reopen_with_feedback(task.id, reason, by_user_id) do
          {:ok, _task} ->
            {:noreply,
             socket
             |> assign(:show_reopen_modal, false)
             |> assign(:reopen_reason, "")
             |> put_flash(:info, "Task reopened.")
             |> refresh_board()
             |> reload_selected_task()}

          {:error, :reason_required} ->
            {:noreply, put_flash(socket, :error, "A reason is required to reopen the task.")}

          {:error, :not_done} ->
            {:noreply,
             socket
             |> assign(:show_reopen_modal, false)
             |> assign(:reopen_reason, "")
             |> put_flash(:error, "Only tasks in `done` can be reopened.")
             |> refresh_board()
             |> reload_selected_task()}

          {:error, :no_plan} ->
            {:noreply,
             socket
             |> assign(:show_reopen_modal, false)
             |> assign(:reopen_reason, "")
             |> put_flash(:error, "Cannot reopen: this task has no active plan to reject.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Reopen failed: #{inspect(reason)}")}
        end
    end
  end

  # ── Return-to-planning modal (supersede current plan) ───────────────────

  def handle_event("open_supersede_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_supersede_modal, true)
     |> assign(:supersede_reason, "")}
  end

  def handle_event("close_supersede_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_supersede_modal, false)
     |> assign(:supersede_reason, "")}
  end

  def handle_event("supersede_reason_changed", params, socket) do
    # Mirror `reopen_reason_changed`: accept either a top-level `reason`
    # string or a `value` fallback so a wrapping-form shape change doesn't
    # silently drop keystrokes.
    reason =
      cond do
        is_binary(Map.get(params, "reason")) -> Map.get(params, "reason")
        is_binary(Map.get(params, "value")) -> Map.get(params, "value")
        true -> ""
      end

    {:noreply, assign(socket, :supersede_reason, reason)}
  end

  def handle_event("submit_supersede", params, socket) do
    task = socket.assigns.selected_task

    reason =
      case Map.get(params, "reason") do
        v when is_binary(v) -> v
        _ -> socket.assigns.supersede_reason
      end

    cond do
      is_nil(task) ->
        {:noreply,
         socket
         |> assign(:show_supersede_modal, false)
         |> assign(:supersede_reason, "")
         |> put_flash(:error, "No task selected.")}

      String.trim(reason || "") == "" ->
        # Client-side submit is disabled while blank; keep the modal open
        # and surface the validation error if the event still lands.
        {:noreply,
         put_flash(socket, :error, "A reason is required to return the task to planning.")}

      true ->
        by_actor_id = socket.assigns[:current_user_id]

        case Tasks.supersede_current_plan(task.id, reason, by_actor_id) do
          {:ok, _task} ->
            {:noreply,
             socket
             |> assign(:show_supersede_modal, false)
             |> assign(:supersede_reason, "")
             |> put_flash(:info, "Task returned to planning.")
             |> refresh_board()
             |> reload_selected_task()}

          {:error, :reason_required} ->
            {:noreply,
             put_flash(socket, :error, "A reason is required to return the task to planning.")}

          {:error, :not_in_flight} ->
            {:noreply,
             socket
             |> assign(:show_supersede_modal, false)
             |> assign(:supersede_reason, "")
             |> put_flash(:error, "Only in-flight tasks can be returned to planning.")
             |> refresh_board()
             |> reload_selected_task()}

          {:error, :no_active_plan} ->
            {:noreply,
             socket
             |> assign(:show_supersede_modal, false)
             |> assign(:supersede_reason, "")
             |> put_flash(:error, "Cannot return to planning: no active plan to supersede.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Return to planning failed: #{inspect(reason)}")}
        end
    end
  end

  # ── Stack-level assignee modal (ADR 0041) ───────────────────────────────

  def handle_event(
        "open_stack_assignee_modal",
        _params,
        %{assigns: %{selected_stack: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("open_stack_assignee_modal", _params, socket) do
    initial_mode =
      case Stacks.stack_phase_assignees(socket.assigns.selected_stack) do
        pa when is_map(pa) and map_size(pa) > 0 ->
          if all_phases_same_agent?(pa), do: :simple, else: :advanced

        _ ->
          :simple
      end

    {:noreply,
     socket
     |> assign(:show_stack_assignee_modal, true)
     |> assign(:stack_assignee_modal_mode, initial_mode)}
  end

  def handle_event("close_stack_assignee_modal", _params, socket) do
    {:noreply, assign(socket, :show_stack_assignee_modal, false)}
  end

  def handle_event("set_stack_assignee_modal_mode", %{"mode" => mode}, socket) do
    next =
      case mode do
        "advanced" -> :advanced
        _ -> :simple
      end

    {:noreply, assign(socket, :stack_assignee_modal_mode, next)}
  end

  def handle_event("save_stack_assignees", %{"assignees" => params}, socket) do
    stack = socket.assigns.selected_stack

    if is_nil(stack) do
      {:noreply, socket}
    else
      mode = socket.assigns.stack_assignee_modal_mode

      attrs_by_phase =
        case mode do
          :simple ->
            entry = phase_entry(Map.get(params, "all", ""))
            %{"planning" => entry, "execution" => entry, "review" => entry}

          :advanced ->
            %{
              "planning" => phase_entry(Map.get(params, "planning", "")),
              "execution" => phase_entry(Map.get(params, "execution", "")),
              "review" => phase_entry(Map.get(params, "review", ""))
            }
        end

      case Stacks.set_stack_phase_assignees(stack, attrs_by_phase) do
        {:ok, %{percolated: percolated, skipped: skipped}} ->
          {:noreply,
           socket
           |> assign(:show_stack_assignee_modal, false)
           |> refresh_board()
           |> reload_selected_stack()
           |> put_flash(
             :info,
             "Stack assignees saved — #{length(percolated)} member(s) updated" <>
               skipped_suffix(skipped)
           )}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to save stack assignees.")}
      end
    end
  end

  def handle_event("clear_member_override", %{"id" => task_id}, socket) do
    case Stacks.clear_member_override(task_id) do
      {:ok, _task} ->
        {:noreply,
         socket
         |> refresh_board()
         |> reload_selected_stack()
         |> put_flash(:info, "Member returned to inheriting the stack default.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not clear the member override.")}
    end
  end

  defp skipped_suffix([]), do: "."

  defp skipped_suffix(skipped),
    do: ", #{length(skipped)} with an individual override left untouched."

  # Reload `:selected_stack` + `:selected_stack_members` from the DB so the
  # stack detail panel reflects writes (stack-level assignment, override
  # clears). No-op when no stack panel is open.
  defp reload_selected_stack(%{assigns: %{selected_stack: nil}} = socket), do: socket

  defp reload_selected_stack(%{assigns: %{selected_stack: %Stack{id: id}}} = socket) do
    case Stacks.get_stack(id) do
      nil ->
        socket
        |> assign(:selected_stack, nil)
        |> assign(:selected_stack_members, [])
        |> assign(:selected_stack_member_review_counts, %{})
        |> assign_stack_review_state(nil)
        |> assign(:show_stack_feedback_overlay, false)
        |> assign(:show_stack_detail, false)
        |> assign(:stack_graph_expanded, false)

      %Stack{} = stack ->
        {members, counts} = load_stack_member_panel_data(stack)

        socket
        |> assign(:selected_stack, stack)
        |> assign(:selected_stack_members, members)
        |> assign(:selected_stack_member_review_counts, counts)
        |> assign_stack_review_state(stack)
    end
  end

  # Stage-2 of task 019e2c25 (badge wiring): preload `:plans` on the stack's
  # members so `Tasks.needs_human_action?/2` can resolve the
  # `:plan_pending_review` branch off the struct, and compute the
  # pending-review-request counts (Map of member id → integer) used by the
  # same predicate. Centralised here so every site that loads the panel's
  # member list (`open_stack_detail`, `start_stack_planning`,
  # `reload_selected_stack`) feeds the assigns the badge depends on.
  defp load_stack_member_panel_data(%Stack{} = stack) do
    members = stack |> Stacks.members() |> Repo.preload(:plans)
    counts = pending_review_counts(members)
    {members, counts}
  end

  # Stage-3 of task 019e2c27 (rollup overlay): set the three assigns that
  # back the stack-feedback chrome pill AND its overlay in one place so the
  # COUNT (pill) and the LIST (overlay rows) are always derived from the
  # same snapshot:
  #
  #   * `:selected_stack_pending_review_count` — integer powering the pill.
  #   * `:selected_stack_open_review_requests` — list of `%ReviewRequest{}`
  #     with `:items` preloaded AND a virtual `:member_task` field carrying
  #     the owning `%Task{}` (used by the overlay to render the row label
  #     "{member.title}").
  #   * `:selected_stack_open_review_canvases` — `%{canvas_id => %Canvas{}}`
  #     for every canvas referenced by an item, pre-loaded so the template
  #     stays DB-free.
  #
  # Pass `nil` for `stack` to reset all three assigns to empty (closed-
  # panel state). This is the only path that should touch these assigns
  # outside the explicit overlay toggle handler.
  defp assign_stack_review_state(socket, nil) do
    socket
    |> sync_stack_review_request_subscriptions(MapSet.new())
    |> assign(:selected_stack_pending_review_count, 0)
    |> assign(:selected_stack_open_review_requests, [])
    |> assign(:selected_stack_open_review_canvases, %{})
  end

  defp assign_stack_review_state(socket, %Stack{} = stack) do
    members = Stacks.members(stack)
    requests = Stacks.list_open_review_requests(stack)
    members_by_id = Map.new(members, &{&1.id, &1})

    enriched =
      Enum.map(requests, fn rr ->
        Map.put(rr, :member_task, Map.get(members_by_id, rr.task_id))
      end)

    canvases = load_review_canvases(requests)

    socket
    |> sync_stack_review_request_subscriptions(MapSet.new(members, & &1.id))
    |> assign(:selected_stack_pending_review_count, length(requests))
    |> assign(:selected_stack_open_review_requests, enriched)
    |> assign(:selected_stack_open_review_canvases, canvases)
  end

  # Stage-5 of task 019e2c27: keep the per-stack-member
  # review_requests:<task_id> subscription set in sync with the open
  # stack-detail panel's member set. Subscribes to any member we are not
  # yet following AND unsubscribes from members that have left the panel
  # (close, abandon, select_task, member removed via reload). On unsubscribe
  # we skip task_ids that are ALSO held by the board-level
  # `:review_request_subscriptions` set so the board's live-update
  # contract (badges, count badges) is not collateral-damaged when the
  # stack panel closes. Idempotent: subscribing twice to the same topic
  # is a no-op in Phoenix.PubSub. No-op on disconnected socket.
  defp sync_stack_review_request_subscriptions(socket, desired) do
    if connected?(socket) do
      current = socket.assigns[:stack_review_request_subscriptions] || MapSet.new()
      board = socket.assigns[:review_request_subscriptions] || MapSet.new()

      to_add = MapSet.difference(desired, current)
      to_drop = MapSet.difference(MapSet.difference(current, desired), board)

      Enum.each(to_add, &ReviewRequests.subscribe_for_task/1)
      Enum.each(to_drop, &ReviewRequests.unsubscribe_for_task/1)

      assign(socket, :stack_review_request_subscriptions, desired)
    else
      socket
    end
  end

  # Stage-4 of task 019e2c27: full reset of the stack-feedback overlay
  # surface state. Used by `close_stack_feedback_overlay` and every other
  # site that drops the overlay (stack panel close, stack abandon, etc.)
  # so a half-typed reject draft doesn't survive across opens.
  defp reset_stack_feedback_overlay(socket) do
    socket
    |> assign(:show_stack_feedback_overlay, false)
    |> assign(:stack_feedback_reject_open, MapSet.new())
    |> assign(:stack_feedback_reject_text, %{})
  end

  # Stage-4 of task 019e2c27: optimistic per-item removal in the overlay
  # after an approve / reject lands. Walks
  # `:selected_stack_open_review_requests`, drops the matching item, and
  # drops any RR that loses its last item. The pending-review count is
  # recomputed from the resulting list so the chrome pill mirrors the
  # overlay's row count exactly. The `:review_request_resolved` PubSub
  # broadcast still fires from `maybe_resolve_request/1` on the server,
  # and the existing handler at ~line 1947 runs
  # `reload_selected_stack/1` (→ `assign_stack_review_state/2`) to
  # converge on server state, so any optimistic drift is reconciled.
  defp drop_overlay_item(socket, item_id) do
    requests = socket.assigns.selected_stack_open_review_requests

    pruned =
      requests
      |> Enum.map(fn rr ->
        items = Enum.reject(rr.items || [], &(&1.id == item_id))
        Map.put(rr, :items, items)
      end)
      |> Enum.reject(&((&1.items || []) == []))

    socket
    |> assign(:selected_stack_open_review_requests, pruned)
    |> assign(:selected_stack_pending_review_count, length(pruned))
  end

  defp phase_entry(""), do: %{}
  defp phase_entry(nil), do: %{}
  defp phase_entry(agent_id), do: %{"assignee_id" => agent_id, "assignee_type" => "agent"}

  defp all_phases_same_agent?(pa) do
    ids =
      ~w(planning execution review)
      |> Enum.map(fn phase ->
        case Map.get(pa, phase) do
          %{"assignee_id" => id} -> id
          _ -> nil
        end
      end)

    case Enum.uniq(ids) do
      [_single] -> true
      _ -> false
    end
  end

  # Back-compat: the old single-select dropdown used the `assign_agent`
  # event. Forward it to the new path so any external clients still work.
  def handle_event("assign_agent", %{"agent_id" => agent_id}, socket) do
    task = socket.assigns.selected_task

    if task do
      entry = phase_entry(agent_id)
      attrs = %{"planning" => entry, "execution" => entry, "review" => entry}

      case Tasks.set_phase_assignees(task, attrs) do
        {:ok, _} ->
          {:noreply,
           socket
           |> refresh_board()
           |> assign_selected_task(Tasks.get_task_detail(task.id))}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to assign agent.")}
      end
    else
      {:noreply, socket}
    end
  end

  # ── Skill picker events ─────────────────────────────────────────────────

  def handle_event("attach_skill", %{"skill_id" => skill_id}, socket) do
    task = socket.assigns.selected_task

    if task && skill_id != "" do
      Skills.attach_skill(skill_id, "task", task.id)

      {:noreply,
       socket
       |> assign(:attached_skills, Skills.resolve_skills(task.id))
       |> assign(:available_skills, Skills.list_skills())}
    else
      {:noreply, socket}
    end
  end

  def handle_event("detach_skill", %{"skill_id" => skill_id}, socket) do
    task = socket.assigns.selected_task

    if task do
      Skills.detach_skill(skill_id, "task", task.id)

      {:noreply,
       socket
       |> assign(:attached_skills, Skills.resolve_skills(task.id))
       |> assign(:available_skills, Skills.list_skills())}
    else
      {:noreply, socket}
    end
  end

  # ── Plan review events ──────────────────────────────────────────────────

  def handle_event("approve_plan", %{"plan-id" => plan_id}, socket) do
    plan =
      case Platform.UUID.cast(plan_id) do
        {:ok, uuid} -> Repo.get(Plan, uuid)
        :error -> nil
      end

    if plan && plan.status == "pending_review" do
      approved_by = socket.assigns[:current_user_id]

      case Tasks.approve_plan(plan, approved_by) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Plan approved.")
           |> refresh_board()
           |> reload_selected_task()}

        {:error, reason} ->
          # Log the reason: an approval failure used to produce a constant
          # flash and NO server-side output at all, which made a production
          # outage effectively invisible.
          Logger.error(
            "approve_plan failed for plan #{plan.id} (task #{plan.task_id}): #{inspect(reason)}"
          )

          {:noreply, put_flash(socket, :error, "Failed to approve plan.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Plan not found or not pending review.")}
    end
  end

  def handle_event("reject_plan", %{"plan-id" => plan_id}, socket) do
    plan =
      case Platform.UUID.cast(plan_id) do
        {:ok, uuid} -> Repo.get(Plan, uuid)
        :error -> nil
      end

    if plan && plan.status == "pending_review" do
      rejected_by = socket.assigns[:current_user_id]

      case Tasks.reject_plan(plan, rejected_by) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(:info, "Plan rejected.")
           |> refresh_board()
           |> reload_selected_task()}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to reject plan.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Plan not found or not pending review.")}
    end
  end

  # ── Reject-with-feedback inline UI (task 019e30be stage 1) ──────────────
  # Three events drive the inline drawer that replaces the bare Reject
  # button on a pending_review plan card. The backend pipeline (Plan
  # `:rejection_reason` column, `Tasks.reject_plan/3`,
  # `ContextAssembler.find_latest_rejected_reason/1`, dispatch template
  # "Previous attempt" section) was already in place — the missing piece
  # was the LV wiring that collects a feedback string before calling the
  # 3-arity form. We mirror the gold-standard per-review-item handlers
  # (`toggle_review_feedback` / `update_review_feedback_text` /
  # `submit_review_feedback` ~line 1665) scaled down to one drawer at a
  # time.
  #
  # The legacy 2-arity `reject_plan` handler above stays as-is: the
  # existing test at `tasks_live_test.exs:1834` clicks it directly and
  # asserts the "Plan rejected." flash, and rejection without feedback is
  # still a valid power-user shortcut.

  def handle_event("toggle_reject_feedback", %{"plan-id" => plan_id}, socket) do
    next =
      if socket.assigns.reject_plan_open == plan_id do
        nil
      else
        plan_id
      end

    {:noreply,
     socket
     |> assign(:reject_plan_open, next)
     |> assign(:reject_plan_feedback_text, "")}
  end

  def handle_event("update_reject_feedback_text", %{"value" => text}, socket) do
    {:noreply, assign(socket, :reject_plan_feedback_text, text)}
  end

  def handle_event("submit_reject_with_feedback", %{"plan-id" => plan_id}, socket) do
    plan =
      case Platform.UUID.cast(plan_id) do
        {:ok, uuid} -> Repo.get(Plan, uuid)
        :error -> nil
      end

    feedback = String.trim(socket.assigns.reject_plan_feedback_text || "")

    cond do
      is_nil(plan) or plan.status != "pending_review" ->
        {:noreply, put_flash(socket, :error, "Plan not found or not pending review.")}

      feedback == "" ->
        # Keep the drawer open and surface a flash so the reviewer knows
        # the textarea isn't optional. Empty submissions are disallowed —
        # the whole point of this stage is to capture the "why" so the
        # next planner has context to work with (ContextAssembler reads
        # rejection_reason verbatim).
        {:noreply,
         put_flash(socket, :error, "Please describe what needs to change before rejecting.")}

      true ->
        rejected_by = socket.assigns[:current_user_id]

        case Tasks.reject_plan(plan, rejected_by, feedback) do
          {:ok, rejected_plan} ->
            # v2 (task 019e30be stage 1): also post the feedback into the
            # task's execution space so the planner re-dispatch picks it up
            # via AttentionRouter — same channel as steering / review-item
            # feedback. Mirrors review_requests.ex post_engagement pattern.
            # Invoked from the CALLER (not from inside Tasks.reject_plan/3)
            # because reject_plan is called from inside
            # Tasks.reopen_with_feedback/3's Repo.transaction/1 — wrapping a
            # chat post in that transaction would risk rolling back the
            # rejection if the post fails.
            #
            # The body itself was hoisted into Platform.Tasks.PlanRejection
            # (019f9b29-251e stage 2) so the architecture gate composes the
            # identical message from below the web layer.
            PlanRejection.post_feedback(rejected_plan, rejected_by, feedback)

            {:noreply,
             socket
             |> assign(:reject_plan_open, nil)
             |> assign(:reject_plan_feedback_text, "")
             |> put_flash(:info, "Plan rejected with feedback.")
             |> refresh_board()
             |> reload_selected_task()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to reject plan.")}
        end
    end
  end

  # ── Plan revision folding events ───────────────────────────────────────

  def handle_event("expand_plan", %{"plan-id" => plan_id}, socket) do
    case Platform.UUID.cast(plan_id) do
      {:ok, uuid} ->
        {:noreply,
         assign(socket, :expanded_plans, MapSet.put(socket.assigns.expanded_plans, uuid))}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("collapse_plan", %{"plan-id" => plan_id}, socket) do
    case Platform.UUID.cast(plan_id) do
      {:ok, uuid} ->
        {:noreply,
         assign(socket, :expanded_plans, MapSet.delete(socket.assigns.expanded_plans, uuid))}

      :error ->
        {:noreply, socket}
    end
  end

  # ── Review item events ──────────────────────────────────────────────────

  def handle_event("approve_review_item", %{"item-id" => item_id}, socket) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.approve_item(item_id, reviewed_by) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_board()
         |> reload_selected_task()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to approve review item.")}
    end
  end

  def handle_event(
        "submit_review_feedback",
        %{"item-id" => item_id, "feedback" => feedback},
        socket
      ) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.reject_item(item_id, reviewed_by, feedback) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(
           :review_items_feedback,
           Map.delete(socket.assigns.review_items_feedback, item_id)
         )
         |> assign(
           :review_feedback_open,
           MapSet.delete(socket.assigns.review_feedback_open, item_id)
         )
         |> refresh_board()
         |> reload_selected_task()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to submit feedback.")}
    end
  end

  def handle_event("toggle_superseded_reviews", _params, socket) do
    {:noreply,
     assign(socket, :superseded_reviews_expanded, !socket.assigns.superseded_reviews_expanded)}
  end

  def handle_event("toggle_review_feedback", %{"item-id" => item_id}, socket) do
    open = socket.assigns.review_feedback_open

    updated =
      if MapSet.member?(open, item_id),
        do: MapSet.delete(open, item_id),
        else: MapSet.put(open, item_id)

    {:noreply, assign(socket, :review_feedback_open, updated)}
  end

  def handle_event("open_review_canvas", %{"canvas-id" => canvas_id}, socket) do
    canvas = find_canvas_for_display(socket, canvas_id)
    {:noreply, assign(socket, :active_review_canvas, canvas)}
  end

  def handle_event("canvas_open", %{"canvas-id" => canvas_id}, socket) do
    canvas = find_canvas_for_display(socket, canvas_id)
    {:noreply, assign(socket, :active_review_canvas, canvas)}
  end

  def handle_event("close_review_canvas", _params, socket) do
    {:noreply, assign(socket, :active_review_canvas, nil)}
  end

  # Stack dep-graph fullscreen modal open/close (stage 3 of task 019f487e).
  # Mirrors the `open_review_canvas` / `close_review_canvas` shape above —
  # bare assign, no pattern-match on `:selected_stack` because the modal's
  # `:if` guard in the template already checks
  # `@stack_graph_expanded && @selected_stack_members not in [nil, []]`.
  def handle_event("open_stack_graph_expand", _params, socket) do
    {:noreply, assign(socket, :stack_graph_expanded, true)}
  end

  def handle_event("close_stack_graph_expand", _params, socket) do
    {:noreply, assign(socket, :stack_graph_expanded, false)}
  end

  def handle_event(
        "update_review_feedback_text",
        %{"item-id" => item_id, "value" => text},
        socket
      ) do
    {:noreply,
     assign(
       socket,
       :review_items_feedback,
       Map.put(socket.assigns.review_items_feedback, item_id, text)
     )}
  end

  # ── Bottom sheet events ─────────────────────────────────────────────────

  def handle_event("toggle_task_sheet", _params, socket) do
    showing = !socket.assigns.show_task_sheet
    socket = close_create_menus(socket)

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

  def handle_event("close_task_sheet", _params, socket) do
    {:noreply, assign(socket, :show_task_sheet, false)}
  end

  # ── New-Epic bottom sheet (task 019d60ca stage 3) ──────────────────────
  # Mirrors the toggle/close/validate/create quartet for tasks above. The
  # epic sheet has fewer fields (no plan/validation/assignee — epics are
  # pure containers) so the handlers are shorter, but the assign + form
  # lifecycle is identical.

  def handle_event("toggle_epic_sheet", _params, socket) do
    showing = !socket.assigns.show_epic_sheet
    socket = close_create_menus(socket)

    socket =
      if showing do
        socket
        |> assign(:show_epic_sheet, true)
        |> assign(
          :epic_form,
          to_form(
            Epic.changeset(%Epic{}, default_epic_form_attrs(socket)),
            as: "epic"
          )
        )
      else
        assign(socket, :show_epic_sheet, false)
      end

    {:noreply, socket}
  end

  def handle_event("close_epic_sheet", _params, socket) do
    {:noreply, assign(socket, :show_epic_sheet, false)}
  end

  def handle_event("validate_epic", %{"epic" => params}, socket) do
    changeset =
      %Epic{}
      |> Epic.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :epic_form, to_form(changeset, as: "epic"))}
  end

  def handle_event("create_epic", %{"epic" => params}, socket) do
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
        # create_epic/1 already broadcasts {:epic_created, epic}; refresh_board
        # will re-fetch and re-enrich the epics list via the existing pubsub
        # path. Closing the sheet + flashing happens here for immediacy.
        {:noreply,
         socket
         |> assign(:show_epic_sheet, false)
         |> put_flash(:info, "Epic created.")
         |> refresh_board()
         |> assign(
           :epics,
           enrich_epics(Tasks.list_epics_for_project(socket.assigns.selected_project_id))
         )}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:epic_form, to_form(changeset, as: "epic"))
         |> put_flash(:error, "Could not create epic. Check the form for errors.")}
    end
  end

  def handle_event("validate_task", %{"task" => params}, socket) do
    Logger.debug(
      "[TasksLive] validate_task: deploy_strategy_type=#{inspect(Map.get(params, "deploy_strategy_type"))}"
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

  def handle_event("toggle_validation_mode", %{"mode" => mode}, socket) do
    modes = socket.assigns.validation_modes

    updated =
      if MapSet.member?(modes, mode),
        do: MapSet.delete(modes, mode),
        else: MapSet.put(modes, mode)

    {:noreply, assign(socket, :validation_modes, updated)}
  end

  def handle_event("toggle_auto_merge", _params, socket) do
    {:noreply, assign(socket, :auto_merge_enabled, !socket.assigns.auto_merge_enabled)}
  end

  def handle_event("toggle_auto_approve_plan", _params, socket) do
    {:noreply,
     assign(socket, :auto_approve_plan_enabled, !socket.assigns.auto_approve_plan_enabled)}
  end

  def handle_event("create_task", %{"task" => params}, socket) do
    status =
      case Map.get(params, "action") do
        "create_and_plan" -> "planning"
        _ -> "backlog"
      end

    do_create_task(params, socket, status)
  end

  def handle_event("toggle_execution_log", _params, socket) do
    {:noreply, assign(socket, :execution_log_collapsed, !socket.assigns.execution_log_collapsed)}
  end

  # ── Kanban drag-and-drop ────────────────────────────────────────────────

  def handle_event("kanban_drop", %{"task_id" => task_id, "column" => column}, socket) do
    task = Tasks.get_task_detail(task_id)

    if is_nil(task) do
      {:noreply, put_flash(socket, :error, "Task not found.")}
    else
      # Thread the LiveView user actor into the drag-and-drop drop so
      # `Tasks.require_approved_plan_for/3` inside `drop_task_to_column/3`
      # can fire the sponsor-bypass rule (ADR 0042 §sponsor-bypass, task
      # 019f6380). See the parallel comment on the `transition_task`
      # handler above for the `nil` current-user-id case.
      case Tasks.drop_task_to_column(task, column, {:user, socket.assigns[:current_user_id]}) do
        {:ok, _updated} ->
          {:noreply,
           socket
           |> put_flash(:info, "Task moved to #{status_label(column_to_status(column))}.")
           |> refresh_board()
           |> reload_selected_task()}

        {:error, :unknown_column} ->
          {:noreply, put_flash(socket, :error, "Unknown column.")}

        {:error, :invalid_drop} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cannot move task from #{status_label(task.status)} to #{status_label(column_to_status(column))}."
           )}

        {:error, :no_approved_plan} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Cannot move task into #{status_label(column_to_status(column))}: no approved plan exists. Create and approve a plan first."
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Move failed: #{inspect(reason)}")}
      end
    end
  end

  # ── Steering input events ──────────────────────────────────────────────

  def handle_event("send_steering_message", %{"steering" => %{"text" => content}}, socket) do
    content = String.trim(content || "")
    attachment_intended? = steering_attachment_intended?(socket)

    cond do
      content == "" and not attachment_intended? ->
        {:noreply,
         put_steering_feedback(socket, :error, "Enter a message or attach a file before sending.")}

      is_nil(socket.assigns.execution_space_id) ->
        {:noreply,
         put_steering_feedback(
           socket,
           :error,
           "This task does not have an execution log yet, so there is nowhere to send steering."
         )}

      true ->
        space_id = socket.assigns.execution_space_id

        participant =
          socket.assigns.execution_participant ||
            resolve_execution_participant(space_id, socket.assigns.current_user_id)

        if participant do
          attrs = steering_message_attrs(space_id, participant.id, content)

          result =
            if attachment_intended? do
              case persist_steering_attachments(socket) do
                {:ok, pending_attachments} ->
                  Chat.post_message_with_attachments(attrs, pending_attachments)

                {:error, :storage_failed} ->
                  {:error, :storage_failed}
              end
            else
              case Chat.post_message(attrs) do
                {:ok, msg} -> {:ok, msg, []}
                error -> error
              end
            end

          case result do
            {:ok, _msg, _attachments} ->
              {:noreply,
               socket
               |> assign(:execution_participant, participant)
               |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
               |> assign(:steering_upload_previews, [])
               |> assign(:steering_attachment_intended, false)
               |> put_steering_feedback(:success, "Steering sent to the execution log.")
               |> push_event("compose_reset", %{})}

            {:ok, _msg} ->
              {:noreply,
               socket
               |> assign(:execution_participant, participant)
               |> assign(:steering_compose_form, to_form(%{"text" => ""}, as: :steering))
               |> assign(:steering_upload_previews, [])
               |> assign(:steering_attachment_intended, false)
               |> put_steering_feedback(:success, "Steering sent to the execution log.")
               |> push_event("compose_reset", %{})}

            {:error, :uploads_in_progress} ->
              {:noreply,
               put_steering_feedback(
                 socket,
                 :error,
                 "Wait for attachments to finish uploading before sending steering."
               )}

            {:error, :storage_failed} ->
              {:noreply,
               socket
               |> assign(:steering_upload_previews, [])
               |> assign(:steering_attachment_intended, false)
               |> put_steering_feedback(
                 :error,
                 "The attachment upload could not be stored in the execution log. Please try again."
               )}

            {:error, _reason} ->
              {:noreply,
               put_steering_feedback(
                 socket,
                 :error,
                 "The steering message was not posted to the execution log. Please try again."
               )}
          end
        else
          {:noreply,
           put_steering_feedback(
             socket,
             :error,
             "Could not join the execution log as the current user. Refresh and try again."
           )}
        end
    end
  end

  def handle_event("steering_changed", %{"steering" => params}, socket) do
    {:noreply,
     socket
     |> assign(:steering_compose_form, to_form(params, as: :steering))
     |> assign(:steering_feedback, nil)}
  end

  def handle_event("cancel_steering_upload", %{"ref" => ref}, socket) do
    socket =
      if Enum.any?(active_steering_upload_entries(socket), &(&1.ref == ref)) do
        cancel_upload(socket, :steering_attachments, ref)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(
       :steering_upload_previews,
       Enum.reject(socket.assigns.steering_upload_previews, fn preview -> preview.ref == ref end)
     )
     |> sync_steering_attachment_intent()
     |> assign(:steering_feedback, nil)}
  end

  # ── Pin-to-Chat toggle (task 019f62a1 stage 4) ─────────────────────────
  #
  # Sponsor-only affordance in the task detail header. The DOM `:if` gate
  # (`sponsor?/2` in the template) already omits the button for non-sponsors,
  # but the server re-checks: LiveView events can be forged via CDP /
  # `liveSocket.push`, and the pin write is the earliest point that a fresh
  # backlog task materialises a `chat_spaces` row (via
  # `ChatPins.pin/3 → ExecutionSpace.find_or_create/1`). A bypass would let
  # any authenticated user pin — and thereby materialise the exec space —
  # for any task they can see. The re-check keeps the sponsor contract
  # honest and logs the attempt for audit.
  def handle_event("toggle_task_chat_pin", _params, socket) do
    task = socket.assigns[:selected_task]
    user_id = socket.assigns[:current_user_id]
    email = socket.assigns[:current_user_email]

    cond do
      is_nil(task) ->
        # No task open — event fired against a stale panel (e.g. a race
        # between close_detail and the toggle click). Silent noop.
        {:noreply, socket}

      is_nil(email) ->
        # Anonymous session or user record was hard-deleted between mount
        # and click. Can't attribute a pin — refuse with a flash.
        {:noreply, put_flash(socket, :error, "You need to be signed in to pin tasks to Chat.")}

      not sponsor?(task, user_id) ->
        Logger.warning(
          "[TasksLive] toggle_task_chat_pin refused for user_id=#{inspect(user_id)} " <>
            "task_id=#{task.id} — non-sponsor bypass attempt (task sponsor_user_id=" <>
            "#{inspect(task.sponsor_user_id)})"
        )

        {:noreply, put_flash(socket, :error, "Only the task sponsor can pin this task.")}

      true ->
        participant = %{kind: "user", id: email}

        if pinned_by_me?(task, user_id, socket.assigns.my_pinned_task_ids) do
          # Optimistic MapSet update happens on the broadcast round-trip;
          # `unpin/3` fires `:task_pin_removed` which our own handle_info
          # clause will drop the id from :my_pinned_task_ids.
          _ = ChatPins.unpin(task.id, participant, email)
          {:noreply, put_flash(socket, :info, "Unpinned from Chat.")}
        else
          case ChatPins.pin(task.id, participant, email) do
            {:ok, _} ->
              {:noreply, put_flash(socket, :info, "Pinned to Chat.")}

            {:error, reason} ->
              Logger.warning(
                "[TasksLive] toggle_task_chat_pin pin/3 failed for task_id=#{task.id} " <>
                  "reason=#{inspect(reason)}"
              )

              {:noreply, put_flash(socket, :error, "Could not pin this task to Chat.")}
          end
        end
    end
  end

  # Upload cancel
  # ── Mention suggestion no-ops (ComposeInput hook fires these; TasksLive has no mention UI) ──

  def handle_event("noop", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("mention_clear", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("mention_query", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_task_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :task_attachments, ref)}
  end

  defp column_to_status("backlog"), do: "backlog"
  defp column_to_status("in_progress"), do: "in_progress"
  defp column_to_status("in_review"), do: "in_review"
  defp column_to_status("deploying"), do: "deploying"
  defp column_to_status("done"), do: "done"
  defp column_to_status(_), do: "unknown"

  # ── PubSub handlers ────────────────────────────────────────────────────

  @impl true
  def handle_info({:task_updated, _task}, socket) do
    {:noreply, socket |> refresh_board() |> reload_selected_task() |> reload_selected_stack()}
  end

  def handle_info({:task_created, _task}, socket) do
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:task_deleted, _task}, socket) do
    {:noreply, refresh_board(socket)}
  end

  # M5b (task 019f6e2c) stage 5: batch soft-delete from
  # `Platform.Meetings.Triage.junk_batch/2`. One refresh drops every
  # listed row in a single kanban reflow — cheaper than N sequential
  # `{:task_deleted, _}` broadcasts at any batch size ≥ 2. The `ids`
  # and `meta` (canvas_id / count / soft_deleted_at) are informational
  # for future consumers (e.g. a toast crediting the rollback), but
  # `refresh_board/1` is a full re-query so we don't need to splice
  # the delta ourselves.
  def handle_info({:tasks_batch_deleted, _ids, _meta}, socket) do
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:epic_created, _epic}, socket) do
    # New epic — refresh the board so the epic dropdown + any epic-scoped
    # filters pick it up immediately.
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:epic_updated, _epic}, socket) do
    # Epic name/description/status may have changed; refresh so the rendered
    # epic chips and the dropdown reflect the new state.
    {:noreply, refresh_board(socket)}
  end

  def handle_info({:plan_updated, _plan}, socket) do
    {:noreply, socket |> refresh_board() |> reload_selected_task() |> reload_selected_stack()}
  end

  # ADR 0042 Decision 4: stack-v2 commencement gate signal. UI reaction
  # (e.g. flashing "ready to run" chips on freshly-unblocked members)
  # is deliberately out of scope for the gate stage — the plan carrier
  # is `{:task_updated, ...}` events as members transition, which we
  # already handle above. This permissive clause exists so the LiveView
  # doesn't crash on the new message shape.
  def handle_info({:stack_gate_opened, _stack_id, _executable_ids}, socket) do
    {:noreply, socket}
  end

  # Stage-5 of task 019e2c25: per-task ReviewRequests broadcasts. Refresh the
  # board (kanban + mobile section list both consume `:review_counts`) and
  # reload the open stack-detail panel so the per-member badge re-evaluates
  # within the 2s contract budget. `reload_selected_task` covers the
  # detail-panel pending-reviews list when a single task is open.
  def handle_info({:review_request_pending, _payload}, socket) do
    {:noreply, socket |> refresh_board() |> reload_selected_task() |> reload_selected_stack()}
  end

  def handle_info({:review_request_resolved, _payload}, socket) do
    {:noreply, socket |> refresh_board() |> reload_selected_task() |> reload_selected_stack()}
  end

  # Pin-to-Chat stage 4 (task 019f62a1): global space-lifecycle broadcasts
  # for task pin add/remove. Only the CURRENT user's pins land in the
  # socket-side MapSet — other users' pins ride the same topic but must
  # not shift this panel's button state. `participant_kind == "user"` also
  # filters out agent pins (agent participants get their pin flow via the
  # stage-3 mention-propagation pass; they don't drive this human panel).
  def handle_info(
        {:task_pin_added,
         %{task_id: task_id, participant_kind: "user", participant_id: participant_id}},
        socket
      ) do
    if participant_id == socket.assigns[:current_user_email] do
      {:noreply,
       assign(socket, :my_pinned_task_ids, MapSet.put(socket.assigns.my_pinned_task_ids, task_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_pin_added, _payload}, socket), do: {:noreply, socket}

  def handle_info(
        {:task_pin_removed,
         %{task_id: task_id, participant_kind: "user", participant_id: participant_id}},
        socket
      ) do
    if participant_id == socket.assigns[:current_user_email] do
      {:noreply,
       assign(
         socket,
         :my_pinned_task_ids,
         MapSet.delete(socket.assigns.my_pinned_task_ids, task_id)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:task_pin_removed, _payload}, socket), do: {:noreply, socket}

  # Execution space PubSub — re-fetch log on any new message
  def handle_info({:new_message, _msg}, socket) do
    case socket.assigns[:execution_space_id] do
      nil ->
        {:noreply, socket}

      space_id ->
        log = ExecutionSpace.list_messages_with_participants(space_id)

        {:noreply,
         socket
         |> assign(:execution_log, log)
         |> assign(:output_canvases, load_output_canvases(space_id))}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # ── Private — Task creation ─────────────────────────────────────────────

  defp do_create_task(params, socket, status) do
    requested_plan? = status == "planning"

    case normalize_task_assignee(params, socket.assigns.default_task_agent_id, requested_plan?) do
      {:error, :no_agent_available} ->
        {:noreply,
         socket
         |> put_flash(:error, "Select an agent before requesting a plan.")}

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
        # Persist attachments
        persist_task_attachments(socket, task)

        Tasks.broadcast_board({:task_created, task})

        flash_message =
          if status == "planning",
            do: "Task created and planning requested.",
            else: "Task created."

        {:noreply,
         socket
         |> assign(:show_task_sheet, false)
         |> put_flash(:info, flash_message)
         |> refresh_board()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:task_form, to_form(changeset, as: "task"))
         |> put_flash(:error, "Could not create task. Check the form for errors.")}

      {:error, reason} ->
        # `TaskAttrs.build_task_attrs/3` can return non-changeset shape
        # errors (invalid phase key, invalid current_phase, etc). The UI
        # doesn't currently expose those inputs, so these are defensive
        # — surface a generic error message rather than crashing the LV.
        {:noreply, put_flash(socket, :error, "Could not create task: #{inspect(reason)}")}
    end
  end

  # `TaskAttrs.build_task_attrs/3` restricts `flat_attrs` to the canonical
  # field list (see `Platform.Federation.TaskAttrs.@canonical_field_keys`).
  # The new-task form also carries `metadata`, `deploy_strategy`, and
  # `dependencies` — UI-only concerns not part of the ADR 0044 canonical
  # shape. Carry them across explicitly so the LV form still lands the
  # full row.
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

  # ── Private — Steering participant helper ──────────────────────────────────

  defp resolve_execution_participant(space_id, user_id)
       when is_binary(space_id) and is_binary(user_id) do
    existing =
      space_id
      |> Chat.list_participants(include_left: true)
      |> Enum.find(fn p -> p.participant_id == user_id end)

    case existing do
      nil ->
        display_name =
          case Accounts.get_user(user_id) do
            %{name: name} when is_binary(name) and name != "" -> name
            %{email: email} when is_binary(email) -> email
            _ -> "User"
          end

        case Chat.add_participant(space_id, %{
               participant_type: "user",
               participant_id: user_id,
               display_name: display_name,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, p} -> p
          {:error, _} -> nil
        end

      %{left_at: nil} = p ->
        p

      p ->
        case Chat.update_participant(p, %{left_at: nil, joined_at: DateTime.utc_now()}) do
          {:ok, rejoined} -> rejoined
          {:error, _} -> p
        end
    end
  end

  defp resolve_execution_participant(_space_id, _user_id), do: nil

  # ── Private — Steering upload helpers ────────────────────────────────────

  defp handle_steering_attachment_progress(:steering_attachments, entry, socket) do
    preview = %{
      ref: entry.ref,
      client_name: entry.client_name,
      client_type: entry.client_type,
      progress: entry.progress
    }

    {:noreply,
     assign(
       socket,
       :steering_upload_previews,
       [preview | Enum.reject(socket.assigns.steering_upload_previews, &(&1.ref == preview.ref))]
     )
     |> assign(:steering_attachment_intended, true)}
  end

  defp has_steering_upload_entries?(socket) do
    active_steering_upload_entries(socket) != [] or socket.assigns.steering_upload_previews != []
  end

  defp steering_attachment_intended?(socket) do
    socket.assigns.steering_attachment_intended or has_steering_upload_entries?(socket)
  end

  defp active_steering_upload_entries(socket) do
    case get_in(socket.assigns, [:uploads, :steering_attachments]) do
      %{entries: entries} when is_list(entries) -> entries
      _ -> []
    end
  end

  defp persist_steering_attachments(socket) do
    case uploaded_entries(socket, :steering_attachments) do
      {[], [_ | _]} ->
        {:error, :uploads_in_progress}

      {[], []} ->
        if steering_attachment_intended?(socket) do
          {:error, :storage_failed}
        else
          {:ok, []}
        end

      _ ->
        results =
          consume_uploaded_entries(socket, :steering_attachments, fn %{path: path}, entry ->
            result =
              case AttachmentStorage.persist_upload(path, entry.client_name, entry.client_type) do
                {:ok, attrs} -> {:ok, attrs}
                {:error, _reason} -> {:error, :storage_failed}
              end

            {:ok, result}
          end)

        {ok_results, error_results} = Enum.split_with(results, &match?({:ok, _}, &1))
        attachments = Enum.map(ok_results, fn {:ok, attrs} -> attrs end)

        if error_results == [] do
          {:ok, attachments}
        else
          AttachmentStorage.delete_many(attachments)
          {:error, :storage_failed}
        end
    end
  end

  defp sync_steering_attachment_intent(socket) do
    assign(socket, :steering_attachment_intended, has_steering_upload_entries?(socket))
  end

  defp steering_message_attrs(space_id, participant_id, content) do
    %{
      space_id: space_id,
      participant_id: participant_id,
      content_type: "text",
      content: content,
      log_only: false,
      metadata: %{
        "kind" => "steering",
        "source" => "tasks_live",
        "delivery" => "engagement"
      }
    }
  end

  defp put_steering_feedback(socket, kind, message) do
    assign(socket, :steering_feedback, %{kind: kind, message: message})
  end

  # ── Private — Execution log helpers ──────────────────────────────────────

  defp load_execution_log(task_id) do
    case ExecutionSpace.find_by_task_id(task_id) do
      %{id: space_id} ->
        {space_id, ExecutionSpace.list_messages_with_participants(space_id)}

      nil ->
        {nil, []}
    end
  end

  defp refresh_execution_log(socket) do
    case socket.assigns[:execution_space_id] do
      nil ->
        socket

      space_id ->
        assign(socket, :execution_log, ExecutionSpace.list_messages_with_participants(space_id))
    end
  end

  defp unsubscribe_execution_space(socket) do
    if space_id = socket.assigns[:execution_space_id] do
      Chat.PubSub.unsubscribe(space_id)
    end
  end

  # ── Private — Kanban helpers ───────────────────────────────────────────

  # Task-only MOBILE bucketing. Iterates @mobile_columns (5 buckets) so
  # the mobile pill nav + section list don't change shape under Stage 2.
  # The corresponding desktop bucketing lives in
  # `Platform.Tasks.list_by_status/1` (Stage 1) and is assigned to
  # `:columns` directly — see `refresh_board/1` and `mount/3`.
  defp group_by_column(tasks) do
    Enum.reduce(@mobile_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@mobile_column_statuses, col_key, [])
      col_tasks = Enum.filter(tasks, &(&1.status in statuses))
      Map.put(acc, col_key, col_tasks)
    end)
  end

  # Bucket %Task{} and %Stack{} into MOBILE kanban columns (5-bucket
  # shape — backlog absorbs planning + blocked + forming). Sorted within
  # each column by `updated_at` descending so stacks interleave with
  # standalone tasks per ADR 0041 acceptance criterion 1.
  #
  # `stack_entries` is the `[{%Stack{}, board_data}, ...]` shape returned
  # by `Stacks.list_stacks_with_members/1`. Only the `%Stack{}` is placed
  # in the column; `board_data` lives in the `:stack_board_data` assign
  # (keyed by stack id) so the template can look it up without changing
  # the entry shape downstream consumers pattern-match on.
  #
  # A task that belongs to a stack (`stack_id != nil`) is suppressed from
  # the flat column list — it renders only under its parent stack card.
  # Stack members on mobile use the same pattern.
  #
  # Discriminate-by-`__struct__`: a column entry is either `%Task{}` or
  # `%Stack{}`. The template pattern-matches `case item.__struct__`.
  defp group_board_items(tasks, stack_entries) do
    standalone_tasks = Enum.filter(tasks, &is_nil(&1.stack_id))

    Enum.reduce(@mobile_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@mobile_column_statuses, col_key, [])
      col_tasks = Enum.filter(standalone_tasks, &(&1.status in statuses))

      col_stacks =
        stack_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1.status in statuses))

      merged =
        (col_tasks ++ col_stacks)
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      Map.put(acc, col_key, merged)
    end)
  end

  # Bucket %Stack{} entries into DESKTOP kanban columns (7-bucket shape,
  # string-keyed for template parity with `@kanban_columns`). Returns a
  # map of "<col_key>" => [%Stack{}, ...]. Tasks for the desktop board
  # come from `Platform.Tasks.list_by_status/1` (assigned to `:columns`,
  # atom-keyed); stacks live in this separate map so the template can
  # merge them column-by-column without re-bucketing tasks too. The
  # template sorts the merged list by `updated_at` desc inline.
  defp group_desktop_stacks(stack_entries) do
    Enum.reduce(@kanban_columns, %{}, fn {col_key, _label}, acc ->
      statuses = Map.get(@desktop_column_statuses, col_key, [])

      col_stacks =
        stack_entries
        |> Enum.map(&elem(&1, 0))
        |> Enum.filter(&(&1.status in statuses))

      Map.put(acc, col_key, col_stacks)
    end)
  end

  # Split `[{stack, board_data}, ...]` into `{%{stack_id => board_data},
  # [stack, ...]}`. The board-data map is what the template consults for
  # member_count / dep_edge_count / ready_count / members per card.
  defp split_stack_entries(stack_entries) when is_list(stack_entries) do
    Enum.reduce(stack_entries, {%{}, []}, fn {%Stack{} = stack, board_data},
                                             {data_acc, stacks_acc} ->
      {Map.put(data_acc, stack.id, board_data), [stack | stacks_acc]}
    end)
    |> then(fn {data_acc, stacks_acc} -> {data_acc, Enum.reverse(stacks_acc)} end)
  end

  defp refresh_board(socket) do
    opts =
      []
      |> then(fn o ->
        case socket.assigns.selected_project_id do
          nil -> o
          id -> Keyword.put(o, :project_id, id)
        end
      end)
      |> then(fn o ->
        case socket.assigns.selected_epic_id do
          nil -> o
          id -> Keyword.put(o, :epic_id, id)
        end
      end)
      |> then(fn o ->
        # Stage-2 of task 019f3f22 (ADR-0042 sponsor visibility): thread
        # the active sponsor filter through the query pipeline so both
        # the desktop kanban (`list_by_status/1`) and mobile section list
        # (`list_all_tasks/1`) narrow to `sponsor_user_id == current_user_id`
        # when the "Sponsored by me" toggle is active. `nil` (i.e. no
        # `:sponsor_user_id` opt) is the unfiltered passthrough that
        # matches every prior refresh_board call site.
        case sponsor_filter_user_id(socket) do
          nil -> o
          id -> Keyword.put(o, :sponsor_user_id, id)
        end
      end)

    tasks = Tasks.list_all_tasks(opts)

    stack_filters =
      case socket.assigns.selected_project_id do
        nil -> %{}
        id -> %{project_id: id}
      end

    # Stage 3 of task 019f487e (ADR-0042 Decision 8 stack-level sponsor):
    # thread the same active sponsor filter through the stacks query so
    # the client-state v3 "Sponsored by me" pill filters BOTH surfaces
    # (tasks + stacks) with one toggle. `Stacks.list_stacks_with_members/1`
    # was taught the `:sponsor_user_id` key in stage 1; the guard mirrors
    # the task-side merge above — `nil` is the unfiltered passthrough,
    # matching every prior refresh_board call site.
    stack_filters =
      stack_filters
      |> then(fn f ->
        case sponsor_filter_user_id(socket) do
          nil -> f
          id -> Map.put(f, :sponsor_user_id, id)
        end
      end)

    stack_entries = Stacks.list_stacks_with_members(stack_filters)
    {stack_board_data, stacks} = split_stack_entries(stack_entries)

    socket
    |> assign(:all_tasks, tasks)
    |> assign(:stacks, stacks)
    |> assign(:stack_board_data, stack_board_data)
    |> assign(:columns, Tasks.list_by_status(opts))
    |> assign(:desktop_stacks_by_column, group_desktop_stacks(stack_entries))
    |> assign(:board_items, group_board_items(tasks, stack_entries))
    # Per ADR 0041 acceptance criterion 3, any list refetch collapses
    # ephemeral expansion. `refresh_board/1` is the common funnel for
    # project / epic / filter changes AND every PubSub board event, so
    # resetting here covers all the reset triggers in one place.
    |> assign(:expanded_stacks, MapSet.new())
    |> assign(:pending_plan_count, count_pending_plans(tasks))
    |> assign(:review_counts, pending_review_counts(tasks))
    # Recompute the scope-rail counts whenever the board refreshes so the
    # rail badges stay in sync with project/epic filter changes and PubSub
    # board events. Cheap (single COUNT(*) today; will be one indexed
    # GROUP BY org_id once MT/RBAC lands).
    |> assign(:scope_counts, Tasks.count_by_scope())
    |> assign(:scope_counts_db, Tasks.count_by_scope())
    |> assign(:visible_task_count, length(tasks))
    |> sync_review_request_subscriptions(tasks)
    # An active search must survive PubSub-driven refreshes — the assigns
    # above are the unfiltered sources; re-narrow the derived shapes.
    |> maybe_reapply_search()
  end

  # ── Board search (re-skin Phase 2 stage 2, task 019f51ca) ─────────────
  #
  # Search narrows the three derived board shapes (`:columns`,
  # `:desktop_stacks_by_column`, `:board_items`) in-memory from the
  # unfiltered sources that every mount/refresh already assigns
  # (`:all_tasks`, `:stacks`, `:stack_board_data`). No DB round-trip per
  # keystroke; clearing the query rebuilds the unfiltered shapes from the
  # same sources. Pill/column counts read from the derived shapes, so
  # they recompute automatically while a search is active, and since
  # Marlowe's 2026-07-12 ruling the scope-rail badges and header total
  # narrow with the query too (restored from :scope_counts_db on clear).

  defp close_create_menus(socket) do
    socket
    |> assign(:create_menu_open, false)
    |> assign(:fab_menu_open, false)
  end

  defp normalize_search(nil), do: ""
  defp normalize_search(q) when is_binary(q), do: q |> String.trim() |> String.downcase()

  defp search_active?(query), do: normalize_search(query) != ""

  # No-op passthrough when there is no active query, so the DB-computed
  # shapes from `refresh_board/1` stay authoritative in the common case.
  defp maybe_reapply_search(socket) do
    if search_active?(socket.assigns[:task_search_query]) do
      rebuild_board_shapes(socket)
    else
      socket
    end
  end

  defp rebuild_board_shapes(socket) do
    q = normalize_search(socket.assigns.task_search_query)
    agent_names = socket.assigns.agent_names

    tasks =
      case q do
        "" -> socket.assigns.all_tasks
        _ -> Enum.filter(socket.assigns.all_tasks, &task_matches_search?(&1, q, agent_names))
      end

    stack_entries =
      socket.assigns.stacks
      |> Enum.filter(&stack_matches_search?(&1, q))
      |> Enum.map(&{&1, Map.get(socket.assigns.stack_board_data, &1.id, %{})})

    # Marlowe 2026-07-12 ("narrow everything"): while a query is active every
    # on-screen count — columns, scope-rail chips, header total — describes
    # the filtered board. Chips mirror Tasks.count_by_scope/0's current stub
    # semantics (everything under :fabrikam); when that becomes a real per-org
    # GROUP BY this branch needs the matching in-memory group-by over `tasks`.
    scope_counts =
      if q == "" do
        socket.assigns.scope_counts_db
      else
        socket.assigns.scope_counts_db
        |> Map.new(fn {key, _} -> {key, 0} end)
        |> Map.put(:fabrikam, length(tasks))
      end

    socket
    |> assign(:columns, bucket_tasks_by_desktop_column(tasks))
    |> assign(:desktop_stacks_by_column, group_desktop_stacks(stack_entries))
    |> assign(:board_items, group_board_items(tasks, stack_entries))
    |> assign(:scope_counts, scope_counts)
    |> assign(:visible_task_count, length(tasks))
  end

  # A task matches when the (downcased) query is a substring of its id,
  # title, sponsor display name, assignee/agent display name, or epic
  # name. Sponsor/epic come from the preloads both board queries carry;
  # the guards below also tolerate `Ecto.Association.NotLoaded`.
  defp task_matches_search?(%Task{} = task, q, agent_names) do
    [
      task.id,
      task.title,
      sponsor_search_name(task),
      assignee_name(task, agent_names),
      epic_search_name(task)
    ]
    |> Enum.any?(fn value ->
      is_binary(value) and String.contains?(String.downcase(value), q)
    end)
  end

  defp sponsor_search_name(%Task{sponsor: %{name: name, email: email}}), do: name || email
  defp sponsor_search_name(_task), do: nil

  defp epic_search_name(%Task{epic: %Epic{name: name}}), do: name
  defp epic_search_name(_task), do: nil

  defp stack_matches_search?(_stack, ""), do: true

  defp stack_matches_search?(%Stack{} = stack, q) do
    [stack.id, stack.name]
    |> Enum.any?(fn value ->
      is_binary(value) and String.contains?(String.downcase(value), q)
    end)
  end

  # In-memory equivalent of `Platform.Tasks.list_by_status/1`'s bucket
  # shape (atom keys, `updated_at` desc within each bucket) so a filtered
  # `:columns` map is indistinguishable downstream. `@desktop_column_statuses`
  # already encodes the same routing (forming→planning, cancelled→done,
  # stack_pending excluded).
  defp bucket_tasks_by_desktop_column(tasks) do
    Map.new(@desktop_column_statuses, fn {col_key, statuses} ->
      bucket =
        tasks
        |> Enum.filter(&(&1.status in statuses))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      {String.to_existing_atom(col_key), bucket}
    end)
  end

  # Stage-5 of task 019e2c25: keep our review_requests:<task_id> subscription
  # set in sync with the visible board. Subscribes to any task we are not yet
  # following and unsubscribes from tasks that have left the board (filter
  # change, deletion, project switch). No-op on disconnected socket — the
  # mount-time guard already skipped the initial subscribe in that case.
  defp sync_review_request_subscriptions(socket, tasks) do
    if connected?(socket) do
      current = socket.assigns[:review_request_subscriptions] || MapSet.new()
      desired = MapSet.new(tasks, & &1.id)

      Enum.each(MapSet.difference(desired, current), &ReviewRequests.subscribe_for_task/1)
      Enum.each(MapSet.difference(current, desired), &ReviewRequests.unsubscribe_for_task/1)

      assign(socket, :review_request_subscriptions, desired)
    else
      socket
    end
  end

  defp reload_selected_task(socket) do
    if task = socket.assigns[:selected_task] do
      updated = Tasks.get_task_detail(task.id)
      pending_reviews = if updated, do: ReviewRequests.list_pending_for_task(updated.id), else: []

      superseded_reviews =
        if updated, do: ReviewRequests.list_superseded_for_task(updated.id), else: []

      review_canvases = load_review_canvases(pending_reviews)
      review_output_ids = review_canvas_ids(pending_reviews)
      output_canvases = load_output_canvases(socket.assigns[:execution_space_id])
      attached_skills = if updated, do: Skills.resolve_skills(updated.id), else: []

      active_review_canvas =
        case socket.assigns[:active_review_canvas] do
          %Canvas{id: id} ->
            Enum.find(output_canvases, &(&1.id == id)) || Map.get(review_canvases, id)

          _ ->
            nil
        end

      socket
      |> assign_selected_task(updated)
      |> assign(:pending_reviews, pending_reviews)
      |> assign(:superseded_reviews, superseded_reviews)
      |> assign(:review_canvases, review_canvases)
      |> assign(:review_output_ids, review_output_ids)
      |> assign(:output_canvases, output_canvases)
      |> assign(:active_review_canvas, active_review_canvas)
      |> assign(:attached_skills, attached_skills)
      |> refresh_execution_log()
    else
      socket
      |> assign(:pending_reviews, [])
      |> assign(:superseded_reviews, [])
      |> assign(:review_canvases, %{})
      |> assign(:review_output_ids, MapSet.new())
      |> assign(:output_canvases, [])
      |> assign(:active_review_canvas, nil)
      |> assign(:attached_skills, [])
    end
  end

  defp load_review_canvases(pending_reviews) do
    pending_reviews
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.map(& &1.canvas_id)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Enum.reduce(%{}, fn canvas_id, acc ->
      case Chat.get_canvas(canvas_id) do
        %Canvas{} = canvas -> Map.put(acc, canvas_id, canvas)
        _ -> acc
      end
    end)
  end

  defp review_canvas_ids(pending_reviews) do
    pending_reviews
    |> Enum.flat_map(&(&1.items || []))
    |> Enum.map(& &1.canvas_id)
    |> Enum.filter(&is_binary/1)
    |> MapSet.new()
  end

  defp load_output_canvases(nil), do: []
  defp load_output_canvases(space_id), do: Chat.list_canvases(space_id)

  defp find_canvas_for_display(socket, canvas_id) do
    Enum.find(socket.assigns[:output_canvases] || [], &(&1.id == canvas_id)) ||
      Map.get(socket.assigns[:review_canvases] || %{}, canvas_id)
  end

  defp count_pending_plans(tasks) do
    Enum.count(tasks, fn task ->
      Enum.any?(task.plans || [], &(&1.status == "pending_review"))
    end)
  end

  defp pending_review_counts(tasks) do
    task_ids = Enum.map(tasks, & &1.id)

    if task_ids == [] do
      %{}
    else
      ReviewRequest
      |> where([rr], rr.task_id in ^task_ids and rr.status == "pending")
      |> group_by([rr], rr.task_id)
      |> select([rr], {rr.task_id, count(rr.id)})
      |> Repo.all()
      |> Map.new()
    end
  end

  # ── View helpers ───────────────────────────────────────────────────────

  # Pulls the first changeset error message for the given field if any —
  # the inline-edit handlers only ever write one field at a time, so this
  # is enough to surface a meaningful flash without dragging in the full
  # `traverse_errors` machinery.
  defp changeset_error(%Ecto.Changeset{errors: errors}, field) do
    field_atom =
      if is_atom(field) do
        field
      else
        try do
          String.to_existing_atom(field)
        rescue
          ArgumentError -> nil
        end
      end

    case Keyword.get(errors, field_atom) do
      {msg, opts} ->
        Enum.reduce(opts, msg, fn {k, v}, acc ->
          String.replace(acc, "%{#{k}}", to_string(v))
        end)

      _ ->
        "invalid value"
    end
  end

  # Deploy targets configured on a project (`project.deploy_config["deploy_targets"]`).
  # Always returns a list of target-name strings; falls back to `[]` when
  # unconfigured so the dropdown gracefully empties out instead of crashing.
  #
  # `deploy_targets` in the DB is a list of MAPS shaped like
  # `%{"name" => "production", "type" => "docker_compose", "config" => %{...}}`
  # (see Project.deploy_config validation + DeployResolver.get_targets/1).
  # Extract the "name" field for the UI dropdown; also accept bare strings for
  # forward-compat with any future shape change.
  defp project_deploy_targets(%{deploy_config: %{"deploy_targets" => targets}})
       when is_list(targets) do
    targets
    |> Enum.map(fn
      %{"name" => n} when is_binary(n) -> n
      n when is_binary(n) -> n
      _ -> nil
    end)
    |> Enum.filter(& &1)
  end

  defp project_deploy_targets(_), do: []

  # Deploy targets for the New-Task bottom sheet's deploy_target dropdown.
  # Reads the selected project id off the task form (nil when no project
  # picked yet), finds the matching project in the pre-grouped
  # `projects_by_org` structure, and delegates to `project_deploy_targets/1`
  # for the same map/string extraction the detail pane uses. Returns `[]`
  # when nothing is selectable — the caller uses that to disable the
  # <select> and swap the placeholder label to "(no targets configured)".
  # ADR 0044 stage 4 — parity with MCP `task_create`'s `deploy_target` field.
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

  defp deploy_target_label("hive_production"), do: "Hive Production"
  defp deploy_target_label("github_pr"), do: "GitHub PR"
  defp deploy_target_label("google_drive"), do: "Google Drive"
  defp deploy_target_label(other), do: other

  # Function component: renders the readonly Deploy target value block.
  #
  # Two rendering paths cohabit here during the deploy_target →
  # deploy_target_config migration (task 019f5e66):
  #
  #   1. `deploy_target_config` is set — render a strategy-aware label
  #      (`data-state="strategy"`, `data-strategy="<name>"`) built from
  #      `deploy_target_config_label/1`. Preferred / new path.
  #   2. `deploy_target_config` is nil — fall back to the legacy
  #      `Platform.Tasks.resolve_deploy_target/1` flow with its three
  #      states (`explicit | inherited | none`). Keeps existing tests and
  #      the "configure a deploy target" affordance intact until every
  #      writer migrates to the config map.
  #
  # `data-state` on the value block is stable — tests and e2e scripts
  # should pin to that, not the string in the badge.
  attr(:task, :any, required: true)

  defp deploy_target_display(assigns) do
    {config_label, strategy_name} =
      case assigns.task.deploy_target_config do
        %{"strategy" => strat} = cfg -> {deploy_target_config_label(cfg), strat}
        _ -> {nil, nil}
      end

    assigns =
      assigns
      |> assign(:config_label, config_label)
      |> assign(:strategy_name, strategy_name)
      |> assign(:resolution, Platform.Tasks.resolve_deploy_target(assigns.task))

    ~H"""
    <%= if @config_label do %>
      <div
        data-role="deploy-target-value"
        data-state="strategy"
        data-strategy={@strategy_name}
        class="flex items-center gap-2 flex-wrap"
      >
        <span class="inline-flex items-center gap-1 rounded-full border border-base-content/20 bg-base-100 px-2 py-0.5 text-xs">
          {@config_label}
        </span>
      </div>
    <% else %>
      <div
        data-role="deploy-target-value"
        data-state={deploy_target_state_name(@resolution)}
        class="flex items-center gap-2 flex-wrap"
      >
        <%= case @resolution do %>
          <% {:explicit, value} -> %>
            <span class="badge badge-sm badge-outline">{deploy_target_label(value)}</span>
          <% {:inherited, value} -> %>
            <span class="badge badge-sm badge-outline">{deploy_target_label(value)}</span>
            <span class="text-xs text-base-content/50">Inherited from project</span>
          <% :none -> %>
            <span class="badge badge-sm badge-warning gap-1">
              <span class="hero-exclamation-triangle size-3"></span> No target set
            </span>
            <button
              type="button"
              phx-click="open_deploy_target_config"
              data-role="configure-deploy-target-button"
              class="btn btn-xs btn-ghost text-warning"
            >
              Configure a deploy target
            </button>
        <% end %>
      </div>
    <% end %>
    """
  end

  defp deploy_target_state_name({:explicit, _}), do: "explicit"
  defp deploy_target_state_name({:inherited, _}), do: "inherited"
  defp deploy_target_state_name(:none), do: "none"

  # Strategy-aware label for `deploy_target_config` (task 019f5e66 stage 6).
  #
  # Each registered strategy renders as a self-describing string suitable for
  # the readonly detail row — no more raw JSON blobs leaking through. Unknown
  # or malformed configs return `nil` so the caller falls back to the legacy
  # `deploy_target` string rendering.
  #
  # `project_files` performs one lookup for the target project's name so the
  # label can render `"Project Files: <project>/<folder>"` instead of a bare
  # UUID. The lookup is best-effort — if the target project is missing (soft-
  # deleted, cross-tenant, etc.) the label degrades to just the folder.
  defp deploy_target_config_label(%{"strategy" => "project_files"} = cfg) do
    folder = string_or_nil(Map.get(cfg, "folder"))
    project_name = lookup_project_name(Map.get(cfg, "project_id"))

    case {project_name, folder} do
      {nil, nil} -> "Project Files"
      {nil, folder} -> "Project Files: #{folder}"
      {name, nil} -> "Project Files: #{name}"
      {name, folder} -> "Project Files: #{name}/#{folder}"
    end
  end

  defp deploy_target_config_label(%{"strategy" => "docker_deploy"} = cfg) do
    case string_or_nil(Map.get(cfg, "target")) do
      nil -> "Docker"
      target -> "Docker: #{target}"
    end
  end

  defp deploy_target_config_label(%{"strategy" => "pr_merge"}), do: "PR merge"

  defp deploy_target_config_label(%{"strategy" => "skill_driven"} = cfg) do
    slug = string_or_nil(Map.get(cfg, "skill_slug")) || string_or_nil(Map.get(cfg, "skill_id"))

    case slug do
      nil -> "Skill"
      s -> "Skill: #{s}"
    end
  end

  defp deploy_target_config_label(%{"strategy" => "manual"}), do: "Manual"
  defp deploy_target_config_label(_), do: nil

  defp string_or_nil(v) when is_binary(v) and v != "", do: v
  defp string_or_nil(_), do: nil

  defp lookup_project_name(id) when is_binary(id) and id != "" do
    case Platform.Tasks.get_project(id) do
      %Platform.Tasks.Project{name: name} -> name
      _ -> nil
    end
  end

  defp lookup_project_name(_), do: nil

  # Edit-mode dropdown pre-selection value (ADR 0044 v3 stage 2).
  #
  # The edit-mode <select> must reflect the SAME resolved value the readonly
  # view shows — otherwise the user sees "production · Inherited from project"
  # in read mode, clicks edit, and finds "(inherit from project)" pre-selected.
  # That mismatch was the v1 bug: users had to re-pick the value they were
  # already implicitly inheriting.
  #
  # Precedence mirrors `Platform.Tasks.resolve_deploy_target/1`:
  #   * explicit task.deploy_target wins
  #   * inherited value (project default / sole-entry list) is pre-selected
  #   * `:none` falls through to the empty-string placeholder
  #
  # Returns the string that should match the <option value=...> attribute; the
  # empty-string placeholder round-trips to nil via the existing coercion in
  # `update_task_field` handler.
  defp deploy_target_dropdown_value(task) do
    case Platform.Tasks.resolve_deploy_target(task) do
      {:explicit, value} -> value
      {:inherited, value} -> value
      :none -> ""
    end
  end

  # Label for the empty-value option in the edit-mode dropdown.
  # When the project has NO deploy targets configured, the placeholder can't
  # promise inheritance — it explicitly names the empty state so the user
  # knows why the dropdown is disabled.
  defp edit_mode_inherit_option_label(_task, project_targets) do
    if Enum.any?(project_targets),
      do: "(inherit from project)",
      else: "(none — no targets configured)"
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

  defp priority_badge_class("critical"), do: "badge badge-error badge-sm"
  defp priority_badge_class("high"), do: "badge badge-error badge-outline badge-sm"
  defp priority_badge_class("medium"), do: "badge badge-warning badge-outline badge-sm"
  defp priority_badge_class("low"), do: "badge badge-success badge-outline badge-sm"
  defp priority_badge_class(_), do: "badge badge-ghost badge-sm"

  # ── Dependency helpers ─────────────────────────────────────────────────

  # Cheap, per-card. Reads `metadata["unmet_dependencies"]` set by
  # `Tasks.create_task/_/transition_*` whenever a task is parked or
  # partially unblocked. No DB hit.
  defp unmet_dependency_count(%Task{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("unmet_dependencies", [])
    |> length()
  end

  defp unmet_dependency_count(_), do: 0

  # Resolves a task's declared dependency ids into `[%{id, title, status}]`
  # rows in the order the user authored them. Issues a single `Repo.all`,
  # so it's safe to call in the detail panel (one task per render) but NOT
  # per-card on the kanban. Missing/deleted ids come back as
  # `%{id: id, title: nil, status: nil}` so the template can render a
  # placeholder + gray ✗ icon.
  defp dependency_summary(%Task{} = task) do
    ids = Tasks.dependency_task_ids(task)

    case ids do
      [] ->
        []

      ids ->
        rows =
          Repo.all(
            from(t in Task,
              where: t.id in ^ids,
              select: %{id: t.id, title: t.title, status: t.status}
            )
          )

        by_id = Map.new(rows, &{&1.id, &1})
        Enum.map(ids, &Map.get(by_id, &1, %{id: &1, title: nil, status: nil}))
    end
  end

  defp dependency_summary(_), do: []

  # Heroicon class + colour for a dependency's status icon.
  defp dependency_status_icon("done"), do: "hero-check-circle-solid text-success"
  defp dependency_status_icon("in_progress"), do: "hero-play-circle-solid text-info"

  defp dependency_status_icon(status)
       when status in ~w(blocked planning backlog in_review deploying),
       do: "hero-pause-circle-solid text-warning"

  defp dependency_status_icon(_), do: "hero-x-circle-solid text-base-content/40"

  # ── Per-phase assignee helpers (used by the assignee modal templates) ───

  defp phase_label("planning"), do: "Planning"
  defp phase_label("execution"), do: "Implementation"
  defp phase_label("review"), do: "Validation"
  defp phase_label(other), do: String.capitalize(other)

  defp current_phase_label(%{} = task), do: Tasks.current_phase(task)

  defp phase_assignee_id(%{phase_assignees: pa}, phase) when is_map(pa) do
    case Map.get(pa, phase) do
      %{"assignee_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp phase_assignee_id(_, _), do: nil

  # Stack-level analogue of `phase_assignee_id/2` — reads the stack's
  # `metadata["phase_assignees"]` default for the stack assignee modal.
  defp stack_phase_assignee_id(%Stack{} = stack, phase) do
    case Stacks.stack_phase_assignees(stack) |> Map.get(phase) do
      %{"assignee_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp stack_phase_assignee_id(_, _), do: nil

  # Whether a stack member is following the stack-level default
  # (`"inherited"`) or carries an individual assignee override
  # (`"override"`). Drives the per-member badge in the stack detail panel.
  defp member_assignment_badge(member),
    do: (Stacks.member_overridden?(member) && "override") || "inherited"

  defp agent_name_for(_agents_by_id, nil), do: nil

  defp agent_name_for(agents_by_id, agent_id) when is_map(agents_by_id) do
    case Map.get(agents_by_id, agent_id) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp status_label("backlog"), do: "Backlog"
  defp status_label("planning"), do: "Planning"
  defp status_label("in_progress"), do: "In Progress"
  defp status_label("in_review"), do: "In Review"
  defp status_label("deploying"), do: "Deploying"
  defp status_label("done"), do: "Done"
  defp status_label("blocked"), do: "Blocked"
  defp status_label(other), do: other

  # Task-aware status badge: when a task is in `planning` AND has a plan
  # waiting on human review, surface "Plan Ready" with a warning badge to
  # signal action-needed. All other cases fall through to `status_label/1`
  # with the neutral outline badge. Requires `:plans` preloaded — both
  # `Tasks.list_all_tasks/1` and `Tasks.get_task_detail/1` do this.
  defp task_display_status(%Task{status: "planning", plans: plans} = _task)
       when is_list(plans) do
    if Enum.any?(plans, &(&1.status == "pending_review")) do
      {"Plan Ready", "badge badge-warning"}
    else
      {status_label("planning"), "badge badge-outline"}
    end
  end

  defp task_display_status(%Task{status: status} = _task) do
    {status_label(status), "badge badge-outline"}
  end

  # ── Stack detail meta-grid helpers (T8 stage 2) ─────────────────────────
  #
  # Pure helpers that compute the four meta-grid cell values from a
  # `%Stack{}` and its preloaded member list. Returned shape:
  #
  #     %{
  #       status:     %{label: "In Review",  class: "text-warning"},
  #       members:    %{count: 4, ready_count: 3, text: "4 · 3 ready"},
  #       dep_edges:  %{count: 3, valid?: true,  text: "3 · valid DAG"},
  #       branch:     "stack/user-keyed-saves"
  #     }
  #
  # Kept private to TasksLive (UI-only); the upstream `Stacks` context
  # already exposes member_count/dep_edge_count/ready_count via
  # `build_board_data/1` for the T7 board card, but stage 2's "ready"
  # rule is broader (counts merged_into_rollup_at members too) and the
  # color/label mapping is UI concern, so we compute fresh here rather
  # than reuse the board-data map.
  @spec stack_meta(Stack.t(), [Task.t()]) :: map()
  defp stack_meta(%Stack{} = stack, members) when is_list(members) do
    %{
      status: stack_meta_status(stack),
      members: stack_meta_members(members),
      dep_edges: stack_meta_dep_edges(members),
      branch: stack.rollup_branch || ""
    }
  end

  defp stack_meta_status(%Stack{status: status}) do
    %{label: status_label(status), class: stack_status_text_class(status)}
  end

  # Color tone for the status cell value text. Mirrors the badge
  # palette used elsewhere (in_review→warning, in_progress→info,
  # done→success, deploying→secondary). `forming` and `abandoned`
  # are dimmed since they're transient/terminal-without-ship states.
  defp stack_status_text_class("in_review"), do: "text-warning"
  defp stack_status_text_class("in_progress"), do: "text-info"
  defp stack_status_text_class("done"), do: "text-success"
  defp stack_status_text_class("deploying"), do: "text-secondary"
  defp stack_status_text_class("blocked"), do: "text-error"
  defp stack_status_text_class(_), do: "text-base-content/50"

  defp stack_meta_members(members) when is_list(members) do
    count = length(members)
    ready_count = Enum.count(members, &member_ready?/1)
    %{count: count, ready_count: ready_count, text: "#{count} · #{ready_count} ready"}
  end

  # A member is "ready" (in the meta-grid sense) when its branch has
  # been merged into the rollup OR its status has crossed the unblock
  # threshold (in_review/deploying/done). Stamping happens after a
  # merge succeeds, so the OR catches members that are status-ready
  # but not yet merged AND members that are merged-but-back-pending.
  defp member_ready?(%Task{status: status, metadata: metadata}) do
    status in ["in_review", "deploying", "done"] or
      (is_map(metadata) and not is_nil(Map.get(metadata, "merged_into_rollup_at")))
  end

  defp stack_meta_dep_edges(members) when is_list(members) do
    member_ids_set = MapSet.new(members, & &1.id)

    # Build [{from_id, to_id}, ...] of in-stack edges. Mirrors
    # `Stacks.build_board_data/1`'s edge-count logic but also keeps
    # the full edge list so we can run a Kahn check for cycles.
    edges =
      Enum.flat_map(members, fn %Task{id: from_id} = m ->
        m
        |> Tasks.dependency_task_ids()
        |> Enum.reject(&(&1 == from_id))
        |> Enum.filter(&MapSet.member?(member_ids_set, &1))
        |> Enum.uniq()
        |> Enum.map(&{from_id, &1})
      end)

    valid? = acyclic?(member_ids_set, edges)

    text =
      if valid? do
        "#{length(edges)} · valid DAG"
      else
        "#{length(edges)} · cycle detected"
      end

    %{count: length(edges), valid?: valid?, text: text}
  end

  # Tone class for the dep-edges cell value: success-tinted when the
  # subgraph is acyclic, error-tinted when a cycle is detected.
  defp dep_edges_class(%{valid?: true}), do: "text-base-content"
  defp dep_edges_class(%{valid?: false}), do: "text-error"

  # Lightweight Kahn-style topological check. Returns true iff every
  # node can be peeled away in some order — i.e. the graph is acyclic.
  # Edges are `{from, to}` where `from` depends on `to`. Treating `from`
  # as the dependent, `from` has an incoming "dependency" edge from
  # `to`, so we count `from` occurrences as in-degree (= number of
  # un-peeled deps remaining). Roots (members with no in-stack deps)
  # start at in-degree 0 and peel first; removing them decrements the
  # in-degree of any member that had THEM as a dep.
  defp acyclic?(node_ids_set, edges) do
    in_degree =
      Enum.reduce(edges, Map.new(node_ids_set, &{&1, 0}), fn {from, _to}, acc ->
        Map.update(acc, from, 1, &(&1 + 1))
      end)

    do_acyclic(in_degree, edges)
  end

  defp do_acyclic(in_degree, _edges) when map_size(in_degree) == 0, do: true

  defp do_acyclic(in_degree, edges) do
    case Enum.find(in_degree, fn {_id, deg} -> deg == 0 end) do
      nil ->
        false

      {id, _} ->
        in_degree = Map.delete(in_degree, id)

        # Removing `id` (a peeled root) frees any member whose dep set
        # included `id` — those are edges `{dependent, id}`; decrement
        # in_degree of `dependent`.
        in_degree =
          Enum.reduce(edges, in_degree, fn
            {dependent, ^id}, acc -> Map.update(acc, dependent, 0, &max(&1 - 1, 0))
            _, acc -> acc
          end)

        do_acyclic(in_degree, edges)
    end
  end

  # ── Stack DAG layout (T8 stage 3) ───────────────────────────────────────
  #
  # `stack_dag_layout/1` is a UI-only positioning helper that turns a list
  # of stack member tasks into a render-ready bag of nodes + edges + a
  # viewBox tuple. The dep DAG SVG in the stack detail panel renders
  # straight off this struct.
  #
  # Algorithm:
  #
  #   1. Build the in-stack edge list `{from_id, to_id}` where `from`
  #      depends on `to`. Edges leaving the stack are dropped — only
  #      sibling-to-sibling deps land on the canvas.
  #   2. Assign each node a topological **level** (row index) equal to the
  #      longest path from a root (in-degree 0) to that node. This means
  #      siblings runnable in parallel land on the same row even if one
  #      has a transitive ancestor that the other lacks. Nodes with cyclic
  #      deps fall back to level 0 so the layout never crashes; the meta-
  #      grid surfaces "cycle detected" separately.
  #   3. Within each level, sort by `stack_position` (stable, deterministic)
  #      and distribute columns left-to-right starting from 0.
  #   4. Translate (level, col) → pixel (x, y) via `@dag_*` constants.
  #      Edge endpoints anchor to bottom-center of source, top-center of
  #      target so arrows visibly flow downward (matches mock).
  #
  # The output map is the same shape used by the template, so the heex
  # can iterate `nodes` and `edges` without further computation.
  #
  # Pixel constants (mock canvas 019e1a16 rev 2 dimensions):
  #   row_height = 76    (vertical stride between rows)
  #   col_width  = 160   (horizontal stride between columns)
  #   node_w     = 140   (rect width)
  #   node_h     = 44    (rect height)
  #   pad        = 8     (left/top padding inside the viewBox)
  @dag_row_height 76
  @dag_col_width 160
  @dag_node_w 140
  @dag_node_h 44
  @dag_pad 8

  @spec stack_dag_layout([Task.t()]) :: %{
          nodes: [map()],
          edges: [map()],
          viewbox: {non_neg_integer(), non_neg_integer()}
        }
  defp stack_dag_layout([]) do
    %{nodes: [], edges: [], viewbox: {0, 0}}
  end

  defp stack_dag_layout(members) when is_list(members) do
    member_by_id = Map.new(members, &{&1.id, &1})
    member_id_set = MapSet.new(members, & &1.id)

    # Edge list: `{from, to}` where `from` depends on `to` (so `to` is
    # the predecessor / parent in the DAG). Only in-stack deps survive.
    edges =
      Enum.flat_map(members, fn %Task{id: from_id} = m ->
        m
        |> Tasks.dependency_task_ids()
        |> Enum.reject(&(&1 == from_id))
        |> Enum.filter(&MapSet.member?(member_id_set, &1))
        |> Enum.uniq()
        |> Enum.map(&{from_id, &1})
      end)

    levels = dag_levels(members, edges)

    # Group node ids by level; within a level, sort by stack_position so
    # the layout is deterministic and matches "dispatch order" left-to-
    # right within each row.
    by_level =
      members
      |> Enum.group_by(fn %Task{id: id} -> Map.get(levels, id, 0) end)
      |> Map.new(fn {lvl, ms} ->
        sorted = Enum.sort_by(ms, & &1.stack_position)
        {lvl, sorted}
      end)

    max_cols =
      by_level
      |> Map.values()
      |> Enum.map(&length/1)
      |> Enum.max(fn -> 1 end)

    num_levels = (by_level |> Map.keys() |> Enum.max(fn -> 0 end)) + 1

    nodes =
      by_level
      |> Enum.flat_map(fn {level, ms} ->
        ms
        |> Enum.with_index()
        |> Enum.map(fn {%Task{} = m, col} ->
          x = @dag_pad + col * @dag_col_width + div(@dag_col_width - @dag_node_w, 2)
          y = @dag_pad + level * @dag_row_height

          %{
            id: m.id,
            level: level,
            col: col,
            x: x,
            y: y,
            w: @dag_node_w,
            h: @dag_node_h,
            status: m.status,
            label: m.title,
            num: stack_position_glyph(m.stack_position)
          }
        end)
      end)
      |> Enum.sort_by(& &1.id)

    node_by_id = Map.new(nodes, &{&1.id, &1})

    # Edge endpoints: source bottom-center → target top-center. Edges
    # whose endpoints aren't both placed (shouldn't happen for in-stack
    # edges, but guard anyway) are dropped.
    edge_records =
      edges
      |> Enum.flat_map(fn {from_id, to_id} ->
        with %{} = src <- Map.get(node_by_id, to_id),
             %{} = dst <- Map.get(node_by_id, from_id) do
          [
            %{
              from_id: from_id,
              to_id: to_id,
              x1: src.x + div(src.w, 2),
              y1: src.y + src.h,
              x2: dst.x + div(dst.w, 2),
              y2: dst.y
            }
          ]
        else
          _ -> []
        end
      end)

    # viewBox: width = max columns * col_width + 2*pad ; height = rows *
    # row_height + node_h + 2*pad (so the bottom row's full rect fits).
    width = max(max_cols, 1) * @dag_col_width + 2 * @dag_pad
    height = num_levels * @dag_row_height + @dag_node_h - @dag_row_height + 2 * @dag_pad
    height = max(height, @dag_node_h + 2 * @dag_pad)

    _ = member_by_id

    %{nodes: nodes, edges: edge_records, viewbox: {width, height}}
  end

  # Compute a level map `%{node_id => longest_path_from_root}` via
  # topological propagation. Roots (no in-stack deps) start at 0; each
  # successor's level becomes `max(parent_level + 1)` across its parents.
  # If the graph contains a cycle, nodes that never get processed default
  # to level 0 (the dep-edges meta-cell already flags cycles separately).
  defp dag_levels(members, edges) do
    # `parents` :: %{node_id => MapSet of predecessor ids}
    parents =
      Enum.reduce(edges, Map.new(members, fn %{id: id} -> {id, MapSet.new()} end), fn {from, to},
                                                                                      acc ->
        Map.update(acc, from, MapSet.new([to]), &MapSet.put(&1, to))
      end)

    # `children` :: %{node_id => MapSet of successor ids}
    children =
      Enum.reduce(edges, Map.new(members, fn %{id: id} -> {id, MapSet.new()} end), fn {from, to},
                                                                                      acc ->
        Map.update(acc, to, MapSet.new([from]), &MapSet.put(&1, from))
      end)

    in_degree = Map.new(parents, fn {id, ps} -> {id, MapSet.size(ps)} end)

    roots =
      in_degree
      |> Enum.filter(fn {_id, deg} -> deg == 0 end)
      |> Enum.map(&elem(&1, 0))

    initial_levels = Map.new(roots, &{&1, 0})

    do_dag_levels(roots, in_degree, children, initial_levels)
  end

  defp do_dag_levels([], _in_degree, _children, levels), do: levels

  defp do_dag_levels([id | rest], in_degree, children, levels) do
    parent_level = Map.get(levels, id, 0)
    succs = Map.get(children, id, MapSet.new())

    {in_degree, levels, queued} =
      Enum.reduce(succs, {in_degree, levels, []}, fn child, {ind, lvls, q} ->
        child_level = max(Map.get(lvls, child, 0), parent_level + 1)
        ind = Map.update(ind, child, 0, &max(&1 - 1, 0))
        lvls = Map.put(lvls, child, child_level)

        q =
          if Map.get(ind, child, 0) == 0 do
            [child | q]
          else
            q
          end

        {ind, lvls, q}
      end)

    do_dag_levels(rest ++ Enum.reverse(queued), in_degree, children, levels)
  end

  # Status → fill / stroke / caption / dasharray for a DAG node rect.
  # Mirrors the mock canvas 019e1a16 rev 2 palette:
  #   done       → green tint  (#7df0c0 stroke #3aa97c)
  #   in_review  → yellow tint (#ffd66e stroke #a37c3a)
  #   in_progress→ blue tint   (#7fd4f9 stroke #3a7ca3)
  #   waiting    → dashed gray (stack_pending / backlog)
  #   else       → neutral gray
  #
  # Captions are uppercase short codes (DONE / REVIEW / PROGRESS /
  # WAITING / status-string) — chosen to fit inside the 140px rect.
  defp dag_node_style("done") do
    %{
      fill: "rgba(0,255,157,0.12)",
      stroke: "#3aa97c",
      text: "#e6e9ee",
      num_color: "#7df0c0",
      caption_color: "#7df0c0",
      caption: "DONE",
      dasharray: nil
    }
  end

  defp dag_node_style("in_review") do
    %{
      fill: "rgba(255,190,0,0.12)",
      stroke: "#a37c3a",
      text: "#e6e9ee",
      num_color: "#ffd66e",
      caption_color: "#ffd66e",
      caption: "REVIEW",
      dasharray: nil
    }
  end

  defp dag_node_style("in_progress") do
    %{
      fill: "rgba(58,191,248,0.12)",
      stroke: "#3a7ca3",
      text: "#e6e9ee",
      num_color: "#7fd4f9",
      caption_color: "#7fd4f9",
      caption: "PROGRESS",
      dasharray: nil
    }
  end

  defp dag_node_style("deploying") do
    %{
      fill: "rgba(186,112,255,0.12)",
      stroke: "#7b5cff",
      text: "#e6e9ee",
      num_color: "#bba1ff",
      caption_color: "#bba1ff",
      caption: "DEPLOY",
      dasharray: nil
    }
  end

  defp dag_node_style(status) when status in ["stack_pending", "backlog"] do
    %{
      fill: "rgba(255,255,255,0.03)",
      stroke: "#3d4451",
      text: "#a6adba",
      num_color: "#6e7681",
      caption_color: "#6e7681",
      caption: "WAITING",
      dasharray: "4,3"
    }
  end

  defp dag_node_style(other) do
    %{
      fill: "rgba(255,255,255,0.04)",
      stroke: "#3d4451",
      text: "#a6adba",
      num_color: "#6e7681",
      caption_color: "#6e7681",
      caption: other |> to_string() |> String.upcase(),
      dasharray: nil
    }
  end

  # Truncate a node label to roughly the rect width (140px). Falls back
  # to a 14-char hard cap with ellipsis. Empty/nil labels render blank.
  defp dag_node_label(nil), do: ""
  defp dag_node_label(""), do: ""

  defp dag_node_label(label) when is_binary(label) do
    if String.length(label) > 14 do
      String.slice(label, 0, 13) <> "…"
    else
      label
    end
  end

  # ── Stack expansion helpers (T7 stage 3) ────────────────────────────────
  #
  # Numbered-node glyph for a member's `stack_position`. Positions 1..10
  # map to the unicode circled digits per ADR 0041 §"UI surface — inline
  # expansion"; positions 11+ fall back to `(N)` so the layout never
  # breaks on absurdly large stacks.
  defp stack_position_glyph(pos) when is_integer(pos) and pos in 1..10 do
    Enum.at(~w(① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩), pos - 1)
  end

  defp stack_position_glyph(pos) when is_integer(pos), do: "(#{pos})"
  defp stack_position_glyph(_), do: "(?)"

  # Styling for the round numbered node next to a member's title. Varies
  # by status per mock canvas 019e1a16 rev 2: done → success tint,
  # in_review → warning tint, stack_pending / backlog → dashed gray,
  # everything else → neutral base-300 ring.
  defp member_node_class("done"), do: "bg-success/20 text-success border border-success/40"

  defp member_node_class("in_review"),
    do: "bg-warning/20 text-warning border border-warning/40"

  defp member_node_class("stack_pending"),
    do: "bg-base-300 text-base-content/40 border border-base-300 border-dashed"

  defp member_node_class("backlog"),
    do: "bg-base-300 text-base-content/40 border border-base-300 border-dashed"

  defp member_node_class(_),
    do: "bg-base-200 text-base-content/70 border border-base-300"

  # Render the dep-annotation line for a single in-stack member. The
  # output mirrors the mock's `needs ① • parallel with ②` text:
  #
  #   * `needs <glyph>[ + <glyph>...]` — joined with ` + ` when the
  #     member has multiple in-stack predecessors.
  #   * `parallel with <glyph>[ + ...]` — appended (separated by ` • `)
  #     when another in-stack member at a different position shares the
  #     same dep set (siblings runnable in parallel).
  #
  # Returns `nil` when the member has no in-stack deps AND no parallel
  # siblings — the template suppresses the dep-line entirely in that
  # case (per mock: member ① has no annotation line).
  defp dep_annotation_text(%Task{} = member, members) when is_list(members) do
    member_ids = MapSet.new(members, & &1.id)

    self_deps =
      member
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == member.id))
      |> Enum.filter(&MapSet.member?(member_ids, &1))
      |> Enum.uniq()

    case self_deps do
      [] ->
        nil

      _ ->
        needs =
          self_deps
          |> Enum.map(fn dep_id ->
            members
            |> Enum.find(&(&1.id == dep_id))
            |> case do
              nil -> nil
              %Task{stack_position: pos} -> stack_position_glyph(pos)
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" + ")

        parallel =
          members
          |> Enum.filter(fn other ->
            other.id != member.id and
              other.stack_position != member.stack_position and
              dep_set(other, member_ids) == MapSet.new(self_deps) and
              MapSet.size(dep_set(other, member_ids)) > 0
          end)
          |> Enum.map(&stack_position_glyph(&1.stack_position))
          |> Enum.sort()
          |> Enum.join(" + ")

        cond do
          needs == "" -> nil
          parallel == "" -> "needs #{needs}"
          true -> "needs #{needs} • parallel with #{parallel}"
        end
    end
  end

  defp dep_annotation_text(_, _), do: nil

  # In-stack dep id set for a member (used by `parallel with` detection).
  defp dep_set(%Task{} = task, member_ids_set) do
    task
    |> Tasks.dependency_task_ids()
    |> Enum.reject(&(&1 == task.id))
    |> Enum.filter(&MapSet.member?(member_ids_set, &1))
    |> MapSet.new()
  end

  # ── Stack members list helpers (T8 stage 4) ─────────────────────────────
  #
  # `member_dep_annotation/2` builds the "depends on ① + ②" /
  # "depends on ① (parallel with ②)" sub-line that appears under each
  # member row in the linear members list (right column of the stack
  # detail panel body). This is a sibling of `dep_annotation_text/2`
  # which serves the inline T7 board-card expansion using the older
  # "needs ① • parallel with ②" format. The two formats diverged on
  # purpose: the panel mock (canvas 019e1a16 rev 2) uses the longer
  # "depends on" wording with parens for parallels, while the inline
  # board card stays terse with "needs". Returns `nil` when the member
  # has no in-stack predecessors so the template can suppress the row.
  #
  # Parallel detection: members at a different `stack_position` whose
  # in-stack dep set is identical to this member's. Same shape as the
  # DAG layout's same-level grouping so the textual annotation and the
  # SVG layout never disagree about who is parallel with whom.
  defp member_dep_annotation(%Task{} = member, members) when is_list(members) do
    member_ids = MapSet.new(members, & &1.id)

    self_deps =
      member
      |> Tasks.dependency_task_ids()
      |> Enum.reject(&(&1 == member.id))
      |> Enum.filter(&MapSet.member?(member_ids, &1))
      |> Enum.uniq()

    case self_deps do
      [] ->
        nil

      _ ->
        depends_on =
          self_deps
          |> Enum.map(fn dep_id ->
            members
            |> Enum.find(&(&1.id == dep_id))
            |> case do
              nil -> nil
              %Task{stack_position: pos} -> stack_position_glyph(pos)
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" + ")

        parallel =
          members
          |> Enum.filter(fn other ->
            other.id != member.id and
              other.stack_position != member.stack_position and
              dep_set(other, member_ids) == MapSet.new(self_deps) and
              MapSet.size(dep_set(other, member_ids)) > 0
          end)
          |> Enum.map(&stack_position_glyph(&1.stack_position))
          |> Enum.sort()
          |> Enum.join(" + ")

        cond do
          depends_on == "" -> nil
          parallel == "" -> "depends on #{depends_on}"
          true -> "depends on #{depends_on} (parallel with #{parallel})"
        end
    end
  end

  defp member_dep_annotation(_, _), do: nil

  # Status pill class + label for a stack member row in the linear list.
  # Mirrors the four mock tones (.b-status-done / -rev / -prog / -wait)
  # so the right-column pills colour-match the DAG node fills exactly.
  defp member_status_pill("done"),
    do: {"Done", "bg-success/20 text-success"}

  defp member_status_pill("in_review"),
    do: {"Review", "bg-warning/20 text-warning"}

  defp member_status_pill("in_progress"),
    do: {"In Progress", "bg-info/20 text-info"}

  defp member_status_pill("deploying"),
    do: {"Deploying", "bg-secondary/20 text-secondary"}

  defp member_status_pill(status) when status in ["stack_pending", "backlog"],
    do:
      {"Waiting", "bg-base-300 text-base-content/50 border border-dashed border-base-content/20"}

  defp member_status_pill(other),
    do: {status_label(other), "bg-base-300 text-base-content/70"}

  # Stage-2 of task 019e2c25: maps the `Tasks.needs_human_action_reason/2`
  # atom to a `{label, data-action-reason-string}` tuple used by the
  # stack-detail member-row badge. The string is what we expose via
  # `data-action-reason` so tests + dataview drilldowns can target the
  # exact predicate branch. `nil` reason → `{nil, nil}`, which the
  # template's `:if` condition uses to suppress the badge.
  defp stack_member_action_label(:plan_pending_review), do: {"Plan ready", "plan_pending_review"}

  defp stack_member_action_label(:review_request_pending),
    do: {"Needs review", "review_request_pending"}

  defp stack_member_action_label(:validation_failed), do: {"Needs review", "validation_failed"}
  defp stack_member_action_label(nil), do: {nil, nil}

  # Stage-4 follow-up of task 019e2c25 (post-rejection fix): on the
  # mobile surfaces (stack-member rows and solo task cards) the existing
  # `task_display_status/1` chip ALREADY surfaces "Plan Ready" with a
  # warning badge for the `:plan_pending_review` case (status="planning"
  # + a plan in `pending_review`). Rendering the action chip there too
  # produces a doubled chip ("Plan Ready" + "Plan ready") on the same
  # row. Suppress the action chip for that branch on mobile — the status
  # chip is the single signal. Action chip still surfaces for
  # `:review_request_pending` and `:validation_failed`, which the status
  # chip does NOT cover. Desktop stack-detail uses `member_status_pill/1`
  # (no "Plan Ready" overlap), so no change there.
  defp mobile_stack_member_action_label(:plan_pending_review), do: {nil, nil}
  defp mobile_stack_member_action_label(reason), do: stack_member_action_label(reason)

  # Bridge between the string-keyed `@kanban_columns` template iteration
  # and the atom-keyed `:columns` map produced by
  # `Platform.Tasks.list_by_status/1`. Returns the task list for the
  # given column key (string), empty list if the column key doesn't map
  # to a known kanban status atom. Wrapped in a function so the template
  # doesn't have to deal with `String.to_existing_atom/1` inline.
  defp tasks_in_column(columns, col_key) when is_map(columns) and is_binary(col_key) do
    case Map.fetch(columns, String.to_existing_atom(col_key)) do
      {:ok, list} -> list
      :error -> []
    end
  rescue
    ArgumentError -> []
  end

  defp tasks_in_column(_columns, _col_key), do: []

  # Merge tasks (from `@columns`, atom-keyed) and stacks (from
  # `@desktop_stacks_by_column`, string-keyed) into a single
  # `updated_at`-desc list for one desktop kanban column. Mirrors the
  # `group_board_items/2` per-column sort so stacks and standalone
  # tasks interleave by recency (ADR 0041 acceptance criterion 1).
  #
  # Stack-member tasks (`stack_id != nil`) are suppressed here — they
  # render only under their parent stack card, never as their own
  # column entry. `Platform.Tasks.list_by_status/1` doesn't pre-filter
  # stack members (it serves the wider task set), so the filter lives
  # in this render-shaping layer.
  defp desktop_column_items(columns, stacks_by_column, col_key) do
    tasks =
      columns
      |> tasks_in_column(col_key)
      |> Enum.filter(&is_nil(&1.stack_id))

    stacks = Map.get(stacks_by_column || %{}, col_key, [])

    (tasks ++ stacks)
    |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})
  end

  # Stage-3 wrapper: filters `desktop_column_items/3` through the active
  # scope-rail selection. `:all` is the unfiltered passthrough. `:fabrikam`
  # also returns the full list today because every task folds under :fabrikam
  # until `tasks.org_id` lands (the same contract `count_by_scope/0`
  # encodes). The other four scopes return an empty list today; once
  # MT/RBAC ships this helper becomes the single seam to swap in real
  # per-task scope filtering.
  defp desktop_column_items_for_scope(columns, stacks_by_column, col_key, :all) do
    desktop_column_items(columns, stacks_by_column, col_key)
  end

  defp desktop_column_items_for_scope(columns, stacks_by_column, col_key, :fabrikam) do
    desktop_column_items(columns, stacks_by_column, col_key)
  end

  defp desktop_column_items_for_scope(_columns, _stacks_by_column, _col_key, scope)
       when scope in [:soylent, :wayne_tech, :sxi, :paragon, :cyberdyne] do
    []
  end

  defp desktop_column_items_for_scope(columns, stacks_by_column, col_key, _other) do
    desktop_column_items(columns, stacks_by_column, col_key)
  end

  # Parse the inbound scope payload into the canonical atom. `"all"` is the
  # rail's reset value; the five sub-org strings round-trip to their atoms
  # via the explicit allowlist (Tasks.scope_keys/0). Returns `:error` for
  # unknown values so the caller can ignore garbage without crashing.
  defp parse_scope("all"), do: {:ok, :all}

  defp parse_scope(scope) when is_binary(scope) do
    Enum.find_value(Tasks.scope_keys(), :error, fn key ->
      if Atom.to_string(key) == scope, do: {:ok, key}
    end)
  end

  defp parse_scope(_), do: :error

  # Stage-2 of task 019f3f22: decode the `?sponsor` URL param into the
  # canonical filter atom. Only `"mine"` activates the filter — everything
  # else (missing, empty, garbage) resolves to `:all` so malformed URLs
  # can't hang the mount.
  defp decode_sponsor_param(%{"sponsor" => "mine"}), do: :mine
  defp decode_sponsor_param(_), do: :all

  # Resolve the current filter state to the `sponsor_user_id:` opt value
  # threaded into `list_by_status/1` / `list_all_tasks/1`. `:mine` maps
  # to the logged-in user's id (or `nil` if the session lacks one, which
  # is a defensive belt-and-suspenders since `/tasks` requires auth); any
  # other filter state is unfiltered.
  defp sponsor_filter_user_id(socket) do
    case socket.assigns[:sponsor_filter] do
      :mine -> socket.assigns[:current_user_id]
      _ -> nil
    end
  end

  # Stage-2 of task 019f3f22 (renamed from `sponsor_filter_board_empty?/4`
  # in re-skin Phase 2 stage 2): true when every kanban column resolves to
  # an empty item list through the scope-filter lens. Shared by the
  # sponsor-filter empty state AND the search "no matching tasks" banner,
  # so neither empty-state lies when multiple filters are active. Called
  # once per render inside each empty-state `:if`.
  #
  # Stage-3 of task 019f487e invariant note (do NOT re-derive this):
  # `desktop_column_items_for_scope/4` merges tasks with stacks from
  # `desktop_stacks_by_column` (grouped from `stack_entries` in
  # `refresh_board/1`). Since stage 3 now applies `:sponsor_user_id` to
  # the `Stacks.list_stacks_with_members/1` call that produces
  # `stack_entries`, the stack half of the merge is naturally narrowed
  # too — there's nothing to do here. The empty-state signal correctly
  # reflects tasks-AND-stacks visibility because both halves flow
  # through the same filtered pipeline.
  defp board_columns_empty?(kanban_columns, columns, stacks_by_column, scope_filter) do
    Enum.all?(kanban_columns, fn {col_key, _label} ->
      desktop_column_items_for_scope(columns, stacks_by_column, col_key, scope_filter) == []
    end)
  end

  # Stage-3 scope rail (2026-05-19): the "All" chip's badge count is the
  # sum of every sub-org bucket. Reading from `@scope_counts` keeps the
  # rail's denominator and per-chip counts wired to the same source of
  # truth (today: all tasks fold under :fabrikam; future: real per-org
  # buckets sum to the same total).
  defp scope_count_total(scope_counts) when is_map(scope_counts) do
    scope_counts
    |> Map.values()
    |> Enum.sum()
  end

  defp scope_count_total(_), do: 0

  defp column_header_class("backlog"), do: "text-base-content/60"
  # Planning + blocked split out from Backlog in Stage 2 of Tasks v2.
  # Planning leans on the neutral accent (work that hasn't started yet);
  # blocked uses the error accent so it visually stands out — the whole
  # point of the dedicated column is to surface things needing unblock.
  defp column_header_class("planning"), do: "text-base-content/60"
  defp column_header_class("in_progress"), do: "text-info"
  defp column_header_class("blocked"), do: "text-error"
  defp column_header_class("in_review"), do: "text-warning"
  defp column_header_class("deploying"), do: "text-secondary"
  defp column_header_class("done"), do: "text-success"
  defp column_header_class(_), do: "text-base-content/60"

  # Used by the mobile task list (tasks_live.html.heex) — color-coded dots
  # mirror the column header colors so the visual cue is consistent across
  # mobile (dot per card) and desktop (column header) layouts.
  defp status_dot_class("backlog"), do: "bg-base-content/30"
  defp status_dot_class("in_progress"), do: "bg-info"
  defp status_dot_class("in_review"), do: "bg-warning"
  defp status_dot_class("deploying"), do: "bg-secondary"
  defp status_dot_class("done"), do: "bg-success"
  defp status_dot_class(_), do: "bg-base-content/30"

  defp empty_board?(columns) when is_map(columns) do
    Enum.all?(columns, fn {_key, tasks} -> tasks == [] end)
  end

  # Used by the mobile-list empty state. Looks up the label that matches the
  # currently active status filter so the empty-state message reads
  # naturally — 'No tasks in In Progress.' rather than 'No tasks in in_progress.'
  defp active_status_label(status, columns) do
    case Enum.find(columns, fn {key, _label} -> key == status end) do
      {_key, label} -> label
      nil -> status
    end
  end

  defp has_active_run?(%Task{} = _task) do
    # TODO: check active runs via Execution plane when wired up
    false
  end

  defp plan_progress(%Task{plans: plans}) when is_list(plans) do
    case Enum.find(plans, &(&1.status in ~w(approved executing))) do
      nil ->
        nil

      plan ->
        stages = plan.stages || []
        total = length(stages)

        if total > 0 do
          completed = Enum.count(stages, &(&1.status in ~w(passed skipped)))
          {completed, total}
        else
          nil
        end
    end
  end

  defp plan_progress(_), do: nil

  defp assignee_identity(%Task{assignee_type: nil}, _users_by_id, _agents_by_id), do: nil

  defp assignee_identity(
         %Task{assignee_type: "agent", assignee_id: id},
         _users_by_id,
         agents_by_id
       )
       when is_binary(id) do
    agent = Map.get(agents_by_id, id)

    %{
      type: :agent,
      name: agent_name(agent),
      seed: id
    }
  end

  defp assignee_identity(
         %Task{assignee_type: "user", assignee_id: id},
         users_by_id,
         _agents_by_id
       )
       when is_binary(id) do
    user = Map.get(users_by_id, id)

    %{
      type: :user,
      name: user_name(user),
      avatar_url: user && user.avatar_url,
      seed: user_seed(user, id)
    }
  end

  defp assignee_identity(_task, _users_by_id, _agents_by_id), do: nil

  defp agent_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp agent_name(_agent), do: "Agent"

  defp user_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp user_name(%{email: email}) when is_binary(email) and email != "", do: email
  defp user_name(_user), do: "User"

  defp user_seed(%{oidc_sub: oidc_sub}, _fallback) when is_binary(oidc_sub) and oidc_sub != "",
    do: oidc_sub

  defp user_seed(%{email: email}, _fallback) when is_binary(email) and email != "", do: email
  defp user_seed(_user, fallback), do: fallback

  defp agent_initials(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "A"
      ch -> String.upcase(ch)
    end
  end

  defp agent_initials(_name), do: "A"

  defp assignee_name(%Task{assignee_type: "agent", assignee_id: id}, agent_names)
       when is_binary(id) do
    Map.get(agent_names, id, "Agent")
  end

  defp assignee_name(%Task{assignee_type: "user"}, _agent_names), do: "User"

  defp assignee_name(_, _), do: nil

  # ── Pin-to-Chat sponsor + pinned-state helpers (task 019f62a1 stage 4) ──
  #
  # `sponsor?/2` is the authoritative gate for BOTH the DOM `:if` (button
  # rendered only for the task sponsor) AND the server-side re-check inside
  # `toggle_task_chat_pin` (any bypass logs + refuses). We match on
  # `Task.sponsor_user_id` — the ADR-0042 identity column — not on
  # `reported_by` (creator, retained for audit even after a sponsor
  # reassign). Sponsor-less tasks (`sponsor_user_id == nil`) yield `false`
  # for everyone: no pin surface until the sponsor slot is filled.
  #
  # `pinned_by_me?/3` reads the socket-side MapSet seeded at mount and
  # kept fresh by the `:task_pin_added` / `:task_pin_removed` handlers.
  # No Repo query per render, so the detail panel stays paint-hot.
  defp sponsor?(%Task{sponsor_user_id: sponsor_id}, user_id)
       when is_binary(sponsor_id) and is_binary(user_id),
       do: sponsor_id == user_id

  defp sponsor?(_task, _user_id), do: false

  defp pinned_by_me?(%Task{id: id}, user_id, %MapSet{} = pinned_ids)
       when is_binary(user_id),
       do: MapSet.member?(pinned_ids, id)

  defp pinned_by_me?(_task, _user_id, _pinned_ids), do: false

  # Resolve the acting user's email once at mount so the pin flow doesn't
  # do a Repo.get on every keystroke of the detail panel. Nil when the
  # session has no user_id (anonymous) or the user row was deleted.
  defp fetch_user_email(nil), do: nil

  defp fetch_user_email(user_id) when is_binary(user_id) do
    case Accounts.get_user(user_id) do
      %{email: email} when is_binary(email) -> email
      _ -> nil
    end
  end

  # Detail-panel Sponsor badge (ADR 0042 stage 4). Returns the display name
  # for the sponsor if set, or `nil` so the template can `:if` the whole row
  # away when there's no sponsor. Falls back to `email` when `name` is blank,
  # and to a sentinel string when the FK points at a user that no longer
  # exists in the local `users_by_id` map (deleted user + stale task row).
  defp sponsor_name(%Task{sponsor_user_id: nil}, _users_by_id), do: nil

  defp sponsor_name(%Task{sponsor_user_id: id}, users_by_id) when is_binary(id) do
    case Map.get(users_by_id, id) do
      nil -> "Unknown user"
      user -> user.name || user.email
    end
  end

  defp sponsor_name(_, _), do: nil

  # ADR 0042 stage 1 (task 019f3f22): sponsor chip on task cards. Mirrors
  # `assignee_identity/3` — returns a `%{name, avatar_url, seed}` map for
  # `<.human_avatar>` or `nil` when the task has no sponsor. Falls back to a
  # sentinel entry (name "Unknown user", no avatar, seed=id) when the FK
  # points at a user no longer in `users_by_id`, matching `sponsor_name/2`'s
  # deleted-user behaviour so the chip still renders instead of blinking on
  # ownership churn.
  defp sponsor_identity(%Task{sponsor_user_id: nil}, _users_by_id), do: nil

  defp sponsor_identity(%Task{sponsor_user_id: id}, users_by_id) when is_binary(id) do
    user = Map.get(users_by_id, id)

    %{
      name: (user && (user.name || user.email)) || "Unknown user",
      avatar_url: user && user.avatar_url,
      seed: user_seed(user, id)
    }
  end

  # Stage 4 of task 019f487e (ADR-0042 Decision 8): stack cards now surface
  # the sponsor avatar too. Same shape as the task-sponsor path above — a
  # nil `sponsor_user_id` returns `nil` so the template `:if`s the avatar
  # away, and a missing user id falls back to the "Unknown user" sentinel
  # rather than blinking off on ownership churn.
  defp sponsor_identity(%Stack{sponsor_user_id: nil}, _users_by_id), do: nil

  defp sponsor_identity(%Stack{sponsor_user_id: id}, users_by_id) when is_binary(id) do
    user = Map.get(users_by_id, id)

    %{
      name: (user && (user.name || user.email)) || "Unknown user",
      avatar_url: user && user.avatar_url,
      seed: user_seed(user, id)
    }
  end

  defp sponsor_identity(_, _), do: nil

  defp relative_time(nil), do: ""

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp relative_time(%NaiveDateTime{} = ndt) do
    ndt |> DateTime.from_naive!("Etc/UTC") |> relative_time()
  end

  defp default_task_agent_id([agent | _]), do: agent.id
  defp default_task_agent_id([]), do: nil

  defp default_task_form_attrs(nil), do: %{}

  defp default_task_form_attrs(agent_id) do
    %{"assignee_id" => agent_id, "assignee_type" => "agent"}
  end

  # Pre-populate the New-Epic form with the currently selected project (if
  # any) so users on a filtered board don't have to re-select it. The form
  # hides the project select entirely in that mode and renders a hidden
  # input instead.
  defp default_epic_form_attrs(socket) do
    case socket.assigns[:selected_project_id] do
      nil -> %{}
      id -> %{"project_id" => id}
    end
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

  # Stage 5 of ADR-0042: bucket `[%Project{org: %Org{}}]` into
  # `[{org_slug, org_name, [project]}]` tuples. Order matches the
  # canonical `Tenancy.tenant_priority/0` (Fabrikam → Soylent → Wayne-Tech →
  # SXI → Paragon → unknown tenants alphabetically); inside each bucket
  # projects are already alphabetically sorted by `Tasks.list_projects_for_user/2`.
  #
  # Implementation lives in `Platform.Projects.group_by_org/1` (extracted
  # in the Files-surface stage so files + tasks share one grouper). Kept
  # as a delegating wrapper here so call sites already reading
  # `group_projects_by_org/1` don't churn.
  defp group_projects_by_org(projects), do: Platform.Projects.group_by_org(projects)

  # Navigation-sidebar source (task 019f4eaa follow-up): every ACTIVE org the
  # VIEWER BELONGS TO gets a section, even at zero projects, so archiving an
  # org's last project can't erase its header — and with it the lifecycle kebab that archives the org
  # itself. `group_projects_by_org/1` stays the SELECTION source for the
  # New-Task / New-Epic <select>s, which must not render empty <optgroup>s.
  #
  # The org list is VIEWER-SCOPED (`list_active_tenants_for_user/1`). Grouping a
  # correctly-scoped project list by the unscoped org list still rendered a
  # header naming every foreign org at a `0` count — an existence leak in its
  # own right. Every caller must therefore pass the viewer.
  defp project_sections(projects, viewer) do
    Platform.Projects.group_by_active_org(
      projects,
      Tenancy.list_active_tenants_for_user(viewer)
    )
  end

  # Reload projects + recompute every container-derived assign after an
  # archive / schedule-deletion so the archived row leaves the sidebar and
  # an archived org drops off the scope rail without a page reload.
  defp refresh_containers(socket) do
    projects = Tasks.list_projects_for_user(socket.assigns[:current_user_record], preload: :org)

    socket
    |> assign(:projects, projects)
    |> assign(:projects_by_org, group_projects_by_org(projects))
    |> assign(:project_sections, project_sections(projects, socket.assigns[:current_user_record]))
    |> assign(:active_scope_keys, active_scope_keys(socket.assigns[:current_user_record]))
  end

  # Scope-rail source (task 019f4eaa stage 6; hardened by task 019fa209;
  # viewer-scoped since): the scope atoms whose org is currently non-archived
  # AND VISIBLE TO THIS VIEWER, in canonical tenant-priority order.
  #
  # The tenant read is `Tenancy.list_active_tenants_for_user/1` — the
  # viewer-scoped sibling of `list_active_tenants_unscoped/0`. It filters on
  # `archived_at` AND the viewer's `org_memberships` in the query (root/Fabrikam
  # admins bypass the membership filter by design and still see every active
  # org). `list_active_tenants_unscoped/0` leaked the NAMES of orgs the
  # viewer has no membership in onto the rail, which is why this function
  # takes a viewer and has no zero-arity form: a viewer-less call must fail to
  # COMPILE, mirroring the viewer-taking `Tasks.list_projects_for_user/2` and
  # `project_sections/2`. Never re-add a `/0` shim, and never filter an
  # unscoped tenant list at a call site — scope belongs in the viewer-taking
  # context read.
  #
  # The allowlist-first construction below is UNCHANGED and must stay:
  # `Tasks.scope_keys/0` filtered by active slugs, compared as STRINGS, never
  # `String.to_atom/1` (nor `String.to_existing_atom/1`). That shape closes the
  # two crash modes covered by the task-019fa209 regression tests; reverting to
  # atom conversion re-opens a /tasks outage for every user.
  #
  # Org slugs are EXTERNALLY SUPPLIED — `Org.changeset/2` accepts any
  # `^[a-z][a-z0-9_-]*$` and the tenant reads filter only on `archived_at`
  # (plus membership), so an active tenant's slug may never have been compiled
  # as an atom. This iterates the canonical allowlist and keeps the ones that are
  # active, comparing as STRINGS: no atom is created (`String.to_atom/1` would
  # grow the never-GC'd atom table from user input) and none is looked up
  # (`String.to_existing_atom/1` raises `ArgumentError`, which 500'd /tasks for
  # every user in the deployment — this ran in `mount/3`).
  #
  # Filtering rather than converting also closes a SECOND crash: a slug that
  # happens to already exist as an atom but is not a scope (e.g. "name" ->
  # `:name`, which exists because it is an Ecto field on `Org`) sails through
  # `to_existing_atom/1` and reaches `<.scope_pill>`, whose `scope_label/1` and
  # `slug/1` clauses are non-total -> `FunctionClauseError` at render. Both
  # failures are why a `rescue ArgumentError` would be the wrong fix; starting
  # from the allowlist makes every element a valid `<.scope_pill>` value by
  # construction.
  #
  # An org outside the enum gets no chip. That is the only behavior the rest of
  # the system supports: the enum is hardcoded in `ScopePill` (`@scopes` +
  # `slug/1` + `scope_label/1`), `Tasks.@scope_keys`,
  # `Tenancy.@scope_classes`/`@scope_labels`, and the `bg-<slug>` /
  # `border-<slug>` / `text-<slug>-label` / `bg-<slug>-dot` utilities in
  # assets/css/app.css. A truly data-driven rail needs color allocation for
  # arbitrary orgs and is out of scope for a crash fix.
  #
  # Order is preserved: `Tasks.scope_keys/0` LEADS with the same five slugs in the same
  # sequence as `Tenancy.tenant_priority/0` (`:cyberdyne` appends; the 9_999 unknown-slug sentinel sorts it last there too), so for seeded orgs the output is
  # identical to the old `sort_by_tenant_priority/2` result. Mirrors
  # `parse_scope/1` above — allowlist first, never convert.
  defp active_scope_keys(viewer) do
    active = MapSet.new(Tenancy.list_active_tenants_for_user(viewer), & &1.slug)

    Enum.filter(Tasks.scope_keys(), &MapSet.member?(active, Atom.to_string(&1)))
  end

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

  defp deletable_task?(%Task{} = task), do: Task.deletable?(task)
  defp deletable_task?(_), do: false

  defp available_transitions("backlog"), do: [{"planning", "Start Planning"}]
  # ADR 0029: plan approval is the start signal. From `planning`, the only
  # manual transition is back to backlog to abandon. Entering execution is
  # gated by `Tasks.require_approved_plan_for/2` and triggered by approving
  # a plan, which transitions the task directly into `in_progress`.
  defp available_transitions("planning"), do: [{"backlog", "Back"}]

  defp available_transitions("in_progress"),
    do: [{"in_review", "Submit for Review"}, {"done", "Mark Done"}]

  # Review outcomes flow through validations / review requests, not blunt status buttons.
  defp available_transitions("in_review"), do: []

  # Deploying outcomes flow through deploy stage validations, not manual transitions.
  defp available_transitions("deploying"), do: []

  defp available_transitions("blocked"),
    do: [{"backlog", "To Backlog"}, {"in_progress", "Resume"}]

  defp available_transitions("done"), do: []
  defp available_transitions(_), do: []

  defp transition_btn_class(status) do
    case status do
      "done" -> "btn btn-sm btn-success"
      "in_review" -> "btn btn-sm btn-warning"
      "in_progress" -> "btn btn-sm btn-info"
      _ -> "btn btn-sm btn-ghost"
    end
  end

  defp enrich_epics(epics) do
    epic_ids = Enum.map(epics, & &1.id)
    counts = Tasks.epic_task_counts(epic_ids)

    Enum.map(epics, fn epic ->
      c = Map.get(counts, epic.id, %{total: 0, done: 0})

      %{
        id: epic.id,
        name: epic.name,
        description: epic.description,
        status: epic.status,
        task_count: c.total,
        done_count: c.done
      }
    end)
  end

  defp epic_status_badge_class("in_progress"), do: "badge badge-warning badge-xs"
  defp epic_status_badge_class("closed"), do: "badge badge-success badge-xs"
  defp epic_status_badge_class(_), do: "badge badge-ghost badge-xs"

  defp format_log_timestamp(nil), do: ""

  defp format_log_timestamp(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if Date.compare(DateTime.to_date(dt), DateTime.to_date(now)) == :eq do
      # Today — just HH:MM
      Calendar.strftime(dt, "%H:%M")
    else
      # Older — Mon DD HH:MM
      Calendar.strftime(dt, "%b %d %H:%M")
    end
  end

  defp log_sender_color("agent", "system"), do: "text-warning"
  defp log_sender_color("agent", _content_type), do: "text-info"
  defp log_sender_color("user", _content_type), do: "text-primary"
  defp log_sender_color(_sender_type, _content_type), do: "text-base-content/60"

  defp stage_status_icon("passed"), do: "hero-check-circle text-success"
  defp stage_status_icon("failed"), do: "hero-x-circle text-error"
  defp stage_status_icon("running"), do: "hero-arrow-path text-info animate-spin"
  defp stage_status_icon("skipped"), do: "hero-minus-circle text-base-content/40"
  defp stage_status_icon(_), do: "hero-clock text-base-content/40"

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:too_many_files), do: "Too many files selected"
  defp upload_error_to_string(:not_accepted), do: "File type is not accepted"
  defp upload_error_to_string(error), do: inspect(error)

  # ── Plan revision folding helpers ───────────────────────────────────────

  # Centralised assign for `:selected_task` that also resets the per-task
  # `:expanded_plans` MapSet so the active plan(s) start expanded and any
  # rejected plans the user previously toggled open in another task don't
  # leak across selections.
  defp assign_selected_task(socket, nil) do
    socket
    |> assign(:selected_task, nil)
    |> assign(:selected_task_canvases, [])
    |> assign(:expanded_plans, MapSet.new())
    |> assign(:edit_mode, false)
    |> assign(:merge_control, nil)
  end

  defp assign_selected_task(socket, %Task{} = task) do
    socket
    |> assign(:selected_task, task)
    |> assign(:selected_task_canvases, load_attached_canvases(task.id))
    |> assign(:expanded_plans, MapSet.new(default_expanded_plan_ids(task)))
    |> assign(:edit_mode, false)
    |> assign(:merge_control, MergeControl.for_task(task))
  end

  # Flatten `CanvasAttachments.list_task_canvases/1` into a chip-render
  # shape (`canvas_id`, `title`, `canvas_present`). Soft-deleted canvases
  # stay in the list with `canvas_present: false` so the strip can render
  # a "(deleted canvas)" affordance + detach button rather than silently
  # dropping the stale row.
  defp load_attached_canvases(task_id) when is_binary(task_id) do
    task_id
    |> CanvasAttachments.list_task_canvases()
    |> Enum.map(fn %{attachment: attachment, canvas: canvas} ->
      %{
        canvas_id: attachment.canvas_id,
        title: canvas && canvas.title,
        canvas_present: not is_nil(canvas)
      }
    end)
  end

  defp load_attached_canvases(_), do: []

  # Returns `{rejected_plans, active_plans}` where `rejected_plans` are the
  # plans with `status == "rejected"` sorted oldest-first by `version`, and
  # `active_plans` is everything else in the order it was preloaded (the
  # heex render path historically just iterated `task.plans` directly).
  def partition_plans(%Task{plans: plans}), do: partition_plans(plans)

  def partition_plans(plans) when is_list(plans) do
    {rejected, active} = Enum.split_with(plans, &(&1.status == "rejected"))
    {Enum.sort_by(rejected, & &1.version), active}
  end

  def partition_plans(_), do: {[], []}

  # IDs of plans that should be expanded by default — every non-rejected
  # plan, so existing behavior (active plan shown in full) is preserved.
  defp default_expanded_plan_ids(%Task{plans: plans}), do: default_expanded_plan_ids(plans)

  defp default_expanded_plan_ids(plans) when is_list(plans) do
    plans
    |> Enum.reject(&(&1.status == "rejected"))
    |> Enum.map(& &1.id)
  end

  defp default_expanded_plan_ids(_), do: []

  defp plan_expanded?(%MapSet{} = expanded_plans, %Plan{id: id}),
    do: MapSet.member?(expanded_plans, id)

  defp plan_expanded?(_expanded_plans, _plan), do: false

  # Treats nil and whitespace-only strings as absent. Used by the
  # template to skip rendering empty rejection-reason boxes on legacy
  # rows pre-migration.
  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # Singular/plural "member" for stack-cascade flash summaries.
  defp member_word(1), do: "member"
  defp member_word(_), do: "members"

  # Singular/plural "request" for the stack-feedback overlay header copy.
  defp request_word(1), do: "request"
  defp request_word(_), do: "requests"

  # Human-readable summary string used in the folded row for a rejected
  # plan revision. When the plan was auto-superseded by a newer revision
  # (`superseded_by_plan_id` non-nil + `:superseded_by` association
  # loaded), render a concise "superseded by vN on DATE" label and skip
  # the rejection_reason excerpt — the supersession IS the reason and
  # the canned excerpt would just be redundant. Otherwise (manual reject
  # via the 019dfad1 free-text path, or legacy/edge cases) fall through
  # to the original "rejected on DATE — \"reason excerpt\"" rendering.
  def plan_summary_label(
        %Plan{superseded_by_plan_id: sup_id, superseded_by: %Plan{} = sup} = plan
      )
      when not is_nil(sup_id) do
    "Plan v#{plan.version} — superseded by v#{sup.version}#{format_supersession_date(plan.updated_at)}"
  end

  def plan_summary_label(%Plan{version: version, updated_at: %DateTime{} = updated_at} = plan) do
    base = "Plan v#{version} — rejected on #{Calendar.strftime(updated_at, "%Y-%m-%d")}"
    append_rejection_excerpt(base, plan.rejection_reason)
  end

  def plan_summary_label(
        %Plan{version: version, updated_at: %NaiveDateTime{} = updated_at} = plan
      ) do
    base = "Plan v#{version} — rejected on #{Calendar.strftime(updated_at, "%Y-%m-%d")}"
    append_rejection_excerpt(base, plan.rejection_reason)
  end

  def plan_summary_label(%Plan{version: version} = plan) do
    base = "Plan v#{version} — rejected"
    append_rejection_excerpt(base, plan.rejection_reason)
  end

  # Date suffix for the supersession label. Mirrors the format used by
  # the rejected-on rendering. Tolerates missing/non-loaded timestamps
  # gracefully — falls back to no suffix rather than crashing the row.
  defp format_supersession_date(%DateTime{} = dt),
    do: " on #{Calendar.strftime(dt, "%Y-%m-%d")}"

  defp format_supersession_date(%NaiveDateTime{} = dt),
    do: " on #{Calendar.strftime(dt, "%Y-%m-%d")}"

  defp format_supersession_date(_), do: ""

  # Appends a truncated, quoted rejection-reason excerpt to the summary
  # label. Truncation cap is 60 chars with a single-character ellipsis
  # appended past that. nil/blank reason → no change (legacy rows).
  defp append_rejection_excerpt(label, nil), do: label
  defp append_rejection_excerpt(label, ""), do: label

  defp append_rejection_excerpt(label, reason) when is_binary(reason) do
    excerpt =
      if String.length(reason) > 60 do
        String.slice(reason, 0, 60) <> "…"
      else
        reason
      end

    "#{label} — \"#{excerpt}\""
  end

  # Function component: renders the inner body of a plan. Each stage card
  # carries its own per-stage validations (test_pass / lint_pass /
  # manual_approval) inline — there is no longer a trailing flat list of
  # validations under the stage list. Task-level `e2e_behavior` validations
  # live on a synthetic "Task-level review" stage (see
  # PlanEngine.route_e2e_behavior_validations/1) and render in a dedicated
  # section below the stages list so they read as a task-wide gate.
  attr(:plan, :any, required: true)

  defp plan_body(assigns) do
    {stages, e2e_validations} = split_e2e_behavior_validations(assigns.plan.stages || [])

    assigns =
      assigns
      |> Map.put(:stages, stages)
      |> Map.put(:e2e_validations, e2e_validations)

    ~H"""
    <div data-role="plan-body-inner" class="space-y-3">
      <div
        :for={stage <- @stages}
        data-role="stage-card"
        data-stage-id={stage.id}
        class="space-y-1"
      >
        <div class="flex items-center gap-2 text-sm">
          <span class={"size-4 #{stage_status_icon(stage.status)}"}></span>
          <span class="flex-1">{stage.name}</span>
          <span class="text-xs text-base-content/40">{stage.status}</span>
        </div>
        <div
          :if={stage.description}
          class="prose prose-sm max-w-none text-xs text-base-content/60 chat-markdown task-markdown mt-1 ml-6"
        >
          {Platform.Chat.ContentRenderer.render_message(stage.description)}
        </div>
        <%!-- Per-stage validation badges (inline, inside the stage card) --%>
        <div
          :if={is_list(stage.validations) and stage.validations != []}
          data-role="stage-validations"
          class="ml-6 flex flex-wrap gap-1.5"
        >
          <span
            :for={v <- stage.validations}
            data-role="stage-validation-badge"
            data-validation-kind={v.kind}
            data-validation-id={v.id}
            class={"badge badge-sm gap-1 #{validation_badge_class(v.status)}"}
            title={"#{v.kind} — #{v.status}"}
          >
            <span class={"size-3 #{stage_status_icon(v.status)}"}></span>
            <span>{v.kind}</span>
            <a
              :if={validation_evidence_link(v)}
              href={validation_evidence_link(v)}
              target="_blank"
              class="link link-hover ml-1 text-[10px] uppercase tracking-wide"
            >
              evidence
            </a>
          </span>
        </div>
      </div>

      <%!-- E2E Behavior — task-level behavioral review gate (one or more per task —
          the planner-authored adversarial test plan, user-approved at plan time). --%>
      <div
        :if={@e2e_validations != []}
        data-role="e2e-behavior-section"
        class="mt-3 rounded-box border border-base-300 bg-base-200/30 p-3 space-y-2"
      >
        <div class="flex items-center gap-2">
          <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
            E2E Behavior
          </span>
          <span class="text-[10px] text-base-content/40">
            task-level review · {length(@e2e_validations)} test cases
          </span>
        </div>

        <div
          :for={v <- @e2e_validations}
          data-role="e2e-behavior-validation"
          data-validation-id={v.id}
          class="space-y-2 rounded border border-base-300 bg-base-100/40 p-2 text-xs"
        >
          <div class="flex items-center gap-2">
            <span class={"size-3 #{stage_status_icon(v.status)}"}></span>
            <span class={"badge badge-xs #{validation_badge_class(v.status)}"}>{v.status}</span>
            <span :if={v.evaluated_by} class="text-base-content/50">
              by {v.evaluated_by}
            </span>
            <a
              :if={validation_evidence_link(v)}
              href={validation_evidence_link(v)}
              target="_blank"
              class="link link-hover ml-auto text-[10px] uppercase tracking-wide"
            >
              evidence
            </a>
          </div>

          <%= for {label, key} <- [
                {"Setup", "setup"},
                {"Actions", "actions"},
                {"Expected", "expected"}
              ] do %>
            <% value = e2e_payload_field(v, key) %>
            <div :if={value} data-role={"e2e-#{key}"} class="space-y-0.5">
              <div class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
                {label}
              </div>
              <pre class="whitespace-pre-wrap break-words rounded bg-base-100 p-2 text-[11px] leading-snug text-base-content/80">{value}</pre>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  # ── plan_body helpers ────────────────────────────────────────────────────

  # Pull e2e_behavior validations out of the per-stage flow and surface them
  # as a dedicated task-level section. The plan engine routes them to a
  # synthetic "Task-level review" stage (see
  # PlanEngine.route_e2e_behavior_validations/1); if that stage carries ONLY
  # e2e_behavior validations and has no description authored by a planner,
  # we hide the now-empty stage card to avoid duplicate rendering.
  defp split_e2e_behavior_validations(stages) when is_list(stages) do
    {hidden_stages, kept_stages, e2es} =
      Enum.reduce(stages, {[], [], []}, fn stage, {hidden, kept, e2e_acc} ->
        validations = if is_list(stage.validations), do: stage.validations, else: []

        {e2e_here, rest} =
          Enum.split_with(validations, fn v -> v.kind == "e2e_behavior" end)

        new_e2e_acc = e2e_acc ++ e2e_here

        cond do
          # Stage entirely dedicated to e2e_behavior — drop it from the stage
          # list; the dedicated section will render the validations.
          e2e_here != [] and rest == [] ->
            {[stage | hidden], kept, new_e2e_acc}

          # Stage carries e2e_behavior alongside other validations — keep
          # the stage but strip the e2e validations off it.
          true ->
            updated_stage = %{stage | validations: rest}
            {hidden, [updated_stage | kept], new_e2e_acc}
        end
      end)

    _ = hidden_stages
    {Enum.reverse(kept_stages), e2es}
  end

  defp split_e2e_behavior_validations(_), do: {[], []}

  # Color/style mapping for validation badges. Reuses DaisyUI badge utility
  # classes so no new CSS is needed.
  defp validation_badge_class("passed"), do: "badge-success"
  defp validation_badge_class("failed"), do: "badge-error"
  defp validation_badge_class("running"), do: "badge-info"
  defp validation_badge_class(_), do: "badge-ghost"

  # Evidence on a Validation is a free-form map. Surface a link only when the
  # planner / evaluator wrote a `url`, `evidence_url`, `link`, or `canvas_id`
  # entry — otherwise the badge stays plain.
  defp validation_evidence_link(%{evidence: evidence}) when is_map(evidence) do
    Map.get(evidence, "url") || Map.get(evidence, :url) ||
      Map.get(evidence, "evidence_url") || Map.get(evidence, :evidence_url) ||
      Map.get(evidence, "link") || Map.get(evidence, :link)
  end

  defp validation_evidence_link(_), do: nil

  # Pull a single string field from an e2e_behavior evaluation_payload,
  # tolerant of string or atom keys.
  defp e2e_payload_field(%{evaluation_payload: payload}, key) when is_map(payload) do
    case Map.get(payload, key) || Map.get(payload, safe_atom(key)) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp e2e_payload_field(_, _), do: nil

  defp safe_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp safe_atom(_), do: nil
end
