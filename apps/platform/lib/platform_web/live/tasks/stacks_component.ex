defmodule PlatformWeb.Tasks.StacksComponent do
  @moduledoc """
  The Stacks concern of the Tasks surface, extracted from
  `PlatformWeb.TasksLive` by task 01a008f6 stage 3.

  Owns the stack detail slide-in panel, the stack-level review rollup
  overlay, the dep-graph fullscreen modal and the stack-level assignee
  modal — four render regions that were scattered across
  `tasks_live.html.heex` and one events block that was scattered across
  `tasks_live.ex`.

  ## Ownership

  Per the table fixed in stage 2 and binding here:

    * `agents`, `stacks` and `board_review_subscriptions` arrive as
      **read-only attrs** from the shell. The component never writes them.
    * Task **selection** is requested, never written: the member rows keep
      an untargeted `phx-click="select_task"` so the event lands on the
      shell, which owns `selected_task`.
    * The board still renders the collapsed stack cards, so
      `expanded_stacks` is mirrored back to the shell with
      `send(self(), {:stacks_expanded, set})` rather than written into a
      shell assign directly.
    * Board refreshes are **requested** with
      `send(self(), {:stacks_board_refresh})` — the component never calls
      `refresh_board/1`.

  ## Events

  All 18 events carry the `stack_` prefix, renamed at extraction time with
  their templates and tests in the same commit. There are no back-compat
  aliases. `stack_clear_member_override` (formerly `clear_member_override`)
  lives HERE and not in the Assignees concern: it is only reachable from
  stack detail and it reads `selected_stack_members`.

  The pure graph math this component renders lives in
  `Platform.Tasks.StackGraph`; the SVG/Tailwind tokens live in
  `PlatformWeb.Tasks.StackStyles`.
  """
  use PlatformWeb, :live_component

  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.{ReviewRequests, Stack, Stacks}

  import Platform.Tasks.StackGraph,
    only: [
      stack_dag_layout: 1,
      dep_edge_summary: 1,
      member_dep_annotation: 2,
      stack_position_glyph: 1
    ]

  import PlatformWeb.Tasks.StackStyles,
    only: [
      dag_node_style: 1,
      dag_node_label: 1,
      dep_edges_class: 1,
      member_node_class: 1,
      member_status_pill: 1,
      stack_member_action_label: 1,
      stack_status_text_class: 1
    ]

  import PlatformWeb.Tasks.StatusLabels,
    only: [status_label: 1, phase_label: 1, member_word: 1, request_word: 1]

  import PlatformWeb.Tasks.PhaseAssigneeParams,
    only: [phase_entry: 1, all_phases_same_agent?: 1]

  import PlatformWeb.Tasks.ReviewLoaders,
    only: [load_review_canvases: 1, pending_review_counts: 1]

  @doc false
  def mount(socket) do
    {:ok,
     socket
     |> assign(:selected_stack, nil)
     |> assign(:selected_stack_members, [])
     |> assign(:selected_stack_member_review_counts, %{})
     |> assign(:selected_stack_pending_review_count, 0)
     |> assign(:selected_stack_open_review_requests, [])
     |> assign(:selected_stack_open_review_canvases, %{})
     |> assign(:show_stack_detail, false)
     |> assign(:show_stack_feedback_overlay, false)
     |> assign(:show_stack_assignee_modal, false)
     |> assign(:stack_assignee_modal_mode, :simple)
     |> assign(:stack_feedback_reject_open, MapSet.new())
     |> assign(:stack_feedback_reject_text, %{})
     |> assign(:stack_feedback_reject_error, %{})
     |> assign(:stack_graph_expanded, false)
     |> assign(:stack_review_request_subscriptions, MapSet.new())}
  end

  @doc false
  def update(%{action: :reload}, socket) do
    {:ok, reload_selected_stack(socket)}
  end

  # The shell closes the stack panel when the per-task detail panel takes
  # over the same slide-in slot.
  def update(%{action: :close}, socket) do
    {:ok, close_stack_panel(socket)}
  end

  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @doc false
  def render(assigns) do
    ~H"""
    <div id={@id}>
      <%!-- Stack detail panel (T8 stage 1 — slide-in from right).
         Mirrors the per-task detail container shape so the two panels
         feel visually identical. Stage 1 ships head + action row;
         stages 2-5 fill in meta-grid, dep DAG, members list, and
         mobile takeover. Purple accent (#7b5cff) matches mock canvas
         019e1a16 rev 2 (.stk-tag style). --%>
      <%!-- T8 stage 5 (revised stage 1 of task 019e38c7): mobile takeover
         + sticky action bar. Container shape mirrors the per-task detail
         panel at line ~865 EXACTLY — explicit `top-0 right-0
         bottom-[calc(...)]` with no `inset-0` shorthand. The old shape
         used `inset-0 ... bottom-[calc(...)]`: Tailwind's same-specificity
         ordering left `inset-0`'s `bottom:0` competing with the calc
         override on mobile, which broke iOS WebKit's overflow
         calculations and left the body unscrollable below the fold.
         Mobile widens to full screen via `left-0 max-w-full`; md+ narrows
         to a right-edge slide-in via `md:left-auto md:max-w-lg`. Bottom
         edge stops at the top of the bottom-nav (including iOS home-
         indicator safe-area) via `bottom-[calc(env(safe-area-inset-
         bottom)+var(--bottom-nav-height,0px))]` on the panel container.
         No defense-in-depth `pb-` on the inner scroller — PR #335
         stripped that pattern as dead space. --%>
      <div
        :if={@show_stack_detail && @selected_stack}
        id="stack-detail-panel"
        data-role="stack-detail-panel"
        data-stack-id={@selected_stack.id}
        class="fixed top-0 left-0 md:left-auto right-0 bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))] z-30 flex w-full max-w-full md:max-w-lg flex-col border-l border-base-300 bg-base-100 shadow-xl safe-area-top"
      >
        <%!-- Head/app bar. On mobile the chrome is a back arrow + Stack
           tag + overflow kebab (matching the mock's `.detail-appbar`).
           On desktop the head retains the stage 1 shape: title + close X
           button on the right. The back arrow + kebab carry `md:hidden`;
           the desktop close X carries `hidden md:flex`. The Stack tag
           and title/description block render on both viewports. --%>
        <%!-- Single scroll region for the whole panel body: head + meta grid +
           DAG/members. Previously only the DAG/members region scrolled and
           the head/meta sat outside it as unshrinkable flex items — a stack
           with a long description made the head taller than the panel, which
           squeezed the scroller to ~0px and pushed it past the panel's bottom
           edge, so the graph and member list were unreachable at every
           breakpoint. Scrolling at this level makes the surface hold for
           arbitrarily long descriptions AND arbitrarily many members. The
           action bar stays outside as a pinned `shrink-0` footer. --%>
        <div class="flex min-h-0 flex-1 flex-col overflow-y-auto" data-role="stack-detail-scroll">
          <div class="shrink-0 flex items-start justify-between gap-3 border-b border-base-300 px-4 py-3">
            <%!-- Mobile back arrow: same handler as the desktop close X. --%>
            <button
              type="button"
              class="btn btn-sm btn-ghost btn-square shrink-0 md:hidden"
              phx-click="stack_close_detail"
              phx-target={@myself}
              aria-label="Back"
              data-role="stack-detail-back"
            >
              <span class="hero-arrow-left size-4"></span>
            </button>
            <div class="flex min-w-0 flex-1 flex-col gap-1.5">
              <div class="flex min-w-0 items-center gap-2">
                <span
                  class="hero-rectangle-stack size-4 shrink-0 text-violet-300"
                  aria-hidden="true"
                >
                </span>
                <span
                  class="text-[9px] font-semibold uppercase tracking-wider shrink-0"
                  style="color:#7b5cff"
                  data-role="stack-tag"
                >
                  Stack
                </span>
              </div>
              <h2
                id={"stack-detail-title-#{@selected_stack.id}"}
                class="text-lg font-semibold leading-tight truncate"
                data-role="stack-detail-title"
              >
                {@selected_stack.name}
              </h2>
              <p
                :if={@selected_stack.description && @selected_stack.description != ""}
                class="text-xs text-base-content/60 leading-snug"
                data-role="stack-detail-description"
              >
                {@selected_stack.description}
              </p>
            </div>
            <%!-- Stage 2 of task 019e2c27 (Stack-Level Review Rollup): chrome
             pill that surfaces the count of open review_requests across
             every member of this stack. Hidden entirely when the count
             is 0 — the chrome stays clutter-free unless there's actual
             feedback waiting. Sits between the title block and the
             overflow kebab / close X so it's visible on both mobile
             (left of the kebab) and desktop (left of the close X).
             Click toggles `show_stack_feedback_overlay` via the stage-2
             handler stub; stage 3 will render the actual rollup overlay. --%>
            <button
              :if={@selected_stack_pending_review_count > 0}
              type="button"
              class="badge badge-warning badge-sm gap-1 shrink-0 self-center cursor-pointer"
              phx-click="stack_open_feedback_overlay"
              phx-target={@myself}
              aria-label={"Needs feedback (#{@selected_stack_pending_review_count})"}
              data-role="stack-detail-needs-feedback-pill"
              data-pending-count={@selected_stack_pending_review_count}
            >
              <span class="hero-eye size-3" aria-hidden="true"></span>
              <span>Needs feedback ({@selected_stack_pending_review_count})</span>
            </button>
            <%!-- Mobile overflow kebab. No-op trigger for now (visual parity
             with the mock); when stack-level overflow actions land they
             wire here. --%>
            <button
              type="button"
              class="btn btn-sm btn-ghost btn-square shrink-0 md:hidden"
              aria-label="Stack actions"
              data-role="stack-detail-overflow"
            >
              <span class="hero-ellipsis-vertical size-4"></span>
            </button>
            <%!-- Desktop close X. Hidden on mobile (the back arrow replaces
             it on the left); visible on md+ where the slide-in shape
             keeps the close affordance on the right. --%>
            <button
              type="button"
              class="hidden md:flex btn btn-sm btn-ghost btn-square shrink-0"
              phx-click="stack_close_detail"
              phx-target={@myself}
              aria-label="Close stack details"
              data-role="stack-detail-close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Meta-grid (T8 stage 2): 4-cell summary under the head.
           Desktop = 4 columns horizontal; mobile baseline 2x2 lands in
           stage 5. Cells: status (color-coded), members (count · ready),
           dep-edges (count · valid DAG / cycle detected), branch (mono).
           Computed via `stack_meta/2` to keep the template clean. --%>
          <% meta = stack_meta(@selected_stack, @selected_stack_members) %>
          <div
            class="shrink-0 grid grid-cols-2 md:grid-cols-4 gap-2 border-b border-base-300 px-4 py-3"
            data-role="stack-detail-meta"
          >
            <div class="meta-cell rounded-md bg-base-300 p-2" data-role="meta-cell-status">
              <div class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Status
              </div>
              <div
                class={"mt-1 text-sm font-medium #{meta.status.class}"}
                data-role="meta-cell-status-value"
              >
                {meta.status.label}
              </div>
            </div>
            <div class="meta-cell rounded-md bg-base-300 p-2" data-role="meta-cell-members">
              <div class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Members
              </div>
              <div class="mt-1 text-sm font-medium" data-role="meta-cell-members-value">
                {meta.members.text}
              </div>
            </div>
            <div class="meta-cell rounded-md bg-base-300 p-2" data-role="meta-cell-dep-edges">
              <div class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Dep edges
              </div>
              <div
                class={"mt-1 text-sm font-medium #{dep_edges_class(meta.dep_edges)}"}
                data-role="meta-cell-dep-edges-value"
              >
                {meta.dep_edges.text}
              </div>
            </div>
            <div class="meta-cell rounded-md bg-base-300 p-2" data-role="meta-cell-branch">
              <div class="text-xs font-semibold uppercase tracking-wider text-base-content/50">
                Branch
              </div>
              <div
                class="mt-1 truncate font-mono text-xs text-base-content"
                data-role="meta-cell-branch-value"
                title={meta.branch}
              >
                {meta.branch}
              </div>
            </div>
          </div>

          <%!-- Body: stage 3 ships the dep DAG SVG in the left column; stage 4
           adds the members list in the right column (mobile collapses to a
           single column in stage 5). The body is a 2-column grid so the
           DAG and members list share width 1:1 on desktop. --%>
          <% dag = stack_dag_layout(@selected_stack_members)
          {dag_w, dag_h} = dag.viewbox %>
          <div
            class="shrink-0 p-4 grid grid-cols-1 md:grid-cols-2 gap-4 items-start"
            data-role="stack-detail-body"
          >
            <%!-- Left column: dep DAG. `.dag` matches the mock chrome
             (rounded base-300 backdrop, modest padding). The SVG fills the
             container (`w-full h-full`); `preserveAspectRatio` keeps the
             graph legible as the aspect changes. Stage 3 will add the
             expand-to-modal affordance atop this container. --%>
            <div
              id="stack-detail-dag-container"
              class="dag relative h-56 md:h-64 rounded bg-base-300 p-2"
              data-role="stack-detail-dag"
            >
              <svg
                viewBox={"0 0 #{dag_w} #{dag_h}"}
                preserveAspectRatio="xMidYMid meet"
                xmlns="http://www.w3.org/2000/svg"
                class="w-full h-full block"
                data-role="stack-detail-dag-svg"
              >
                <%!-- Edges render as dashed lines with no arrowhead per Rowan's
                 T8 stage-5 review: direction is implicit from the
                 topological-row layout (sources are above targets), so
                 the marker-end arrowhead is intentionally omitted. --%>
                <%= for edge <- dag.edges do %>
                  <line
                    x1={edge.x1}
                    y1={edge.y1}
                    x2={edge.x2}
                    y2={edge.y2}
                    stroke="#7b5cff"
                    stroke-width="1.4"
                    stroke-dasharray="6,4"
                    data-role="stack-detail-dag-edge"
                    data-from-id={edge.from_id}
                    data-to-id={edge.to_id}
                  />
                <% end %>
                <%= for node <- dag.nodes do %>
                  <% style = dag_node_style(node.status) %>
                  <g data-role="stack-detail-dag-node" data-node-id={node.id}>
                    <rect
                      x={node.x}
                      y={node.y}
                      width={node.w}
                      height={node.h}
                      rx="6"
                      fill={style.fill}
                      stroke={style.stroke}
                      stroke-width="1.2"
                      stroke-dasharray={style.dasharray}
                      data-status={node.status}
                    />
                    <text
                      x={node.x + 12}
                      y={node.y + 18}
                      font-size="11"
                      font-weight="700"
                      fill={style.num_color}
                    >
                      {node.num}
                    </text>
                    <text x={node.x + 26} y={node.y + 18} font-size="9" fill={style.text}>
                      {dag_node_label(node.label)}
                    </text>
                    <text
                      x={node.x + 26}
                      y={node.y + 34}
                      font-size="7"
                      letter-spacing="0.5"
                      fill={style.caption_color}
                    >
                      {style.caption}
                    </text>
                  </g>
                <% end %>
              </svg>
              <%!-- Expand-to-modal affordance (stage 3 of task 019f487e). Ghost
               icon-button positioned top-right of the dep-graph container;
               semantic-token colors only (no hard-coded hex). On click,
               sets `:stack_graph_expanded` true so the fullscreen modal
               renders (see the modal block below the review-canvas modal).
               --%>
              <button
                type="button"
                aria-label="Expand dep graph"
                data-role="stack-detail-dag-expand"
                phx-click="stack_open_graph_expand"
                phx-target={@myself}
                class="btn btn-ghost btn-sm btn-square absolute top-1 right-1 text-base-content/60 hover:bg-base-content/10 max-sm:h-11 max-sm:w-11 max-sm:min-h-[44px] max-sm:min-w-[44px]"
              >
                <span class="hero-arrows-pointing-out size-4" aria-hidden="true"></span>
              </button>
            </div>
            <%!-- Right column: linear members list (T8 stage 4). One row per
             in-stack member ordered by `stack_position`. Each row carries
             a circular position badge (status-coloured), the truncated
             title, a status pill on the right, and an optional dep
             annotation line below ("depends on ① + ②" /
             "depends on ① (parallel with ②)") suppressed when the member
             has no in-stack predecessors. Rows are clickable: clicking
             one push_patches to /tasks/:id and closes this stack panel
             (close-and-open behavior — the per-task detail slides in to
             replace the stack panel). --%>
            <%!-- Members column. The panel-level scroll region
             (`stack-detail-scroll`) handles vertical overflow for the entire
             panel; the column itself must NOT carry its own scroller or iOS
             WebKit's momentum scroll fights itself on mobile (the
             single-column grid stacks DAG above members and the user
             can't reach the bottom rows). See task 019e38c7 stage 1. --%>
            <div
              class="flex flex-col gap-2"
              data-role="stack-detail-members"
            >
              <div
                class="flex items-center gap-2"
                data-role="stack-detail-members-header"
              >
                <span class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                  Members
                </span>
                <span class="text-[10px] text-base-content/50">(dispatch order)</span>
              </div>
              <div class="mlist flex flex-col gap-1.5" data-role="stack-detail-members-list">
                <%= for member <- @selected_stack_members do %>
                  <% {pill_label, pill_class} = member_status_pill(member.status)
                  annotation = member_dep_annotation(member, @selected_stack_members)
                  assignment = member_assignment_badge(member)
                  review_count = Map.get(@selected_stack_member_review_counts, member.id, 0)
                  action_reason = Tasks.needs_human_action_reason(member, review_count)
                  {action_label, action_reason_attr} = stack_member_action_label(action_reason) %>
                  <div
                    class="mlist-item rounded-md bg-base-300 border border-base-300 p-2 cursor-pointer hover:bg-base-200 transition-colors"
                    phx-click="select_task"
                    phx-value-id={member.id}
                    data-role="stack-detail-member-row"
                    data-member-id={member.id}
                    data-member-status={member.status}
                  >
                    <div class="flex items-center gap-2">
                      <span
                        class={"inline-flex size-5 items-center justify-center rounded-full text-[11px] font-semibold shrink-0 #{member_node_class(member.status)}"}
                        data-role="stack-detail-member-num"
                      >
                        {stack_position_glyph(member.stack_position)}
                      </span>
                      <span
                        class="flex-1 truncate text-sm text-base-content"
                        data-role="stack-detail-member-title"
                      >
                        {member.title}
                      </span>
                      <%!-- Assignment badge (ADR 0041): `inherited` = follows the
                       stack-level default; `override` = carries an individual
                       assignee, protected from stack-level fan-out. Overridden
                       rows expose an inline "clear" action that returns the
                       member to inheriting. --%>
                      <%= if assignment == "override" do %>
                        <button
                          type="button"
                          class="shrink-0 inline-flex items-center gap-0.5 rounded bg-warning/20 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-warning hover:bg-warning/30"
                          phx-click="stack_clear_member_override"
                          phx-target={@myself}
                          phx-value-id={member.id}
                          data-confirm="Clear this member's individual override and return it to inheriting the stack default?"
                          data-role="stack-detail-member-assignment"
                          data-assignment="override"
                          title="Clear override — return to inheriting the stack default"
                        >
                          override <span class="hero-x-mark size-3"></span>
                        </button>
                      <% else %>
                        <span
                          class="shrink-0 rounded bg-base-content/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider text-base-content/60"
                          data-role="stack-detail-member-assignment"
                          data-assignment="inherited"
                        >
                          inherited
                        </span>
                      <% end %>
                      <%!-- Badges-for-tasks-that-need-feedback (task 019e2c25
                       stage 2): per-row "Needs review" / "Plan ready"
                       warning chip rendered when Tasks.needs_human_action?
                       evaluates true for this member. The data-action-reason
                       attribute carries the precise predicate branch
                       (`plan_pending_review`, `review_request_pending`,
                       `validation_failed`) so the badge is targetable from
                       tests + dataview drilldowns. --%>
                      <span
                        :if={action_label}
                        class="shrink-0 badge badge-warning badge-xs gap-1"
                        data-role="stack-detail-member-action"
                        data-action-reason={action_reason_attr}
                      >
                        <span class="hero-eye size-3"></span>
                        {action_label}
                      </span>
                      <span
                        class={"shrink-0 rounded px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wider #{pill_class}"}
                        data-role="stack-detail-member-pill"
                      >
                        {pill_label}
                      </span>
                    </div>
                    <div
                      :if={annotation}
                      class="pl-7 text-[10px] text-base-content/50"
                      data-role="stack-detail-member-deps"
                    >
                      {annotation}
                    </div>
                  </div>
                <% end %>
              </div>
            </div>
          </div>
        </div>

        <%!-- Action row: Abandon (ghost) + View rollup PR (primary).
           The PR anchor is disabled when no rollup PR has been opened
           yet (metadata.rollup_pr.url is nil). --%>
        <% rollup_pr_url =
          case @selected_stack.metadata do
            %{"rollup_pr" => %{"url" => url}} when is_binary(url) and url != "" -> url
            _ -> nil
          end %>
        <%!-- Pinned bottom action bar (T8 stage 5). It is the last, non-
           shrinking child of the panel's flex column, so it stays at the
           panel's bottom edge on mobile (where the panel is full-screen and
           the region above it scrolls) and on desktop alike. The panel
           container's
           `bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-
           height,0px))]` constraint (PR #335 pattern) keeps the bar
           from being occluded by the bottom-tab nav on iOS — no
           defense-in-depth pb on this bar is required. --%>
        <% has_backlog_member? =
          Enum.any?(@selected_stack_members, &(&1.status == "backlog")) %>
        <div
          class="shrink-0 flex gap-2 border-t border-base-300 bg-base-100 px-4 py-3"
          data-role="stack-detail-actions"
        >
          <%!-- Start Planning (T8 stage 3): stack-level mirror of the per-task
             "Start Planning" button. Cascades every `backlog` member to
             `planning` via Stacks.start_planning/1. Rendered only when the
             stack has at least one `backlog` member — a stack with nothing
             to plan does not show the control. --%>
          <button
            :if={has_backlog_member?}
            type="button"
            class="btn btn-ghost btn-sm flex-1"
            phx-click="stack_start_planning"
            phx-target={@myself}
            data-role="stack-detail-start-planning"
          >
            <span class="hero-play size-4"></span> Start Planning
          </button>
          <%!-- Assign Agents (ADR 0041): opens the stack-level assignee modal.
             The stack-level assignment fans out to every member that is not
             individually overridden. --%>
          <button
            type="button"
            class="btn btn-ghost btn-sm flex-1"
            phx-click="stack_open_assignee_modal"
            phx-target={@myself}
            data-role="stack-detail-assign-agents"
          >
            <span class="hero-user-group size-4"></span> Assign Agents
          </button>
          <button
            type="button"
            class="btn btn-ghost btn-sm flex-1"
            phx-click="stack_abandon"
            phx-target={@myself}
            data-confirm="Abandon this stack? This cannot be undone."
            data-role="stack-detail-abandon"
          >
            Abandon
          </button>
          <%= if rollup_pr_url do %>
            <a
              href={rollup_pr_url}
              target="_blank"
              rel="noopener"
              class="btn btn-primary btn-sm flex-1"
              data-role="stack-detail-rollup-pr"
            >
              View rollup PR
            </a>
          <% else %>
            <button
              type="button"
              class="btn btn-primary btn-sm flex-1 btn-disabled"
              disabled
              aria-disabled="true"
              data-role="stack-detail-rollup-pr"
            >
              View rollup PR
            </button>
          <% end %>
        </div>
      </div>
      <%!-- Stage 3 of task 019e2c27 (Stack-Level Review Rollup): the rollup
         overlay. Modal/takeover surface that floats OVER the stack pane
         (NOT inline in it — the inline layout was the design Rowan rejected
         from v1). Lists every open ReviewRequest across the stack's
         members; each row renders the member task title + the canvas
         content inline via the same CanvasRenderer.canvas_document
         component the per-task `active_review_canvas` modal uses (gold-
         standard pattern at line ~2410 below).

         Layout:
           * z-40 sits ABOVE the stack panel (z-30) so it visually replaces
             the pane while keeping the panel mounted underneath — closing
             the overlay returns the user directly to the stack pane.
           * z-50 is reserved for the per-canvas `active_review_canvas`
             modal, which a future stage may open from a drill-down here.
           * Mobile (default): full-screen takeover (`inset-0`). The chrome
             pill is the trigger so the user never lands on this surface
             without a count to read; the takeover style matches the v2
             plan's "full-screen takeover on 375x812".
           * Desktop (md+): the panel is `max-w-lg` on the right edge; the
             overlay mirrors that and pins to the same column so it
             visually replaces the pane (NOT a small modal floating in the
             board's empty space). Backdrop fills the rest of the viewport
             with a black wash so it's clear the board is non-interactive.
           * Bottom edge mirrors the stack-detail panel's safe-area
             constraint so the takeover does not bleed under the bottom
             nav on iOS PWA.
           * Backdrop click dismisses (`close_stack_feedback_overlay`); the
             top-right X is a redundant explicit close.

         Stage-4 work (this stage): the approve/reject buttons on each
         item are wired against `ReviewRequests.approve_item/2` +
         `ReviewRequests.reject_item/3`. Approve is one-click; reject
         expands an inline textarea (mirrors the per-task
         `submit_review_feedback` UX) so the reviewer can give a reason. --%>
      <div
        :if={@show_stack_feedback_overlay && @selected_stack}
        id="stack-feedback-overlay"
        data-role="stack-feedback-overlay"
        data-stack-id={@selected_stack.id}
        class="fixed inset-0 z-40"
      >
        <%!-- Backdrop fills the viewport. On desktop the overlay panel is
           pinned to the right column (md:max-w-lg) so the backdrop
           visually wraps the rest of the board; click anywhere on the
           backdrop to dismiss. --%>
        <div
          class="absolute inset-0 bg-black/50"
          phx-click="stack_close_feedback_overlay"
          phx-target={@myself}
          data-role="stack-feedback-overlay-backdrop"
        />
        <%!-- Overlay panel — full-screen takeover on mobile, pinned to the
           right edge on desktop matching the stack pane's column. --%>
        <div
          class="absolute inset-0 md:inset-y-0 md:left-auto md:right-0 bottom-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))] flex w-full max-w-full md:max-w-lg flex-col border-l border-base-300 bg-base-100 shadow-2xl safe-area-top"
          data-role="stack-feedback-overlay-panel"
        >
          <%!-- Overlay header: title + count + close X. Mirrors the stack-
             detail panel chrome shape for visual continuity, but uses the
             "Needs feedback" label so the user understands this is the
             drill-down from the chrome pill. --%>
          <div class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div class="flex min-w-0 items-center gap-2">
              <span class="hero-eye size-4 shrink-0 text-warning" aria-hidden="true"></span>
              <div class="min-w-0">
                <div class="text-sm font-semibold leading-tight truncate">
                  Needs feedback
                </div>
                <div
                  class="text-xs text-base-content/60"
                  data-role="stack-feedback-overlay-count"
                >
                  {@selected_stack_pending_review_count} pending {request_word(
                    @selected_stack_pending_review_count
                  )} across this stack
                </div>
              </div>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square shrink-0"
              phx-click="stack_close_feedback_overlay"
              phx-target={@myself}
              aria-label="Close feedback overlay"
              data-role="stack-feedback-overlay-close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Scrollable body. Empty state is defensive: the chrome pill is
             hidden when the count is 0, so the overlay should never open
             with an empty list. If it does (e.g. PubSub flushed every RR
             between click and render), surface a neutral copy instead of a
             blank pane. --%>
          <div class="flex-1 overflow-y-auto px-4 py-3">
            <%= if @selected_stack_open_review_requests == [] do %>
              <div
                class="rounded-lg border border-dashed border-base-300 bg-base-200/50 p-6 text-center text-sm text-base-content/60"
                data-role="stack-feedback-overlay-empty"
              >
                No pending feedback on this stack.
              </div>
            <% else %>
              <ul class="flex flex-col gap-4" data-role="stack-feedback-overlay-list">
                <li
                  :for={rr <- @selected_stack_open_review_requests}
                  class="rounded-xl border border-base-300 bg-base-100"
                  data-role="stack-feedback-overlay-item"
                  data-review-request-id={rr.id}
                  data-task-id={rr.task_id}
                >
                  <%!-- Row header: member task title + drill-in link. --%>
                  <div class="flex items-start justify-between gap-2 border-b border-base-300 px-3 py-2">
                    <div class="min-w-0">
                      <div class="text-[10px] font-semibold uppercase tracking-wider text-base-content/50">
                        Member task
                      </div>
                      <%= if rr.member_task do %>
                        <.link
                          patch={~p"/tasks/#{rr.member_task.id}"}
                          class="block truncate text-sm font-medium text-base-content hover:underline"
                          data-role="stack-feedback-overlay-task-link"
                        >
                          {rr.member_task.title}
                        </.link>
                      <% else %>
                        <span class="block truncate text-sm font-medium text-base-content/60">
                          (member task missing)
                        </span>
                      <% end %>
                    </div>
                  </div>

                  <%!-- Items: each one carries the canvas (or text content)
                     plus the (stage-4) approve/reject buttons. --%>
                  <ul class="flex flex-col gap-3 p-3">
                    <li
                      :for={item <- rr.items || []}
                      class="rounded-lg border border-base-300 bg-base-200/40 p-3"
                      data-role="stack-feedback-overlay-review-item"
                      data-review-item-id={item.id}
                    >
                      <div class="mb-2 flex items-center justify-between gap-2">
                        <div class="min-w-0 truncate text-xs font-semibold text-base-content/80">
                          {item.label}
                        </div>
                        <div class="flex shrink-0 gap-1">
                          <%!-- Stage 4 wiring: Approve fires a single
                             `stack_feedback_approve_item` event with the
                             item id. Reject toggles an inline textarea
                             (mirrors the per-task `submit_review_feedback`
                             UX) so a feedback string is collected before
                             `ReviewRequests.reject_item/3` is called. --%>
                          <button
                            type="button"
                            class="btn btn-success btn-xs"
                            phx-click="stack_feedback_approve_item"
                            phx-target={@myself}
                            phx-value-id={item.id}
                            data-role="stack-feedback-overlay-approve"
                            data-review-item-id={item.id}
                            title="Approve this item"
                          >
                            <span class="hero-check size-3"></span> Approve
                          </button>
                          <button
                            type="button"
                            class="btn btn-error btn-xs"
                            phx-click="stack_toggle_feedback_reject"
                            phx-target={@myself}
                            phx-value-id={item.id}
                            data-role="stack-feedback-overlay-reject"
                            data-review-item-id={item.id}
                            title="Reject this item with feedback"
                          >
                            <span class="hero-x-mark size-3"></span> Reject
                          </button>
                        </div>
                      </div>

                      <%!-- Reject feedback textarea + submit. Toggled by
                         `toggle_stack_feedback_reject` (the Reject button
                         above). Lives in overlay-scoped assigns
                         (`:stack_feedback_reject_open` /
                         `:stack_feedback_reject_text`) so opening this
                         drawer here does NOT also expand the per-task
                         review panel's separate reject UI underneath. --%>
                      <%!-- The reason is a real form field, NOT a
                         `phx-value-feedback` echo of keystroke events. The
                         echo only carried keystrokes whose round-trip had
                         already re-rendered, so it dropped the tail of what
                         the reviewer typed and dropped pasted text entirely.
                         See `GatePanelComponent`'s "Why a form" note. --%>
                      <form
                        :if={MapSet.member?(@stack_feedback_reject_open, item.id)}
                        class="mb-2 space-y-2"
                        data-role="stack-feedback-overlay-reject-form"
                        data-review-item-id={item.id}
                        phx-submit="stack_feedback_reject_item"
                        phx-change="stack_update_feedback_reject_text"
                        phx-target={@myself}
                      >
                        <input type="hidden" name="item-id" value={item.id} />
                        <textarea
                          name="feedback"
                          class="textarea textarea-bordered textarea-xs w-full"
                          aria-label="Rejection feedback"
                          placeholder="Describe what needs to change..."
                          phx-debounce="blur"
                          data-role="stack-feedback-overlay-reject-text"
                          data-review-item-id={item.id}
                        >{Map.get(@stack_feedback_reject_text, item.id, "")}</textarea>
                        <p
                          :if={Map.has_key?(@stack_feedback_reject_error, item.id)}
                          class="text-xs text-error"
                          role="alert"
                        >
                          {Map.fetch!(@stack_feedback_reject_error, item.id)}
                        </p>
                        <button
                          type="submit"
                          class="btn btn-warning btn-xs"
                          data-role="stack-feedback-overlay-reject-submit"
                          data-review-item-id={item.id}
                        >
                          Submit feedback
                        </button>
                      </form>
                      <%!-- Canvas content (inline) — same component the per-
                         task `active_review_canvas` modal uses. If the item
                         carries free-form `content` instead of a canvas
                         reference, render that as the fallback so the
                         reviewer sees something either way. --%>
                      <%= cond do %>
                        <% canvas = is_binary(item.canvas_id) && Map.get(@selected_stack_open_review_canvases, item.canvas_id) -> %>
                          <div
                            class="rounded-md border border-base-300 bg-base-100 p-2"
                            data-role="stack-feedback-overlay-canvas"
                            data-canvas-id={canvas.id}
                          >
                            <PlatformWeb.Chat.CanvasRenderer.canvas_document
                              canvas={canvas}
                              show_header={false}
                              dom_id_base={"stack-feedback-overlay-canvas-#{canvas.id}"}
                            />
                          </div>
                        <% is_binary(item.content) and item.content != "" -> %>
                          <pre
                            class="overflow-x-auto whitespace-pre-wrap rounded-md border border-base-300 bg-base-100 p-2 text-xs text-base-content/80"
                            data-role="stack-feedback-overlay-content"
                          >{item.content}</pre>
                        <% true -> %>
                          <div
                            class="rounded-md border border-dashed border-base-300 bg-base-100 p-2 text-xs text-base-content/50"
                            data-role="stack-feedback-overlay-empty-item"
                          >
                            No reviewable content attached.
                          </div>
                      <% end %>
                    </li>
                  </ul>
                </li>
              </ul>
            <% end %>
          </div>

          <%!-- Sticky bottom close button — mirrors the stack-detail panel
             action bar so the dismiss target is reachable on tall mobile
             viewports without scrolling all the way back up. --%>
          <div
            class="mt-auto sticky bottom-0 flex gap-2 border-t border-base-300 bg-base-100 px-4 py-3"
            data-role="stack-feedback-overlay-actions"
          >
            <button
              type="button"
              class="btn btn-ghost btn-sm flex-1"
              phx-click="stack_close_feedback_overlay"
              phx-target={@myself}
              data-role="stack-feedback-overlay-close-bottom"
            >
              Close
            </button>
          </div>
        </div>
      </div>
      <%!-- Stack dep-graph fullscreen modal. Mirrors the active_review_canvas
         modal chrome above; body re-renders the same stack_dag_layout SVG at
         a much larger container size so 6+ node stacks are legible. Escape
         key close pattern matches the reaction-picker at chat_live.html.heex
         :988. Mobile: card fills viewport via max-sm:* utility overrides so
         tiny iPhone-class canvases reclaim every pixel. --%>
      <div
        :if={@stack_graph_expanded && @selected_stack_members not in [nil, []]}
        id="stack-detail-dag-modal"
        data-role="stack-detail-dag-modal"
        class="fixed inset-0 z-50 flex items-center justify-center px-4 py-6 max-sm:p-0"
        phx-window-keydown="stack_close_graph_expand"
        phx-target={@myself}
        phx-key="Escape"
      >
        <div
          class="absolute inset-0 bg-black/50"
          phx-click="stack_close_graph_expand"
          phx-target={@myself}
          data-role="stack-detail-dag-modal-backdrop"
          aria-hidden="true"
        />
        <div class="relative z-10 flex max-h-[90vh] w-full max-w-6xl flex-col overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-2xl max-sm:h-screen max-sm:max-h-none max-sm:w-screen max-sm:rounded-none max-sm:border-0">
          <div class="flex items-center justify-between border-b border-base-300 px-4 py-3 pt-[max(0.75rem,env(safe-area-inset-top))]">
            <div class="min-w-0">
              <div class="truncate text-sm font-semibold">Stack dep graph</div>
              <div class="text-xs text-base-content/60">
                {length(@selected_stack_members)} members
              </div>
            </div>
            <button
              type="button"
              class="btn btn-ghost btn-sm btn-square"
              phx-click="stack_close_graph_expand"
              phx-target={@myself}
              aria-label="Close dep graph"
              data-role="stack-detail-dag-modal-close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>
          <div class="flex-1 overflow-auto p-4 pb-[max(1rem,env(safe-area-inset-bottom))] bg-base-300">
            <% dag_modal = stack_dag_layout(@selected_stack_members)
            {mw, mh} = dag_modal.viewbox %>
            <svg
              viewBox={"0 0 #{mw} #{mh}"}
              preserveAspectRatio="xMidYMid meet"
              xmlns="http://www.w3.org/2000/svg"
              class="w-full h-full min-h-[60vh] block"
              data-role="stack-detail-dag-modal-svg"
            >
              <%= for edge <- dag_modal.edges do %>
                <line
                  x1={edge.x1}
                  y1={edge.y1}
                  x2={edge.x2}
                  y2={edge.y2}
                  stroke="#7b5cff"
                  stroke-width="1.4"
                  stroke-dasharray="6,4"
                  data-role="stack-detail-dag-modal-edge"
                  data-from-id={edge.from_id}
                  data-to-id={edge.to_id}
                />
              <% end %>
              <%= for node <- dag_modal.nodes do %>
                <% style = dag_node_style(node.status) %>
                <g data-role="stack-detail-dag-modal-node" data-node-id={node.id}>
                  <rect
                    x={node.x}
                    y={node.y}
                    width={node.w}
                    height={node.h}
                    rx="6"
                    fill={style.fill}
                    stroke={style.stroke}
                    stroke-width="1.2"
                    stroke-dasharray={style.dasharray}
                    data-status={node.status}
                  />
                  <text
                    x={node.x + 12}
                    y={node.y + 18}
                    font-size="11"
                    font-weight="700"
                    fill={style.num_color}
                  >
                    {node.num}
                  </text>
                  <text x={node.x + 26} y={node.y + 18} font-size="9" fill={style.text}>
                    {dag_node_label(node.label)}
                  </text>
                  <text
                    x={node.x + 26}
                    y={node.y + 34}
                    font-size="7"
                    letter-spacing="0.5"
                    fill={style.caption_color}
                  >
                    {style.caption}
                  </text>
                </g>
              <% end %>
            </svg>
          </div>
        </div>
      </div>
      <%!-- Stack-level assignee modal (ADR 0041 — assign agents at the stack
         level). Mirrors the per-task assignee modal: simple/advanced
         segmented control, same sheet-on-mobile / dialog-on-desktop shape.
         The stack-level assignment is the default that fans out to every
         member that is not individually overridden. --%>
      <div
        :if={@show_stack_assignee_modal && @selected_stack}
        class="fixed inset-0 z-50 flex items-end sm:items-center justify-center"
        id="stack-assignee-modal"
      >
        <%!-- Backdrop --%>
        <div
          class="absolute inset-0 bg-black/40"
          phx-click="stack_close_assignee_modal"
          phx-target={@myself}
        />

        <%!-- Sheet / dialog --%>
        <div class="relative w-full max-w-lg rounded-t-2xl sm:rounded-2xl bg-base-100 shadow-2xl pb-[env(safe-area-inset-bottom)] max-h-[90vh] overflow-y-auto">
          <%!-- Header --%>
          <div class="flex items-center justify-between border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold">Assign Agents</h2>
              <p class="mt-0.5 text-xs text-base-content/60">
                {@selected_stack.name} · stack-level default
              </p>
            </div>
            <button
              type="button"
              phx-click="stack_close_assignee_modal"
              phx-target={@myself}
              class="btn btn-sm btn-ghost btn-square"
              aria-label="Close"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </div>

          <%!-- Mode toggle (segmented) --%>
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-300 gap-3">
            <p class="text-xs text-base-content/60 leading-snug">
              {if @stack_assignee_modal_mode == :advanced,
                do: "One agent per phase, applied to every member.",
                else: "One agent for the whole stack."}
            </p>
            <div class="join shrink-0">
              <button
                type="button"
                phx-click="stack_set_assignee_modal_mode"
                phx-target={@myself}
                phx-value-mode="simple"
                class={[
                  "btn btn-sm join-item",
                  @stack_assignee_modal_mode == :simple && "btn-primary",
                  @stack_assignee_modal_mode != :simple && "btn-ghost"
                ]}
                aria-pressed={if @stack_assignee_modal_mode == :simple, do: "true", else: "false"}
              >
                Simple
              </button>
              <button
                type="button"
                phx-click="stack_set_assignee_modal_mode"
                phx-target={@myself}
                phx-value-mode="advanced"
                class={[
                  "btn btn-sm join-item",
                  @stack_assignee_modal_mode == :advanced && "btn-primary",
                  @stack_assignee_modal_mode != :advanced && "btn-ghost"
                ]}
                aria-pressed={if @stack_assignee_modal_mode == :advanced, do: "true", else: "false"}
              >
                Advanced
              </button>
            </div>
          </div>

          <%!-- Form body --%>
          <form
            id="stack-assignees-form"
            phx-hook="ButtonLoading"
            phx-submit="stack_save_assignees"
            phx-target={@myself}
            class="flex flex-col gap-3 px-4 py-4"
          >
            <%!-- Simple mode --%>
            <div :if={@stack_assignee_modal_mode == :simple} class="flex flex-col gap-1">
              <label class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                Agent (all phases)
              </label>
              <select
                name="assignees[all]"
                class="select select-bordered select-sm w-full"
              >
                <option value="">Unassigned</option>
                <option
                  :for={agent <- @agents}
                  value={agent.id}
                  selected={stack_phase_assignee_id(@selected_stack, "execution") == agent.id}
                >
                  {agent.name}
                </option>
              </select>
            </div>

            <%!-- Advanced mode: per-phase pickers --%>
            <div :if={@stack_assignee_modal_mode == :advanced} class="flex flex-col gap-3">
              <div :for={phase <- ~w(planning execution review)} class="flex flex-col gap-1">
                <label class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
                  {phase_label(phase)}
                </label>
                <select
                  name={"assignees[" <> phase <> "]"}
                  class="select select-bordered select-sm w-full"
                >
                  <option value="">Unassigned</option>
                  <option
                    :for={agent <- @agents}
                    value={agent.id}
                    selected={stack_phase_assignee_id(@selected_stack, phase) == agent.id}
                  >
                    {agent.name}
                  </option>
                </select>
              </div>

              <p class="mt-1 text-[11px] text-base-content/50">
                This stack-level assignment is the default. It fans out to every member that
                isn't individually overridden — members with their own assignment are left
                untouched.
              </p>
            </div>

            <%!-- Actions --%>
            <div class="mt-2 flex justify-end gap-2 border-t border-base-300 pt-3">
              <button
                type="button"
                phx-click="stack_close_assignee_modal"
                phx-target={@myself}
                class="btn btn-sm btn-ghost"
              >
                Cancel
              </button>
              <button type="submit" class="btn btn-sm btn-primary">Save</button>
            </div>
          </form>
        </div>
      </div>
    </div>
    """
  end

  # ── Events ─────────────────────────────────────────────────────────────

  # Toggle a stack card's expansion state on the kanban board (T7 stage 2).
  #
  # `:expanded_stacks` is BOARD render state (the collapsed stack card is
  # board markup, and `refresh_board/1` resets the set per ADR 0041
  # acceptance criterion 3), so it stays shell-owned and moves with the
  # Board in stage 7. The click is routed here by `phx-target` because the
  # trigger belongs to the Stacks feature; the component then REQUESTS the
  # toggle rather than writing another concern's assign.
  def handle_event("stack_toggle_expand", %{"id" => stack_id}, socket) do
    send(self(), {:stacks_toggle_expand, stack_id})
    {:noreply, socket}
  end

  # Open the stack detail slide-in panel (T8 stage 1).
  #
  # Loads the stack + its members (ordered by `stack_position`) and flips
  # `:show_stack_detail` true. The shell is asked to drop its per-task
  # panel so the two slide-ins don't overlap — the component does NOT
  # write `selected_task`, which the shell owns.
  #
  # Defensive: a click on a stale DOM node whose stack id no longer exists
  # in the database is a no-op rather than a crash.
  def handle_event("stack_open_detail", %{"id" => stack_id}, socket) do
    case Stacks.get_stack(stack_id) do
      nil ->
        {:noreply, socket}

      %Stack{} = stack ->
        {members, counts} = load_stack_member_panel_data(stack)
        send(self(), {:stacks_close_task_detail})

        {:noreply,
         socket
         |> assign(:selected_stack, stack)
         |> assign(:selected_stack_members, members)
         |> assign(:selected_stack_member_review_counts, counts)
         |> assign_stack_review_state(stack)
         |> assign(:show_stack_feedback_overlay, false)
         |> assign(:show_stack_detail, true)}
    end
  end

  # Close the stack detail panel (T8 stage 1).
  def handle_event("stack_close_detail", _params, socket) do
    {:noreply, close_stack_panel(socket)}
  end

  # Stage-3 of task 019e2c27 (Stack-Level Review Rollup): toggle the rollup
  # overlay from the chrome "Needs feedback (N)" pill. The overlay reads
  # `:selected_stack_open_review_requests` + `:..._canvases`, both
  # maintained by `assign_stack_review_state/2` on every panel transition
  # (open, member status change, PubSub reload). Opening refreshes the
  # snapshot once more so a long-open panel sees the freshest data — cheap
  # (the same two queries the pill already runs) and it removes a whole
  # stale-state class of bugs from this surface.
  def handle_event("stack_open_feedback_overlay", _params, socket) do
    next = !socket.assigns.show_stack_feedback_overlay

    socket =
      if next and socket.assigns.selected_stack do
        assign_stack_review_state(socket, socket.assigns.selected_stack)
      else
        socket
      end

    {:noreply, assign(socket, :show_stack_feedback_overlay, next)}
  end

  # Explicit close for the rollup overlay. Backdrop click, overlay X and
  # the close button all wire here so the dismiss path is one event
  # regardless of trigger. The stack panel stays open behind it.
  def handle_event("stack_close_feedback_overlay", _params, socket) do
    {:noreply, reset_stack_feedback_overlay(socket)}
  end

  # Stage-4 of task 019e2c27: approve a single review item from the
  # overlay. Reuses `ReviewRequests.approve_item/2`, then optimistically
  # drops the item so the row vanishes immediately. Server-state
  # convergence still rides the `:review_request_resolved` PubSub handler
  # in the shell, which sends us `action: :reload`.
  def handle_event("stack_feedback_approve_item", %{"id" => item_id}, socket) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    case ReviewRequests.approve_item(item_id, reviewed_by) do
      {:ok, _item} ->
        {:noreply, drop_overlay_item(socket, item_id)}

      {:error, _} ->
        send(self(), {:stacks_flash, :error, "Failed to approve review item."})
        {:noreply, socket}
    end
  end

  # Toggle the reject-feedback textarea on a specific overlay item.
  # Scoped to the overlay so a row's textarea state does not bleed into the
  # per-task review panel below.
  def handle_event("stack_toggle_feedback_reject", %{"id" => item_id}, socket) do
    open = socket.assigns.stack_feedback_reject_open

    next =
      if MapSet.member?(open, item_id),
        do: MapSet.delete(open, item_id),
        else: MapSet.put(open, item_id)

    {:noreply, assign(socket, :stack_feedback_reject_open, next)}
  end

  # Capture textarea keystrokes for an item's reject-feedback buffer.
  # Keyed by item id so multiple rows can be in flight simultaneously
  # without their drafts colliding.
  def handle_event(
        "stack_update_feedback_reject_text",
        %{"item-id" => item_id, "feedback" => text},
        socket
      ) do
    {:noreply,
     socket
     |> assign(
       :stack_feedback_reject_text,
       Map.put(socket.assigns.stack_feedback_reject_text, item_id, text)
     )
     |> assign(
       :stack_feedback_reject_error,
       Map.delete(socket.assigns.stack_feedback_reject_error, item_id)
     )}
  end

  # Submit a reject + feedback for a single overlay item. Same optimistic
  # drop as the approve handler, plus clearing the in-flight draft.
  def handle_event("stack_feedback_reject_item", %{"item-id" => item_id} = params, socket) do
    reviewed_by = socket.assigns[:current_user_id] || "unknown"

    # Form-serialized, so whole by construction. The old `||` fallback to the
    # keystroke buffer is deliberately gone: it silently substituted a stale
    # draft for the value the reviewer actually submitted.
    feedback = Map.get(params, "feedback", "")

    if String.trim(feedback) == "" do
      {:noreply,
       socket
       |> assign(
         :stack_feedback_reject_text,
         Map.put(socket.assigns.stack_feedback_reject_text, item_id, feedback)
       )
       |> assign(
         :stack_feedback_reject_error,
         Map.put(
           socket.assigns.stack_feedback_reject_error,
           item_id,
           "Enter a reason before sending feedback."
         )
       )}
    else
      stack_submit_reject(socket, item_id, reviewed_by, feedback)
    end
  end

  # Abandon the open stack (T8 stage 1). Calls `Stacks.abandon_stack/2` and
  # closes the panel on success.
  def handle_event("stack_abandon", _params, %{assigns: %{selected_stack: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("stack_abandon", _params, socket) do
    case Stacks.abandon_stack(socket.assigns.selected_stack) do
      {:ok, _stack} ->
        send(self(), {:stacks_flash, :info, "Stack abandoned."})
        {:noreply, close_stack_panel(socket)}

      {:error, _changeset} ->
        send(self(), {:stacks_flash, :error, "Could not abandon stack."})
        {:noreply, socket}
    end
  end

  # Stack-level "Start Planning" cascade (T8 stage 3). Under Stack v2
  # wave-gated dispatch (ADR 0045 / task 019f487e), manual mode dispatches
  # wave 0 only; downstream waves advance when each member's plan approves.
  # On success/partial, reloads the panel so member statuses are fresh.
  def handle_event("stack_start_planning", _params, %{assigns: %{selected_stack: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("stack_start_planning", _params, socket) do
    case Stacks.start_planning(socket.assigns.selected_stack) do
      {:ok, %{stack: stack, planning: planning}} ->
        send(
          self(),
          {:stacks_flash, :info,
           "Started planning for #{length(planning)} #{member_word(length(planning))}."}
        )

        {:noreply, assign_stack_panel(socket, stack)}

      {:partial, %{stack: stack, planning: planning, errors: errors}} ->
        send(
          self(),
          {:stacks_flash, :error,
           "Started planning for #{length(planning)} #{member_word(length(planning))}; " <>
             "#{length(errors)} failed to transition."}
        )

        {:noreply, assign_stack_panel(socket, stack)}

      {:noop, :already_in_flight} ->
        send(self(), {:stacks_flash, :info, "Planning is already in flight for this stack."})
        {:noreply, socket}

      {:error, :cycle, _path} ->
        send(
          self(),
          {:stacks_flash, :error, "Cannot start planning: this stack has a dependency cycle."}
        )

        {:noreply, socket}

      {:error, :cross_stack_dep, _payload} ->
        send(
          self(),
          {:stacks_flash, :error,
           "Cannot start planning: a member depends on a task outside this stack."}
        )

        {:noreply, socket}

      {:error, _reason} ->
        send(
          self(),
          {:stacks_flash, :error, "Could not start planning for this stack."}
        )

        {:noreply, socket}
    end
  end

  # ── Stack-level assignee modal (ADR 0041) ──────────────────────────────

  def handle_event(
        "stack_open_assignee_modal",
        _params,
        %{assigns: %{selected_stack: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("stack_open_assignee_modal", _params, socket) do
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

  def handle_event("stack_close_assignee_modal", _params, socket) do
    {:noreply, assign(socket, :show_stack_assignee_modal, false)}
  end

  def handle_event("stack_set_assignee_modal_mode", %{"mode" => mode}, socket) do
    next =
      case mode do
        "advanced" -> :advanced
        _ -> :simple
      end

    {:noreply, assign(socket, :stack_assignee_modal_mode, next)}
  end

  def handle_event("stack_save_assignees", %{"assignees" => params}, socket) do
    stack = socket.assigns.selected_stack

    if is_nil(stack) do
      {:noreply, socket}
    else
      attrs_by_phase =
        case socket.assigns.stack_assignee_modal_mode do
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
          send(self(), {:stacks_board_refresh})

          send(
            self(),
            {:stacks_flash, :info,
             "Stack assignees saved — #{length(percolated)} member(s) updated" <>
               skipped_suffix(skipped)}
          )

          {:noreply,
           socket
           |> assign(:show_stack_assignee_modal, false)
           |> reload_selected_stack()}

        {:error, _} ->
          send(self(), {:stacks_flash, :error, "Failed to save stack assignees."})
          {:noreply, socket}
      end
    end
  end

  # OWNERSHIP CALL (stage 3): this event was filed under the Assignees
  # concern in the inventory, but it is reachable ONLY from stack detail and
  # it reads `:selected_stack_members`. It belongs to Stacks and is renamed
  # `stack_clear_member_override` here. Stage 5's Assignees component does
  # NOT carry it.
  def handle_event("stack_clear_member_override", %{"id" => task_id}, socket) do
    case Stacks.clear_member_override(task_id) do
      {:ok, _task} ->
        send(self(), {:stacks_board_refresh})

        send(
          self(),
          {:stacks_flash, :info, "Member returned to inheriting the stack default."}
        )

        {:noreply, reload_selected_stack(socket)}

      {:error, _reason} ->
        send(self(), {:stacks_flash, :error, "Could not clear the member override."})
        {:noreply, socket}
    end
  end

  # Stack dep-graph fullscreen modal open/close (stage 3 of task 019f487e).
  # Bare assigns — the modal's `:if` guard in the template already checks
  # `@stack_graph_expanded && @selected_stack_members not in [nil, []]`.
  def handle_event("stack_open_graph_expand", _params, socket) do
    {:noreply, assign(socket, :stack_graph_expanded, true)}
  end

  def handle_event("stack_close_graph_expand", _params, socket) do
    {:noreply, assign(socket, :stack_graph_expanded, false)}
  end

  # ── Panel state helpers ────────────────────────────────────────────────

  defp assign_stack_panel(socket, %Stack{} = stack) do
    {members, counts} = load_stack_member_panel_data(stack)

    socket
    |> assign(:selected_stack, stack)
    |> assign(:selected_stack_members, members)
    |> assign(:selected_stack_member_review_counts, counts)
    |> assign_stack_review_state(stack)
  end

  defp close_stack_panel(socket) do
    socket
    |> assign(:selected_stack, nil)
    |> assign(:selected_stack_members, [])
    |> assign(:selected_stack_member_review_counts, %{})
    |> assign_stack_review_state(nil)
    |> assign(:show_stack_feedback_overlay, false)
    |> assign(:show_stack_detail, false)
    |> assign(:stack_graph_expanded, false)
  end

  # Reload `:selected_stack` + `:selected_stack_members` from the DB so the
  # panel reflects writes (stack-level assignment, override clears) and
  # PubSub-driven member transitions. No-op when no panel is open.
  defp reload_selected_stack(%{assigns: %{selected_stack: nil}} = socket), do: socket

  defp reload_selected_stack(%{assigns: %{selected_stack: %Stack{id: id}}} = socket) do
    case Stacks.get_stack(id) do
      nil -> close_stack_panel(socket)
      %Stack{} = stack -> assign_stack_panel(socket, stack)
    end
  end

  # Preload `:plans` on the stack's members so `Tasks.needs_human_action?/2`
  # can resolve the `:plan_pending_review` branch off the struct, and
  # compute the pending-review-request counts the same predicate needs.
  defp load_stack_member_panel_data(%Stack{} = stack) do
    members = stack |> Stacks.members() |> Repo.preload(:plans)
    {members, pending_review_counts(members)}
  end

  # Set the three assigns backing the stack-feedback chrome pill AND its
  # overlay in one place so the COUNT (pill) and the LIST (overlay rows)
  # are always derived from the same snapshot. Pass `nil` for `stack` to
  # reset to closed-panel state.
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

    socket
    |> sync_stack_review_request_subscriptions(MapSet.new(members, & &1.id))
    |> assign(:selected_stack_pending_review_count, length(requests))
    |> assign(:selected_stack_open_review_requests, enriched)
    |> assign(:selected_stack_open_review_canvases, load_review_canvases(requests))
  end

  # Keep the per-stack-member `review_requests:<task_id>` subscription set
  # in sync with the open panel's member set. On unsubscribe we skip
  # task_ids ALSO held by the board-level subscription set (passed in as the
  # read-only `:board_review_subscriptions` attr) so the board's
  # live-update contract is not collateral-damaged when the panel closes.
  # Idempotent; no-op on a disconnected socket.
  defp sync_stack_review_request_subscriptions(socket, desired) do
    if connected?(socket) do
      current = socket.assigns[:stack_review_request_subscriptions] || MapSet.new()
      board = socket.assigns[:board_review_subscriptions] || MapSet.new()

      to_add = MapSet.difference(desired, current)
      to_drop = MapSet.difference(MapSet.difference(current, desired), board)

      Enum.each(to_add, &ReviewRequests.subscribe_for_task/1)
      Enum.each(to_drop, &ReviewRequests.unsubscribe_for_task/1)

      assign(socket, :stack_review_request_subscriptions, desired)
    else
      socket
    end
  end

  # Full reset of the stack-feedback overlay surface state, so a half-typed
  # reject draft doesn't survive across opens.
  defp reset_stack_feedback_overlay(socket) do
    socket
    |> assign(:show_stack_feedback_overlay, false)
    |> assign(:stack_feedback_reject_open, MapSet.new())
    |> assign(:stack_feedback_reject_text, %{})
    |> assign(:stack_feedback_reject_error, %{})
  end

  # Optimistic per-item removal in the overlay after an approve / reject
  # lands. Drops the matching item and any RR that loses its last item; the
  # pending count is recomputed from the resulting list so the chrome pill
  # mirrors the overlay's row count exactly.
  defp drop_overlay_item(socket, item_id) do
    pruned =
      socket.assigns.selected_stack_open_review_requests
      |> Enum.map(fn rr ->
        Map.put(rr, :items, Enum.reject(rr.items || [], &(&1.id == item_id)))
      end)
      |> Enum.reject(&((&1.items || []) == []))

    socket
    |> assign(:selected_stack_open_review_requests, pruned)
    |> assign(:selected_stack_pending_review_count, length(pruned))
  end

  defp skipped_suffix([]), do: "."

  defp skipped_suffix(skipped),
    do: ", #{length(skipped)} with an individual override left untouched."

  # ── Meta-grid helpers ──────────────────────────────────────────────────
  #
  # Compute the four meta-grid cell values from a `%Stack{}` and its
  # preloaded member list:
  #
  #     %{
  #       status:    %{label: "In Review", class: "text-warning"},
  #       members:   %{count: 4, ready_count: 3, text: "4 · 3 ready"},
  #       dep_edges: %{count: 3, valid?: true, text: "3 · valid DAG"},
  #       branch:    "stack/user-keyed-saves"
  #     }
  #
  # The `Stacks` context already exposes member_count/dep_edge_count via
  # `build_board_data/1` for the board card, but the "ready" rule here is
  # broader (it counts merged_into_rollup_at members too), so we compute
  # fresh rather than reuse the board-data map.
  defp stack_meta(%Stack{} = stack, members) when is_list(members) do
    %{
      status: %{
        label: status_label(stack.status),
        class: stack_status_text_class(stack.status)
      },
      members: stack_meta_members(members),
      dep_edges: dep_edge_summary(members),
      branch: stack.rollup_branch || ""
    }
  end

  defp stack_meta_members(members) when is_list(members) do
    count = length(members)
    ready_count = Enum.count(members, &member_ready?/1)
    %{count: count, ready_count: ready_count, text: "#{count} · #{ready_count} ready"}
  end

  # A member is "ready" (in the meta-grid sense) when its branch has been
  # merged into the rollup OR its status has crossed the unblock threshold.
  # Stamping happens after a merge succeeds, so the OR catches members that
  # are status-ready but not yet merged AND merged-but-back-pending ones.
  defp member_ready?(%{status: status, metadata: metadata}) do
    status in ["in_review", "deploying", "done"] or
      (is_map(metadata) and not is_nil(Map.get(metadata, "merged_into_rollup_at")))
  end

  # Whether a stack member is following the stack-level default
  # (`"inherited"`) or carries an individual assignee override
  # (`"override"`). Drives the per-member badge in the stack detail panel.
  defp member_assignment_badge(member),
    do: (Stacks.member_overridden?(member) && "override") || "inherited"

  # Stack-level analogue of the per-task `phase_assignee_id/2` — reads the
  # stack's `metadata["phase_assignees"]` default for the assignee modal.
  defp stack_phase_assignee_id(%Stack{} = stack, phase) do
    case Stacks.stack_phase_assignees(stack) |> Map.get(phase) do
      %{"assignee_id" => id} when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp stack_phase_assignee_id(_, _), do: nil

  defp stack_submit_reject(socket, item_id, reviewed_by, feedback) do
    case ReviewRequests.reject_item(item_id, reviewed_by, feedback) do
      {:ok, _item} ->
        {:noreply,
         socket
         |> assign(
           :stack_feedback_reject_open,
           MapSet.delete(socket.assigns.stack_feedback_reject_open, item_id)
         )
         |> assign(
           :stack_feedback_reject_error,
           Map.delete(socket.assigns.stack_feedback_reject_error, item_id)
         )
         |> assign(
           :stack_feedback_reject_text,
           Map.delete(socket.assigns.stack_feedback_reject_text, item_id)
         )
         |> drop_overlay_item(item_id)}

      {:error, _} ->
        send(self(), {:stacks_flash, :error, "Failed to submit feedback."})
        {:noreply, socket}
    end
  end
end
