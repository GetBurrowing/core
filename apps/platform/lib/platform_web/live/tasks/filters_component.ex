defmodule PlatformWeb.Tasks.FiltersComponent do
  @moduledoc """
  Board filtering — search, scope rail, sponsor toggle, mobile status pills
  and the active-filter breadcrumb. Extracted from `PlatformWeb.TasksLive`
  by task 01a008f6 stage 6.

  ## Ownership

  Writer for `:task_search_query`, `:scope_filter` and
  `:active_status_filter`. Every write is announced with
  `send(self(), {:tasks_filters_changed, filters})`; the shell mirrors the
  values and does the board work. This component NEVER calls
  `refresh_board/1` and never touches a board assign — the shell mediates,
  exactly as the stage contract requires. The shell's copies are a
  read-only MIRROR, the same arrangement `SidebarComponent` already uses
  for `:epics_collapsed`, and they become plain attrs on the board
  component in stage 7.

  `:sponsor_filter` was, until task 01a08df0 stage 1, the one exception —
  deliberately NOT owned here, because `?sponsor=mine` is the authoritative
  source (share-a-URL contract) and `handle_params/3` — a LiveView callback
  that cannot exist in a LiveComponent — is its writer. `:task_search_query`
  and `:scope_filter` now have the SAME dual arrangement, for the SAME
  reason (a filtered board must be linkable): this component still `assign`s
  them locally via `announce/2` so the control re-renders immediately
  without waiting for the patch round trip, but `filter_search`/
  `filter_scope` now ALSO `push_patch` (`?q=`/`?scope=`), and
  `handle_params/3` decodes them back on every mount/patch — the same
  arrangement `filter_toggle_sponsor` already used for `:sponsor_filter`. So
  all four board filters (`sponsor`, `sort`, `q`, `scope`) are URL-decoded by
  the shell; this component's `announce/2` writes are now a local-echo
  optimization on three of them, not the sole source of truth on any.

  `:board_sort` (task 01a0cef1 stage 2) is the one filter with no local echo
  at all: `?sort=updated` is decoded by `handle_params/3`, the value arrives
  here read-only, and the control's two options are `patch` links built by
  `BoardData.tasks_path/1`, so the sort needs no event at all.

  Five events, and the plan's count of five is right for once:
  `filter_search`, `filter_by_status`, `filter_scope`,
  `filter_toggle_sponsor`, `filter_clear`.

  ## Three regions, one component

  The concern's markup is NOT contiguous, and never was — the plan's single
  cited range (123-413) covers only part of it. At `74448b78` it is at
  `tasks_live.html.heex` 54-63 (search input, in the `page_header`
  `:search` slot), 189-323 (breadcrumb + scope rail + sponsor toggle, in
  the `:filters` slot) and 401-445 (mobile status pills, nested inside the
  mobile list container). A LiveComponent renders in exactly one place, so
  the largest region moves into this module's `~H` and the other two stay
  as *trigger sites* in the shell carrying `phx-target="#tasks-filters"` —
  the same shape stage 2 established for `SidebarComponent`, whose triggers
  are scattered across the shell too. State and events are wholly here;
  only two fragments of markup are not.

  ## Read-only masking attrs (task 01a00cf1 stage 3)

  `mask_names?` and `mask_labels` arrive as ATTRS from the shell (written by
  `PlatformWeb.Tasks.MaskHooks`) and are never written here. Two of this
  component's three regions render real org and project names — the breadcrumb
  and the scope rail's sub-org chips — and both sit in the page header, above
  the rail stage 2 masked. No render site may call `SidebarMask` or resolve its
  own placeholder: one map, one resolved string per entity, or the text surface
  and the `aria-label` surface disagree.

  ## Hook retargeting

  Two JS hooks push filter events, and `pushEvent` from a hook ignores
  `phx-target` — it always lands on the parent LiveView. Both were
  converted to `pushEventTo("#tasks-filters", ...)` in the same commit:
  `tasks_status_filter.js` (replays the stored mobile pill on mount) and
  `last_project.js` (replays a stored "All projects" as `filter_clear`).
  Left alone, both would have gone silently dead with every `mix test`
  still green — the click paths they shadow keep working.
  """
  use PlatformWeb, :live_component

  alias Platform.Tasks.Task
  alias Platform.Tenancy
  alias PlatformWeb.Tasks.{BoardData, SortControl, TaskDisplay}

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Active filter breadcrumb. Stage 5 of ADR-0042 prefixes the project
           with `<org_label> / ` (org name carries the scope color token, e.g.
           `text-initech`) so users always know which tenant context they're
           inside.

           THE MOST VISIBLE SINGLE LEAK this task had left (01a00cf1 stage 3):
           it is on screen at both breakpoints for as long as a project is
           selected, directly above the masked rail, so an unmasked breadcrumb
           does not merely leak — it makes the masked rail beside it read as
           broken. Both halves follow @mask_labels.

           The org name is coloured from its row through `data-scope`
           (`.scope-fill-text`; task 01a14dd9 stage 2 retired the per-slug
           `text-<slug>` class). `data-scope` spells the slug, so it is
           dropped while masking is on and the name renders uncoloured.

           THE EPIC NAME FOLLOWS THE MASK TOO. An epic is an entity with an id
           and a name — structurally a project, reachable by the same lookup —
           not free text like a task title, so `@mask_labels` carries an
           `{:epic, id}` key and this span reads it through the same
           `label_for/4` its two siblings use. Leaving it real put a live epic
           name directly above a fully masked rail, which does not merely leak:
           it makes the rail beside it read as broken. --%>
      <div
        :if={@selected_project_id}
        data-role="tasks-breadcrumb"
        class="flex items-center gap-1 px-4 pb-2 text-xs text-subtle"
      >
        <span
          :for={p <- @projects}
          :if={p.id == @selected_project_id}
          class="flex items-center gap-1"
        >
          <span
            :if={match?(%Tenancy.Org{}, p.org)}
            class="font-medium scope-fill-text"
            data-scope={if(@mask_names?, do: nil, else: p.org.slug)}
          >
            {TaskDisplay.label_for(@mask_labels, @mask_names?, {:org, p.org.slug}, real: p.org.name)}
          </span>
          <span :if={match?(%Tenancy.Org{}, p.org)} aria-hidden="true" class="text-decorative">
            /
          </span>
          <span>
            {TaskDisplay.label_for(@mask_labels, @mask_names?, {:project, p.id}, real: p.name)}
          </span>
        </span>
        <span :if={@selected_epic_id}>
          /
          <span :for={e <- @epics} :if={e.id == @selected_epic_id}>
            {TaskDisplay.label_for(@mask_labels, @mask_names?, {:epic, e.id}, real: e.name)}
          </span>
        </span>
        <button
          phx-click="filter_clear"
          phx-target={@myself}
          class="btn btn-ghost btn-xs btn-square ml-1"
          aria-label="Clear filters"
        >
          <span class="hero-x-mark size-3"></span>
        </button>
      </div>

      <%!-- Scope-filter rail (desktop, Stage 3 of Tasks v2 — 2026-05-19).
           One chip per active org the viewer belongs to (task 01a09287
           stage 2 — no longer a fixed six), plus an "All" reset. Mobile keeps the 5-pill status
           nav — the rail is `hidden lg:flex` only, per the responsive-scope
           contract.

           Each sub-org chip uses the foundation `<.scope_pill />` primitive
           (futureproof seam for the MT/RBAC stack 019e3c49). Counts come from
           `@scope_counts` populated by `Platform.Tasks.count_by_scope/0`.

           Click semantics: the "All" chip dispatches `filter_scope` with
           `phx-value-scope="all"`; sub-org chips dispatch it with their scope
           SLUG, a plain string (`"acme"`, `"initech"`, etc) that stays a
           string all the way through `parse_scope/2` into `@scope_filter`. The
           shell narrows the kanban render via
           `desktop_column_items_for_scope/6` once it mirrors the value. --%>
      <nav
        id="tasks-scope-rail"
        aria-label="Filter tasks by sub-org scope"
        class="hidden min-w-0 lg:flex items-center gap-2 overflow-x-auto"
      >
        <button
          type="button"
          phx-click="filter_scope"
          phx-target={@myself}
          phx-value-scope="all"
          aria-pressed={@scope_filter == :all}
          data-scope-chip="all"
          data-active={to_string(@scope_filter == :all)}
          class={[
            "inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium leading-none transition-colors focus-visible-ring",
            if(@scope_filter == :all,
              do:
                "bg-base-content text-base-100 border-base-content shadow-[0_0_0_2px_oklch(70%_0_0/30%)]",
              else: "bg-base-200 text-base-content border-base-content/15 hover:bg-base-300"
            )
          ]}
        >
          <span class="scope-pill-label">All</span>
          <span class={[
            "inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums",
            if(@scope_filter == :all,
              do: "bg-base-100/20 text-base-100",
              else: "bg-base-300 text-base-content"
            )
          ]}>
            {scope_count_total(@scope_counts)}
          </span>
        </button>
        <span
          :for={entry <- @active_scopes}
          data-scope-chip={TaskDisplay.scope_pill_slug(@mask_labels, @mask_names?, entry.slug)}
          data-active={to_string(@scope_filter == entry.slug)}
          class="inline-flex items-center gap-1"
        >
          <%!-- event/target are NOT optional decoration: `scope_pill/1`
               hardcoded an un-targeted `phx-click="scope_filter"` until
               stage 6, so without these the sub-org chips would render
               perfectly and click into a shell that no longer handles them.

               `label` is the seam PR #769 already cut for the chat rail (task
               01a00c66) — it overrides the visible text AND the aria-label
               together, which is the whole point: a chip that masks its text
               and keeps the real org name in the accessibility tree has not
               been masked. THIS IS THE SIXTH SURFACE, found by stage 2's live
               DOM sweep and absent from stage 3's written site list. It sits in
               the page header, inches above the masked rail, at desktop width.
               Passing `nil` while unmasked leaves the pill computing its own
               label exactly as before — see `TaskDisplay.scope_pill_label/3`. --%>
          <%!-- `scope` is the org's SLUG AS A STRING and `label` is its own
               `Org.name`, since task 01a09287 stage 2 removed the
               `Tasks.scope_keys/0` allowlist this rail used to intersect.
               Never convert the slug to an atom on the way in or out — the
               atom exists for the six orgs that shipped with the code and
               does not exist for one an admin created this morning, which
               is exactly the shape that passes local testing and 500s
               `/tasks` in production (task 019fa209).

               Passing `label` unconditionally also means the pill never
               needs to look a slug up: while masking is on
               `scope_pill_label/3` returns the placeholder, and while it is
               off this hands over the real org name rather than leaving the
               pill to guess from a six-entry map. --%>
          <%!-- `surface` is declared, not inherited (task 01a09333-d374):
               these chips sit in `page_header/1`'s `bg-base-100` header. --%>
          <.scope_pill
            scope={entry.slug}
            surface={:base_100}
            active={@scope_filter == entry.slug}
            event="filter_scope"
            target={@myself}
            label={
              TaskDisplay.scope_pill_label(@mask_labels, @mask_names?, entry.slug) || entry.label
            }
            value={TaskDisplay.scope_pill_slug(@mask_labels, @mask_names?, entry.slug)}
          />
          <span class={[
            "inline-flex items-center justify-center min-w-[18px] h-[18px] -ml-0.5 rounded-full text-[10px] font-bold tabular-nums",
            if(@scope_filter == entry.slug,
              do: "bg-base-content/15 text-base-content",
              else: "bg-base-200 text-subtle"
            )
          ]}>
            {Map.get(@scope_counts, entry.slug, 0)}
          </span>
        </span>

        <%!-- "Sponsored by me" toggle (Stage 2 of task 019f3f22 —
             ADR-0042 sponsor visibility). Click flips between `:all` ↔
             `:mine` and push_patches the URL so `?sponsor=mine` is
             authoritative (share-a-URL contract, matches `?project=` /
             `?scope=` semantics — no localStorage / session persistence per
             ADR non-goals). Mobile uses the same URL param via
             `handle_params/3`. --%>
        <button
          type="button"
          phx-click="filter_toggle_sponsor"
          phx-target={@myself}
          aria-pressed={if @sponsor_filter == :mine, do: "true", else: "false"}
          aria-label="Filter tasks and stacks to those I sponsor"
          data-role="sponsor-filter-toggle"
          data-active={to_string(@sponsor_filter == :mine)}
          class={[
            "ml-auto inline-flex items-center gap-1.5 rounded-full border px-2.5 py-0.5 text-xs font-medium leading-none transition-colors focus-visible-ring",
            if(@sponsor_filter == :mine,
              do:
                "bg-primary text-primary-content border-primary shadow-[0_0_0_2px_oklch(70%_0.15_260/30%)]",
              else: "bg-base-200 text-base-content border-base-content/15 hover:bg-base-300"
            )
          ]}
        >
          <span>My work</span>
        </button>
      </nav>

      <%!-- External Feedback lane (task 01a11ec3 stage 4). Two patch links,
           no event: `?origin=external_feedback` is decoded by
           `BoardHooks.apply_url_filters/3`, which narrows every board query on
           the PERSISTED `origin` column. Rendered at every width — the lane
           is a primary surface, not a desktop-only refinement. --%>
      <nav
        data-role="origin-lane-tabs"
        aria-label="Task lanes"
        class="inline-flex shrink-0 items-center gap-0.5 rounded-full border border-edge bg-base-200 p-0.5"
      >
        <.link
          :for={{lane, label, icon} <- origin_lanes()}
          patch={
            BoardData.tasks_path(
              @sponsor_filter,
              @board_sort,
              @task_search_query,
              @scope_filter,
              @kind_filter,
              lane
            )
          }
          data-role="origin-lane-tab"
          data-lane={to_string(lane)}
          aria-current={if lane_active?(@origin_filter, lane), do: "page", else: "false"}
          class={[
            "inline-flex h-7 items-center gap-1 rounded-full px-2.5 text-xs font-medium leading-none whitespace-nowrap transition-colors focus-visible-ring max-sm:h-9",
            if(lane_active?(@origin_filter, lane),
              do: "bg-primary text-primary-content",
              else: "text-base-content hover:bg-base-300"
            )
          ]}
        >
          <span class={[icon, "size-3.5"]} aria-hidden="true"></span>
          <span>{label}</span>
        </.link>
      </nav>

      <form phx-change="filter_kind" phx-target={@myself} class="block shrink-0">
        <label for="tasks-kind-filter" class="sr-only">Filter tasks by kind</label>
        <select
          id="tasks-kind-filter"
          name="kind"
          data-role="task-kind-filter"
          aria-label="Filter tasks by kind"
          class="select select-bordered select-xs min-h-7 h-7"
        >
          <option value="all" selected={@kind_filter == :all}>All kinds</option>
          <option
            :for={kind <- Task.kinds()}
            value={kind}
            selected={@kind_filter == kind}
          >
            {String.capitalize(kind)}
          </option>
        </select>
      </form>

      <%!-- Sort control (task 01a0cef1 stage 2). A SIBLING of the scope rail,
           not a chip inside it: the rail narrows the set and scrolls, this
           reorders it and never scrolls (`shrink-0`). See `SortControl`. --%>
      <SortControl.sort_control
        id="board-sort-control"
        role="board-sort-control"
        board_sort={@board_sort}
        sponsor_filter={@sponsor_filter}
        task_search_query={@task_search_query}
        scope_filter={@scope_filter}
        kind_filter={@kind_filter}
        origin_filter={@origin_filter}
        class="hidden lg:inline-flex shrink-0"
      />
    </div>
    """
  end

  # The two lanes, in tab order. `:all` is the unfiltered board (the default,
  # emits no `?origin=`); `"external_feedback"` is the persisted origin value.
  defp origin_lanes do
    [
      {:all, "All tasks", "hero-squares-2x2"},
      {"external_feedback", "External feedback", "hero-inbox-arrow-down"}
    ]
  end

  defp lane_active?(origin_filter, :all), do: origin_filter != "external_feedback"
  defp lane_active?(origin_filter, lane), do: origin_filter == lane

  # Header total for the "All" chip. The sum of every sub-org bucket.
  defp scope_count_total(scope_counts) when is_map(scope_counts) do
    scope_counts |> Map.values() |> Enum.sum()
  end

  defp scope_count_total(_), do: 0

  # ── Events ──────────────────────────────────────────────────────────────

  # Fired by the page-header `<.search_input>`: live phx-change (debounced
  # 200ms, params carry "q"), Enter submit (same params) and Escape keydown
  # (params carry "key" — treated as clear).
  @impl true
  def handle_event("filter_search", params, socket) do
    # Read BEFORE announce/2 overwrites it — this is the pre-keystroke value,
    # needed to tell "starting a new search from blank" apart from "typing
    # another character into an already-active search" below.
    previous_query = socket.assigns.task_search_query

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

    # `announce/2` updates this component's local mirror AND notifies the
    # shell (unchanged); `push_patch` is new (task 01a08df0 stage 1) — it
    # makes `?q=` the shareable, refreshable source of truth, matching
    # `filter_toggle_sponsor`'s existing pattern below. Built from
    # `socket.assigns` AFTER `announce/2` so the patch carries the query just
    # written, not last render's value.
    #
    # `replace:` depends on the blank -> non-blank transition, not a bare
    # `true` (task 01a08df0 remediation, validation 01a0ea7b-afaa-7002):
    # the FIRST keystroke since the query was blank must PUSH a new history
    # entry, because the current entry is the pre-search page (bare
    # `/tasks`, or whatever the user was on) — replacing it would overwrite
    # that entry via `history.replaceState`, which destroys its content
    # irretrievably, so Back could never return to it. Every subsequent
    # keystroke within an already-active search (non-blank -> non-blank)
    # still replaces, collapsing 'Z'/'Ze'/'Zep' onto the one entry pushed by
    # the first keystroke, exactly as before. Clearing the search
    # (non-blank -> blank, via Escape/Clear-search) also keeps `replace:
    # true`: the entry being replaced is itself an already-pushed search
    # entry (not the original pre-search entry, which was preserved by the
    # push above), so replacing it loses nothing.
    starting_new_search? = previous_query == "" and query != ""

    socket = announce(socket, %{task_search_query: query})

    {:noreply,
     push_patch(socket,
       to: BoardData.tasks_path(socket.assigns),
       replace: not starting_new_search?
     )}
  end

  # Mobile-only: status-filter pill bar above the section-grouped task list.
  # Validates the incoming status against the mobile columns to ignore
  # garbage — a stale ClientState value replayed by `tasks_status_filter.js`
  # is the realistic source.
  def handle_event("filter_by_status", %{"status" => status}, socket) do
    if Enum.any?(socket.assigns.mobile_columns, fn {key, _label} -> key == status end) do
      {:noreply, announce(socket, %{active_status_filter: status})}
    else
      {:noreply, socket}
    end
  end

  # Desktop-only: scope-filter rail. The scope arrives as a string (Phoenix
  # serializes `phx-value-scope={@scope}` from an atom into its string
  # name), so parse it against the canonical allowlist — anything outside
  # the known set is ignored rather than blowing up
  # `String.to_existing_atom/1`.
  #
  # While masking is on the chip emits the per-session PLACEHOLDER slug
  # (task 01a00cf1), so the value is resolved back to the real slug before it
  # meets the allowlist. Unmasked, `real_org_slug/2` returns its argument
  # unchanged and this reads exactly as it did.
  def handle_event("filter_scope", %{"scope" => scope}, socket) do
    resolved = TaskDisplay.real_org_slug(socket.assigns[:mask_labels] || %{}, scope)

    case parse_scope(socket, resolved) do
      # `push_patch` (task 01a08df0 stage 1), in addition to the existing
      # `announce/2`: `?scope=` becomes shareable, matching `?q=` above and
      # `?sponsor=mine` below. NO `replace: true` — a scope chip is a
      # discrete, deliberate choice (not a keystroke stream), so it pushes
      # its own history entry, same as `filter_toggle_sponsor`'s unchanged
      # pattern.
      {:ok, parsed} ->
        socket = announce(socket, %{scope_filter: parsed})
        {:noreply, push_patch(socket, to: BoardData.tasks_path(socket.assigns))}

      :error ->
        {:noreply, socket}
    end
  end

  # No-scope variant: the "All" chip dispatches without a phx-value-scope so
  # users can reset the filter from a single click.
  def handle_event("filter_scope", _params, socket) do
    socket = announce(socket, %{scope_filter: :all})
    {:noreply, push_patch(socket, to: BoardData.tasks_path(socket.assigns))}
  end

  def handle_event("filter_kind", %{"kind" => kind}, socket) do
    parsed = if kind in Task.kinds(), do: kind, else: :all

    {:noreply,
     push_patch(socket, to: BoardData.tasks_path(%{socket.assigns | kind_filter: parsed}))}
  end

  # Thin push_patch shim: `handle_params/3` in the shell owns the decode, so
  # a share-a-URL loader and a click loader end up in the same state. Going
  # back to `:all` DROPS the `?sponsor` param entirely to preserve the
  # canonical URL (a `?sponsor=all` URL is never emitted).
  #
  # The path comes from `BoardData.tasks_path/1` (the map form, task
  # 01a08df0 stage 1 — was the 2-arg `tasks_path/2` before this stage) so
  # the toggle PRESERVES `?sort=` (task 01a0cef1 stage 2) AND now `?q=`/
  # `?scope=` too — the "no patch can drop a param" invariant `tasks_path/4`
  # documents applies to every control, not just the two that existed when
  # it was written.
  def handle_event("filter_toggle_sponsor", _params, socket) do
    next = if socket.assigns[:sponsor_filter] == :mine, do: :all, else: :mine

    {:noreply,
     push_patch(socket, to: BoardData.tasks_path(%{socket.assigns | sponsor_filter: next}))}
  end

  # Clearing the project/epic breadcrumb is shell work (it re-queries epics
  # and pushes the localStorage sync), so this only reports the intent.
  def handle_event("filter_clear", _params, socket) do
    send(self(), {:tasks_filters_cleared})
    {:noreply, socket}
  end

  # Assign locally so this component re-renders immediately, and announce so
  # the shell can mirror + rebuild the board. Never `refresh_board/1` here.
  defp announce(socket, changes) do
    send(self(), {:tasks_filters_changed, changes})
    assign(socket, changes)
  end

  # Membership test against the chips this viewer was actually rendered,
  # never a conversion. `String.to_existing_atom/1` on user input is a crash
  # waiting for a scope that was never compiled, and `String.to_atom/1` is
  # unbounded atom-table growth from a `phx-value-` payload. The filter value
  # STAYS A STRING from here on; `:all` is the one atom, and it is ours.
  #
  # Scoping to `@active_scopes` rather than to every org is deliberate: a
  # replayed or hand-crafted payload naming an org the viewer has no
  # membership in is ignored, exactly as an unknown slug is.
  defp parse_scope(_socket, "all"), do: {:ok, :all}

  defp parse_scope(socket, scope) when is_binary(scope) do
    if Enum.any?(socket.assigns[:active_scopes] || [], &(&1.slug == scope)) do
      {:ok, scope}
    else
      :error
    end
  end

  defp parse_scope(_socket, _), do: :error
end
