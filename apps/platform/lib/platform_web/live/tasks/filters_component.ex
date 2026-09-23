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

  `:sponsor_filter` is the exception and is deliberately NOT owned here.
  `?sponsor=mine` is the authoritative source (share-a-URL contract), which
  makes `handle_params/3` the writer — and `handle_params/3` is a LiveView
  callback that cannot exist in a LiveComponent. Owning the assign here
  would mean two writers racing over one value. What this component owns is
  the *control*: `filter_toggle_sponsor` push_patches the URL and the
  shell's `handle_params/3` decodes it, which is what the shell handler did
  before the move. The current value arrives as a read-only attr.

  `:board_sort` (task 01a0cef1 stage 2) is the same shape, for the same
  reason: `?sort=updated` is decoded by `handle_params/3`, the value arrives
  here read-only, and the control's two options are `patch` links built by
  `BoardData.tasks_path/2`, so the sort needs no event at all.

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
           `text-soylent`) so users always know which tenant context they're
           inside.

           THE MOST VISIBLE SINGLE LEAK this task had left (01a00cf1 stage 3):
           it is on screen at both breakpoints for as long as a project is
           selected, directly above the masked rail, so an unmasked breadcrumb
           does not merely leak — it makes the masked rail beside it read as
           broken. Both halves follow @mask_labels.

           `Tenancy.scope_color/1` keeps the real slug on purpose: it emits a
           CSS utility class and no name, class names cannot be regenerated per
           session, and `Platform.MaskAssertions` excludes `class` for exactly
           that reason. Named limitation, as on the rail.

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
        class="flex items-center gap-1 px-4 pb-2 text-xs text-base-content/60"
      >
        <span
          :for={p <- @projects}
          :if={p.id == @selected_project_id}
          class="flex items-center gap-1"
        >
          <span
            :if={match?(%Tenancy.Org{}, p.org)}
            class={"font-medium #{Tenancy.scope_color(p.org.slug)}"}
          >
            {TaskDisplay.label_for(@mask_labels, @mask_names?, {:org, p.org.slug},
              real: Tenancy.scope_label(p.org.slug)
            )}
          </span>
          <span :if={match?(%Tenancy.Org{}, p.org)} class="text-base-content/40">/</span>
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
           SLUG, a plain string (`"fabrikam"`, `"soylent"`, etc) that stays a
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
              else: "bg-base-200 text-base-content/70 border-base-content/15 hover:bg-base-300"
            )
          ]}
        >
          <span class="scope-pill-label">All</span>
          <span class={[
            "inline-flex items-center justify-center min-w-[18px] h-[18px] rounded-full text-[10px] font-bold tabular-nums",
            if(@scope_filter == :all,
              do: "bg-base-100/20 text-base-100",
              else: "bg-base-300 text-base-content/70"
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
          <.scope_pill
            scope={entry.slug}
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
              else: "bg-base-200 text-base-content/60"
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
              else: "bg-base-200 text-base-content/70 border-base-content/15 hover:bg-base-300"
            )
          ]}
        >
          <span>My work</span>
        </button>
      </nav>

      <%!-- Sort control (task 01a0cef1 stage 2). A SIBLING of the scope rail,
           not a chip inside it: the rail narrows the set and scrolls, this
           reorders it and never scrolls (`shrink-0`). See `SortControl`. --%>
      <SortControl.sort_control
        id="board-sort-control"
        role="board-sort-control"
        board_sort={@board_sort}
        sponsor_filter={@sponsor_filter}
        class="hidden lg:inline-flex shrink-0"
      />
    </div>
    """
  end

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

    {:noreply, announce(socket, %{task_search_query: query})}
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
      {:ok, parsed} -> {:noreply, announce(socket, %{scope_filter: parsed})}
      :error -> {:noreply, socket}
    end
  end

  # No-scope variant: the "All" chip dispatches without a phx-value-scope so
  # users can reset the filter from a single click.
  def handle_event("filter_scope", _params, socket) do
    {:noreply, announce(socket, %{scope_filter: :all})}
  end

  # Thin push_patch shim: `handle_params/3` in the shell owns the decode, so
  # a share-a-URL loader and a click loader end up in the same state. Going
  # back to `:all` DROPS the `?sponsor` param entirely to preserve the
  # canonical URL (a `?sponsor=all` URL is never emitted).
  #
  # The path comes from `BoardData.tasks_path/2` so the toggle PRESERVES the
  # current `?sort=` (task 01a0cef1 stage 2); a fixed path here would drop it.
  def handle_event("filter_toggle_sponsor", _params, socket) do
    next = if socket.assigns[:sponsor_filter] == :mine, do: :all, else: :mine

    {:noreply, push_patch(socket, to: BoardData.tasks_path(next, socket.assigns[:board_sort]))}
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
