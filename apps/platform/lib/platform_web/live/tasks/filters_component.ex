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

  alias Platform.Tasks
  alias Platform.Tenancy

  @impl true
  def update(assigns, socket), do: {:ok, assign(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="contents">
      <%!-- Active filter breadcrumb. Stage 5 of ADR-0042 prefixes the project
           with `<org_label> / ` (org name carries the scope color token, e.g.
           `text-soylent`) so users always know which tenant context they're
           inside. --%>
      <div
        :if={@selected_project_id}
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
            {Tenancy.scope_label(p.org.slug)}
          </span>
          <span :if={match?(%Tenancy.Org{}, p.org)} class="text-base-content/40">/</span>
          <span>{p.name}</span>
        </span>
        <span :if={@selected_epic_id}>
          / <span :for={e <- @epics} :if={e.id == @selected_epic_id}>{e.name}</span>
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
           Five sub-org chips + an "All" reset. Mobile keeps the 5-pill status
           nav — the rail is `hidden lg:flex` only, per the responsive-scope
           contract.

           Each sub-org chip uses the foundation `<.scope_pill />` primitive
           (futureproof seam for the MT/RBAC stack 019e3c49). Counts come from
           `@scope_counts` populated by `Platform.Tasks.count_by_scope/0`.

           Click semantics: the "All" chip dispatches `filter_scope` with
           `phx-value-scope="all"`; sub-org chips dispatch it with their scope
           atom serialized to a string (`"fabrikam"`, `"soylent"`, etc). The
           shell narrows the kanban render via
           `desktop_column_items_for_scope/4` once it mirrors the value. --%>
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
          :for={scope <- @active_scope_keys}
          data-scope-chip={Atom.to_string(scope)}
          data-active={to_string(@scope_filter == scope)}
          class="inline-flex items-center gap-1"
        >
          <%!-- event/target are NOT optional decoration: `scope_pill/1`
               hardcoded an un-targeted `phx-click="scope_filter"` until
               stage 6, so without these the sub-org chips would render
               perfectly and click into a shell that no longer handles them. --%>
          <.scope_pill
            scope={scope}
            active={@scope_filter == scope}
            event="filter_scope"
            target={@myself}
          />
          <span class={[
            "inline-flex items-center justify-center min-w-[18px] h-[18px] -ml-0.5 rounded-full text-[10px] font-bold tabular-nums",
            if(@scope_filter == scope,
              do: "bg-base-content/15 text-base-content",
              else: "bg-base-200 text-base-content/60"
            )
          ]}>
            {Map.get(@scope_counts, scope, 0)}
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
  def handle_event("filter_scope", %{"scope" => scope}, socket) do
    case parse_scope(socket, scope) do
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
  def handle_event("filter_toggle_sponsor", _params, socket) do
    path =
      case socket.assigns[:sponsor_filter] do
        :mine -> ~p"/tasks"
        _ -> ~p"/tasks?sponsor=mine"
      end

    {:noreply, push_patch(socket, to: path)}
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

  # Allowlist first, never convert: `String.to_existing_atom/1` on user
  # input is a crash waiting for a scope that was never rendered.
  defp parse_scope(_socket, scope) when is_binary(scope) do
    Enum.find(Tasks.scope_keys(), &(Atom.to_string(&1) == scope))
    |> case do
      nil -> if scope == "all", do: {:ok, :all}, else: :error
      parsed -> {:ok, parsed}
    end
  end

  defp parse_scope(_socket, _), do: :error
end
