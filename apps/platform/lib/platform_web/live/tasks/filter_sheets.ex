defmodule PlatformWeb.Tasks.FilterSheets do
  @moduledoc """
  The phone Tasks sheets (task 01a161fd stage 3, prototype canvas 01a16202
  node `p`): the project sheet (`#psheet`, with its epic level) and the
  filter sheet (`#fsheet`). Rendered by `PlatformWeb.Tasks.MyTasksList`.

  ## The sheet gate

  Both are `<.sheet placement={:bottom} handle_close swipe_dismiss>` with the
  `:handle` slot left EMPTY, the shape task 01a161c4 makes `sheet/1` require.
  `handle_close` hides the sheet's own title visually (it still names the
  dialog), so each body starts with a visible, `aria-hidden` heading line,
  the idiom of `inbox_list.ex`'s `inbox-row-sheet`.

  ## Options are links

  Every option that changes the URL (project, epic, sort, status, kind, scope,
  sponsor, org, source, Reset) is a plain `<.link patch>` with NO
  `phx-click`, built by `FilterBar.href/2` over `BoardData.tasks_path/1`. Only
  the epic drill-in (›), Back and 'Show N tasks' are buttons. A pick in the
  project sheet closes it (`FilterHooks.after_patch/1`); the filter sheet
  stays open, so its options apply live.

  'All projects' is `?project=all`, because an ABSENT `project` means 'keep the
  current or remembered project' (stages 1-2).

  Pressed options are `active:bg-base-200` on the base-100 sheet; no `hover:`
  utility (desktop hover is stage 4's plain CSS). Status dots are decorative
  (`aria-hidden`): the word beside each carries the meaning.
  """
  use Phoenix.Component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]

  alias PlatformWeb.Tasks.{FilterBar, StatusLabels, TaskDisplay}

  # The Status section's order (the stage inventory), every Task.statuses/0.
  @status_order ~w(backlog planning in_progress in_review blocked deploying stack_pending done cancelled)
  # The Kind section's order (the prototype), every Task.kinds/0.
  @kind_order ~w(feature bug chore research ops)

  @doc "The Status section's order."
  def status_order, do: @status_order
  @doc "The Kind section's order."
  def kind_order, do: @kind_order

  @opt "tasks-filter-opt flex min-h-12 min-w-0 flex-1 items-center gap-2.5 rounded-field px-2 text-left text-[15px] text-base-content active:bg-base-200 focus-visible-ring"
  @tog "tasks-filter-tog inline-flex h-9 items-center gap-1.5 rounded-full border border-edge px-3 text-sm text-base-content active:bg-base-200 focus-visible-ring"
  @seg "tasks-filter-tog inline-flex h-9 items-center px-[18px] text-sm text-base-content active:bg-base-200 focus-visible-ring"
  @label "mb-2 text-xs font-medium text-subtle"

  # ── Project sheet ───────────────────────────────────────────────────────

  attr :sheet, :any, required: true, doc: "@tasks_filter_sheet"
  attr :url, :map, required: true
  attr :projects, :list, default: []
  attr :drill_epics, :list, default: [], doc: "@tasks_filter_epics"
  attr :mask_names?, :boolean, default: false
  attr :mask_labels, :map, default: %{}

  @doc "The phone project sheet: `project_picker/1` in a bottom sheet."
  def project_sheet(assigns) do
    assigns = assign(assigns, :open?, project_open?(assigns.sheet))

    ~H"""
    <.sheet
      id="tasks-project-sheet"
      open={@open?}
      placement={:bottom}
      on_close="tasks_filter_close"
      class="lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Choose project</:title>
      <.project_picker
        :if={@open?}
        sheet={@sheet}
        url={@url}
        projects={@projects}
        drill_epics={@drill_epics}
        mask_names?={@mask_names?}
        mask_labels={@mask_labels}
      />
    </.sheet>
    """
  end

  @doc "True when `@tasks_filter_sheet` opens the project picker (either level)."
  def project_open?(sheet), do: sheet == :project or match?({:epics, _}, sheet)

  attr :sheet, :any, required: true, doc: "@tasks_filter_sheet"
  attr :url, :map, required: true
  attr :projects, :list, default: []
  attr :drill_epics, :list, default: [], doc: "@tasks_filter_epics"
  attr :mask_names?, :boolean, default: false
  attr :mask_labels, :map, default: %{}

  @doc """
  The project picker's body, root level and epic level: shared by the phone
  sheet and the desktop title menu (stage 4).
  """
  def project_picker(assigns) do
    drill_id =
      case assigns.sheet do
        {:epics, id} -> id
        _ -> nil
      end

    assigns =
      assigns
      |> assign(:drill_id, drill_id)
      |> assign(:selected, assigns.url[:selected_project_id])
      |> assign(:selected_epic, assigns.url[:selected_epic_id])
      |> assign(:listed, Enum.reject(assigns.projects, &Platform.Projects.archived?/1))
      |> assign(:opt, @opt)

    ~H"""
    <div :if={is_nil(@drill_id)} data-role="tasks-project-root" class="flex flex-col">
      <p
        class="flex min-h-10 items-center px-2 pb-1.5 text-base font-semibold text-base-content"
        aria-hidden="true"
      >
        Project
      </p>
      <.link
        patch={FilterBar.href(@url, %{selected_project_id: "all", selected_epic_id: nil})}
        data-role="tasks-project-option"
        data-project="all"
        aria-current={if is_nil(@selected), do: "true"}
        class={@opt}
      >
        <span class="w-[18px] shrink-0 font-bold" aria-hidden="true">
          {if is_nil(@selected), do: "✓"}
        </span>
        <span class="min-w-0 flex-1 truncate">All projects</span>
      </.link>
      <div :for={p <- @listed} class="flex min-w-0 items-center">
        <.link
          patch={FilterBar.href(@url, %{selected_project_id: p.id, selected_epic_id: nil})}
          data-role="tasks-project-option"
          data-project={p.id}
          aria-current={if @selected == p.id, do: "true"}
          class={@opt}
        >
          <span class="w-[18px] shrink-0 font-bold" aria-hidden="true">
            {mark(@selected == p.id, @selected_epic)}
          </span>
          <span class="min-w-0 flex-1 truncate">{project_label(assigns, p)}</span>
        </.link>
        <button
          type="button"
          phx-click="tasks_filter_epics"
          phx-value-id={p.id}
          data-role="tasks-project-epics"
          aria-label={"Epics in #{project_label(assigns, p)}"}
          class="inline-flex size-11 shrink-0 items-center justify-center rounded-field text-subtle active:bg-base-200 focus-visible-ring"
        >
          <span class="hero-chevron-right size-4" aria-hidden="true"></span>
        </button>
      </div>
    </div>
    <div :if={@drill_id} data-role="tasks-project-epic-level" class="flex flex-col">
      <div class="flex min-h-10 items-center gap-2 pb-1.5">
        <button
          type="button"
          phx-click="tasks_filter_back"
          data-role="tasks-project-back"
          aria-label="Back to projects"
          class="inline-flex size-9 shrink-0 items-center justify-center rounded-field text-base-content active:bg-base-200 focus-visible-ring"
        >
          <span class="hero-chevron-left size-4" aria-hidden="true"></span>
        </button>
        <p
          class="min-w-0 flex-1 truncate text-base font-semibold text-base-content"
          aria-hidden="true"
        >
          {drill_label(assigns)}
        </p>
      </div>
      <.link
        patch={FilterBar.href(@url, %{selected_project_id: @drill_id, selected_epic_id: nil})}
        data-role="tasks-epic-option"
        data-epic="all"
        aria-current={if @selected == @drill_id and is_nil(@selected_epic), do: "true"}
        class={@opt}
      >
        <span class="w-[18px] shrink-0 font-bold" aria-hidden="true">
          {if @selected == @drill_id and is_nil(@selected_epic), do: "✓"}
        </span>
        <span class="min-w-0 flex-1 truncate">All of {drill_label(assigns)}</span>
      </.link>
      <.link
        :for={e <- @drill_epics}
        patch={FilterBar.href(@url, %{selected_project_id: @drill_id, selected_epic_id: e.id})}
        data-role="tasks-epic-option"
        data-epic={e.id}
        aria-current={if @selected_epic == e.id, do: "true"}
        class={@opt}
      >
        <span class="w-[18px] shrink-0 font-bold" aria-hidden="true">
          {if @selected_epic == e.id, do: "✓"}
        </span>
        <span class="min-w-0 flex-1 truncate">
          {TaskDisplay.label_for(@mask_labels, @mask_names?, {:epic, e.id}, real: e.name)}
        </span>
      </.link>
    </div>
    """
  end

  defp mark(true, nil), do: "✓"
  defp mark(true, _epic), do: "•"
  defp mark(false, _epic), do: nil

  defp project_label(assigns, p),
    do:
      TaskDisplay.label_for(assigns.mask_labels, assigns.mask_names?, {:project, p.id},
        real: p.name
      )

  defp drill_label(%{drill_id: id} = assigns) do
    case Enum.find(assigns.projects, &(&1.id == id)) do
      nil -> TaskDisplay.label_for(assigns.mask_labels, true, {:project, id}, real: "Project")
      p -> project_label(assigns, p)
    end
  end

  # ── Filter sheet ────────────────────────────────────────────────────────

  attr :open?, :boolean, required: true
  attr :url, :map, required: true
  attr :count, :integer, required: true, doc: "@filtered_count"
  attr :active_scopes, :list, default: []
  attr :mask_names?, :boolean, default: false
  attr :mask_labels, :map, default: %{}

  @doc "The phone filter sheet: `filter_body/1` and `filter_foot/1` in a bottom sheet."
  def filter_sheet(assigns) do
    ~H"""
    <.sheet
      id="tasks-filter-sheet"
      open={@open?}
      placement={:bottom}
      on_close="tasks_filter_close"
      class="lg:hidden"
      handle_close
      swipe_dismiss
    >
      <:title>Filter and sort tasks</:title>
      <.filter_body
        :if={@open?}
        url={@url}
        active_scopes={@active_scopes}
        mask_names?={@mask_names?}
        mask_labels={@mask_labels}
      />
      <:actions>
        <.filter_foot :if={@open?} url={@url} count={@count} />
      </:actions>
    </.sheet>
    """
  end

  attr :url, :map, required: true
  attr :active_scopes, :list, default: []
  attr :mask_names?, :boolean, default: false
  attr :mask_labels, :map, default: %{}

  @doc """
  Filter and sort: Sort, Status, Kind, Scope, Sponsor, plus Org and Source.
  Shared by the phone sheet and the desktop popover (stage 4).
  """
  def filter_body(assigns) do
    url = assigns.url

    assigns =
      assigns
      |> assign(:statuses, url[:status_filters] || [])
      |> assign(:kinds, FilterBar.kind_list(url))
      |> assign(:tog, @tog)
      |> assign(:seg, @seg)
      |> assign(:label, @label)

    ~H"""
    <div data-role="tasks-filter-sheet-body" class="flex flex-col">
      <p
        class="flex min-h-10 items-center pb-1.5 text-base font-semibold text-base-content"
        aria-hidden="true"
      >
        Filter and sort
      </p>

      <section data-role="tasks-filter-sort" class="py-2.5">
        <p class={@label} aria-hidden="true">Sort</p>
        <div role="radiogroup" aria-label="Sort" class="flex flex-wrap gap-2">
          <.link
            :for={mode <- FilterBar.sort_modes()}
            patch={FilterBar.href(@url, %{board_sort: mode})}
            role="radio"
            aria-checked={to_string(@url[:board_sort] == mode)}
            data-role="tasks-filter-option"
            data-sort={mode}
            class={[@tog, on(@url[:board_sort] == mode)]}
          >
            {FilterBar.sort_label(mode)}<.tick :if={@url[:board_sort] == mode} />
          </.link>
        </div>
      </section>

      <section data-role="tasks-filter-status" class="border-t border-edge py-2.5">
        <p class={@label} aria-hidden="true">Status</p>
        <div role="group" aria-label="Status" class="flex flex-wrap gap-2">
          <.link
            :for={s <- status_order()}
            patch={FilterBar.href(@url, %{status_filters: toggle(@statuses, s)})}
            aria-pressed={to_string(s in @statuses)}
            data-role="tasks-filter-option"
            data-status={s}
            class={[@tog, on(s in @statuses)]}
          >
            <span
              data-role="tasks-status-dot"
              class={["size-2 shrink-0 rounded-full", StatusLabels.dot_class(s)]}
              aria-hidden="true"
            >
            </span>
            {StatusLabels.status_sentence(s)}<.tick :if={s in @statuses} />
          </.link>
        </div>
      </section>

      <section data-role="tasks-filter-kind" class="border-t border-edge py-2.5">
        <p class={@label} aria-hidden="true">Kind</p>
        <div role="group" aria-label="Kind" class="flex flex-wrap gap-2">
          <.link
            :for={k <- kind_order()}
            patch={FilterBar.href(@url, %{kind_filters: toggle(@kinds, k), kind_filter: :all})}
            aria-pressed={to_string(k in @kinds)}
            data-role="tasks-filter-option"
            data-kind={k}
            class={[@tog, on(k in @kinds)]}
          >
            {FilterBar.kind_label(k)}<.tick :if={k in @kinds} />
          </.link>
        </div>
      </section>

      <section data-role="tasks-filter-scope" class="border-t border-edge py-2.5">
        <p class={@label} aria-hidden="true">Scope</p>
        <div
          role="radiogroup"
          aria-label="Scope"
          class="inline-flex overflow-hidden rounded-field border border-edge"
        >
          <.link
            :for={{mine?, text} <- [{true, "Mine"}, {false, "All"}]}
            patch={FilterBar.href(@url, %{mine_filter: mine?})}
            role="radio"
            aria-checked={to_string(@url[:mine_filter] == true == mine?)}
            data-role="tasks-filter-option"
            data-mine={to_string(mine?)}
            class={[@seg, on(@url[:mine_filter] == true == mine?)]}
          >
            {text}
          </.link>
        </div>
      </section>

      <section data-role="tasks-filter-sponsor" class="border-t border-edge py-2.5">
        <p class={@label} aria-hidden="true">Sponsor</p>
        <.link
          patch={
            FilterBar.href(@url, %{
              sponsor_filter: if(@url[:sponsor_filter] == :mine, do: :all, else: :mine)
            })
          }
          role="checkbox"
          aria-checked={to_string(@url[:sponsor_filter] == :mine)}
          data-role="tasks-filter-option"
          data-sponsor="mine"
          class="tasks-filter-opt flex min-h-11 items-center gap-2.5 rounded-field text-[15px] text-base-content active:bg-base-200 focus-visible-ring"
        >
          <span
            data-role="tasks-sponsor-box"
            class={[
              "inline-flex size-5 shrink-0 items-center justify-center rounded-[5px] border-2 border-base-content text-xs font-bold",
              @url[:sponsor_filter] == :mine && "bg-base-content text-base-100"
            ]}
            aria-hidden="true"
          >
            {if @url[:sponsor_filter] == :mine, do: "✓"}
          </span>
          Only tasks I sponsor
        </.link>
      </section>

      <%!-- Old options the prototype omits (design deviations): the org
             scope rail, shown only with 2 or more scopes, and the origin
             lanes. --%>
      <section
        :if={length(@active_scopes) >= 2}
        data-role="tasks-filter-org"
        class="border-t border-edge py-2.5"
      >
        <p class={@label} aria-hidden="true">Org</p>
        <div role="radiogroup" aria-label="Org" class="flex flex-wrap gap-2">
          <.link
            :for={{slug, text} <- org_options(assigns)}
            patch={FilterBar.href(@url, %{scope_filter: slug})}
            role="radio"
            aria-checked={to_string(org_on?(@url[:scope_filter], slug))}
            data-role="tasks-filter-option"
            data-org={if slug == :all, do: "all", else: "org"}
            class={[@tog, on(org_on?(@url[:scope_filter], slug))]}
          >
            {text}
          </.link>
        </div>
      </section>

      <section data-role="tasks-filter-source" class="border-t border-edge py-2.5">
        <p class={@label} aria-hidden="true">Source</p>
        <div role="radiogroup" aria-label="Source" class="flex flex-wrap gap-2">
          <.link
            :for={{lane, text} <- [{:all, "All"}, {"external_feedback", "External feedback"}]}
            patch={FilterBar.href(@url, %{origin_filter: lane})}
            role="radio"
            aria-checked={to_string(source_on?(@url[:origin_filter], lane))}
            data-role="tasks-filter-option"
            data-source={to_string(lane)}
            class={[@tog, on(source_on?(@url[:origin_filter], lane))]}
          >
            {text}
          </.link>
        </div>
      </section>
    </div>
    """
  end

  attr :url, :map, required: true
  attr :count, :integer, required: true, doc: "@filtered_count"
  attr :on_show, :any, default: "tasks_filter_close", doc: "the Show button's phx-click"

  @doc "The footer: Reset and 'Show N tasks' (disabled 'No tasks match' at 0)."
  def filter_foot(assigns) do
    assigns = assign(assigns, :clear_href, FilterBar.clear_href(assigns.url))

    ~H"""
    <div data-role="tasks-filter-foot" class="flex w-full items-center gap-3">
      <.link
        patch={@clear_href}
        data-role="tasks-filter-reset"
        class="inline-flex min-h-11 items-center text-sm font-medium text-base-content underline focus-visible-ring"
      >
        Reset
      </.link>
      <button
        type="button"
        phx-click={@on_show}
        data-role="tasks-filter-show"
        disabled={@count == 0}
        class={[
          "ml-auto inline-flex h-11 items-center rounded-field px-[18px] text-sm font-semibold focus-visible-ring",
          if(@count == 0,
            do: "bg-base-300 text-subtle",
            else: "bg-primary text-primary-content"
          )
        ]}
      >
        {show_label(@count)}
      </button>
    </div>
    """
  end

  defp tick(assigns) do
    ~H"""
    <span class="text-xs" aria-hidden="true">✓</span>
    """
  end

  @doc "The footer button's copy."
  def show_label(0), do: "No tasks match"
  def show_label(1), do: "Show 1 task"
  def show_label(n), do: "Show #{n} tasks"

  defp on(true), do: "bg-base-300 font-semibold"
  defp on(_), do: "bg-base-100"

  defp toggle(list, value) do
    if value in list, do: List.delete(list, value), else: list ++ [value]
  end

  defp org_options(assigns) do
    [{:all, "All"}] ++
      Enum.map(assigns.active_scopes, fn entry ->
        {entry.slug,
         FilterBar.org_label(
           assigns.mask_labels,
           assigns.mask_names?,
           assigns.active_scopes,
           entry.slug
         )}
      end)
  end

  defp org_on?(scope, :all), do: not is_binary(scope)
  defp org_on?(scope, slug), do: scope == slug

  defp source_on?(origin, :all), do: origin != "external_feedback"
  defp source_on?(origin, lane), do: origin == lane
end
