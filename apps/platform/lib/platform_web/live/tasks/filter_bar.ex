defmodule PlatformWeb.Tasks.FilterBar do
  @moduledoc """
  The phone Tasks header (task 01a161fd stage 3, the designer's prototype
  canvas 01a16202 node `p`): the project title button, the Filter button and
  its badge, the search field and the chips row. Rendered by
  `PlatformWeb.Tasks.MyTasksList` inside `#tasks-my-list`.

  ## Links, not events

  Every control that changes the URL (a chip's remove, Clear all) is a plain
  `<.link patch>` with NO `phx-click`: a bare `phx-click` on a patch link
  throws `TypeError: this[kind] is not a function` in the client. Its `href`
  comes from `BoardData.tasks_path/1`, the one builder, so a link that
  changes one param keeps every other. Only the sheet triggers are
  `<button type="button" phx-click>`; their events live in
  `PlatformWeb.Tasks.FilterHooks`.

  ## Counting

  The badge and the chips count the same list, `active_filters/2`: status,
  kind, Mine, I sponsor, the search query, and the two old options the
  prototype omits (Org scope and Source). The project, the epic and the sort
  are never counted and never removable. Clear all and Reset keep them.

  ## Palette

  Ground base-200, controls base-100 with `border-edge`, pressed
  `active:bg-base-200`. No `hover:` utility and no `text-base-content/<n>`:
  text is `text-base-content` or `text-subtle`.
  """
  use Phoenix.Component

  import PlatformWeb.Components.ActionPatterns, only: [search_input: 1]

  alias PlatformWeb.Tasks.{BoardData, StatusLabels, TaskDisplay}

  @url_keys ~w(sponsor_filter board_sort task_search_query scope_filter kind_filter kind_filters
               origin_filter selected_project_id selected_epic_id status_filters mine_filter)a

  @sort_labels %{
    priority: "Priority",
    updated: "Recently updated",
    newest: "Newest",
    oldest: "Oldest"
  }

  @doc "The URL state a link is built from: the `tasks_path/1` keys of `assigns`."
  def url_state(assigns), do: Map.take(assigns, @url_keys)

  @doc "The `/tasks` URL for `url` with `changes` applied."
  def href(url, changes), do: BoardData.tasks_path(Map.merge(url, changes))

  @doc """
  Clear all and Reset: status, kind, Mine, I sponsor, the query, Org scope and
  Source cleared; project, epic and sort kept.
  """
  def clear_href(url) do
    href(url, %{
      status_filters: [],
      kind_filters: [],
      kind_filter: :all,
      mine_filter: false,
      sponsor_filter: :all,
      task_search_query: "",
      scope_filter: :all,
      origin_filter: :all
    })
  end

  @doc "The sort chip's and the Sort section's label for a mode."
  def sort_label(mode), do: Map.get(@sort_labels, mode, "Priority")

  @doc "Sort modes in the Sort section's order (the board's `sort_modes/0`)."
  def sort_modes, do: BoardData.sort_modes()

  @doc "A kind's label: 'Feature', 'Bug', ..."
  def kind_label(kind), do: String.capitalize(kind)

  @doc """
  The active filters, in chip order: `%{key, label, remove}` where `remove`
  is the patch URL without that one value.
  """
  def active_filters(url, org_label \\ & &1) do
    statuses = list(url[:status_filters])
    kinds = kind_list(url)
    q = url[:task_search_query]

    Enum.map(statuses, fn s ->
      %{
        key: "status-#{s}",
        label: StatusLabels.status_sentence(s),
        remove: href(url, %{status_filters: List.delete(statuses, s)})
      }
    end) ++
      Enum.map(kinds, fn k ->
        %{
          key: "kind-#{k}",
          label: kind_label(k),
          remove: href(url, %{kind_filters: List.delete(kinds, k), kind_filter: :all})
        }
      end) ++
      Enum.reject(
        [
          url[:mine_filter] == true &&
            %{key: "mine", label: "Mine", remove: href(url, %{mine_filter: false})},
          url[:sponsor_filter] == :mine &&
            %{key: "sponsor", label: "I sponsor", remove: href(url, %{sponsor_filter: :all})},
          BoardData.search_active?(q) &&
            %{key: "q", label: ~s("#{q}"), remove: href(url, %{task_search_query: ""})},
          is_binary(url[:scope_filter]) &&
            %{
              key: "org",
              label: org_label.(url[:scope_filter]),
              remove: href(url, %{scope_filter: :all})
            },
          url[:origin_filter] == "external_feedback" &&
            %{
              key: "source",
              label: "External feedback",
              remove: href(url, %{origin_filter: :all})
            }
        ],
        &(&1 == false)
      )
  end

  @doc "The kind set a URL state means: the list, else the old single value."
  def kind_list(url) do
    case {list(url[:kind_filters]), url[:kind_filter]} do
      {[], kind} when is_binary(kind) -> [kind]
      {kinds, _} -> kinds
    end
  end

  defp list(values) when is_list(values), do: values
  defp list(_values), do: []

  @doc "The masked label for an org scope slug, for the Org chip and section."
  def org_label(mask_labels, masked?, active_scopes, slug) do
    TaskDisplay.scope_pill_label(mask_labels, masked?, slug) ||
      Enum.find_value(active_scopes, slug, &(&1.slug == slug && &1.label))
  end

  # ── Header ──────────────────────────────────────────────────────────────

  attr :project_label, :string, default: nil, doc: "masked; nil means All projects"
  attr :epic_label, :string, default: nil, doc: "masked"
  attr :expanded?, :boolean, default: false
  attr :count, :integer, required: true, doc: "active filters (the badge)"

  @doc "The title button, the Filter button and its badge."
  def header(assigns) do
    ~H"""
    <header class="flex min-w-0 flex-1 items-center gap-2 py-3 pl-4 pr-1">
      <.title_button project_label={@project_label} epic_label={@epic_label} expanded?={@expanded?} />
      <.filter_button count={@count} />
    </header>
    """
  end

  attr :id, :string, default: "tasks-title-picker"
  attr :variant, :atom, default: :phone, values: [:phone, :desktop]
  attr :project_label, :string, default: nil, doc: "masked; nil means All projects"
  attr :epic_label, :string, default: nil, doc: "masked"
  attr :expanded?, :boolean, default: false
  attr :rest, :global

  @doc """
  The project title button. `:phone` is the list header's h1 on base-200;
  `:desktop` (stage 4) sits in the board's `page_header` on base-100, at
  `lg` only, and opens the title menu.
  """
  def title_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="tasks-title-picker"
      phx-click="tasks_filter_open"
      phx-value-sheet="project"
      aria-haspopup="dialog"
      aria-expanded={to_string(@expanded?)}
      aria-label={title_aria(@project_label, @epic_label)}
      class={[
        "min-w-0 items-center gap-1.5 rounded-field text-left focus-visible-ring",
        if(@variant == :phone,
          do: "flex min-h-11 flex-1 active:bg-base-100",
          else: "hidden min-h-9 max-w-80 px-1 active:bg-base-200 lg:inline-flex"
        )
      ]}
      {@rest}
    >
      <%!-- The phone title is the list's h1; on desktop the page_header
           already carries the page's h1, so the label is a span. --%>
      <.dynamic_tag
        tag_name={if @variant == :phone, do: "h1", else: "span"}
        class={[
          "flex min-w-0 font-semibold text-base-content",
          if(@variant == :phone, do: "text-lg", else: "text-base")
        ]}
      >
        <span data-role="tasks-title-project" class="min-w-0 truncate">
          {@project_label || "All projects"}
        </span>
        <span :if={@epic_label} data-role="tasks-title-epic" class="shrink-0 whitespace-nowrap">
          &nbsp;› {@epic_label}
        </span>
      </.dynamic_tag>
      <span class="hero-chevron-down size-4 shrink-0 text-base-content" aria-hidden="true"></span>
    </button>
    """
  end

  attr :id, :string, default: "tasks-filter-button"
  attr :variant, :atom, default: :phone, values: [:phone, :desktop]
  attr :count, :integer, required: true, doc: "active filters (the badge)"
  attr :expanded?, :boolean, default: false
  attr :rest, :global

  @doc """
  The Filter button and its badge. `:desktop` (stage 4) is `hidden
  lg:inline-flex` beside the settings menu and opens the filter popover.
  """
  def filter_button(assigns) do
    ~H"""
    <button
      type="button"
      id={@id}
      data-role="tasks-filter-button"
      phx-click="tasks_filter_open"
      phx-value-sheet="filter"
      aria-haspopup="dialog"
      aria-expanded={@variant == :desktop && to_string(@expanded?)}
      aria-label={if @count > 0, do: "Filter, #{@count} on", else: "Filter"}
      class={[
        "shrink-0 items-center gap-1.5 rounded-field border border-edge bg-base-100 px-3 text-sm font-medium text-base-content active:bg-base-200 focus-visible-ring",
        if(@variant == :phone, do: "inline-flex h-10", else: "hidden h-8 lg:inline-flex")
      ]}
      {@rest}
    >
      Filter
      <span
        :if={@count > 0}
        data-role="tasks-filter-badge"
        class="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-base-content px-1 text-xs font-bold text-base-100"
      >
        {@count}
      </span>
    </button>
    """
  end

  @doc "The title's project label, masked; nil means All projects."
  def title_project(%{selected_project_id: nil}), do: nil

  def title_project(assigns) do
    id = assigns.selected_project_id
    real = Enum.find_value(assigns.projects, "Project", &(&1.id == id && &1.name))
    TaskDisplay.label_for(assigns.mask_labels, assigns.mask_names?, {:project, id}, real: real)
  end

  @doc "The title's epic label, masked; nil when no epic is selected."
  def title_epic(%{selected_project_id: pid, selected_epic_id: id} = assigns)
      when is_binary(pid) and is_binary(id) do
    real = Enum.find_value(assigns.epics, "Epic", &(&1.id == id && &1.name))
    TaskDisplay.label_for(assigns.mask_labels, assigns.mask_names?, {:epic, id}, real: real)
  end

  def title_epic(_assigns), do: nil

  defp title_aria(project, epic) do
    "Project: #{project || "All projects"}#{if epic, do: ", epic #{epic}"}. Change project"
  end

  attr :query, :string, default: ""

  @doc "The search field: the board's own `filter_search` handler, a new id."
  def search(assigns) do
    ~H"""
    <div class="shrink-0 px-4 pb-2.5">
      <.search_input
        id="tasks-my-search"
        event="filter_search"
        target="#tasks-filters"
        value={@query}
        placeholder="Search tasks"
        aria_label="Search tasks"
      />
    </div>
    """
  end

  attr :board_sort, :atom, default: :priority
  attr :filters, :list, required: true, doc: "active_filters/2"
  attr :clear_href, :string, required: true

  @doc "The sort chip (never removable), one chip per active filter, Clear all from 2."
  def chips(assigns) do
    ~H"""
    <div
      data-role="tasks-filter-chips"
      class="flex shrink-0 items-center gap-2 overflow-x-auto px-4 pb-2.5"
    >
      <button
        type="button"
        data-role="tasks-sort-chip"
        phx-click="tasks_filter_open"
        phx-value-sheet="filter"
        aria-haspopup="dialog"
        aria-label={"Sort: #{sort_label(@board_sort)}. Change sort"}
        class="inline-flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-edge bg-base-100 px-3 text-[13px] font-semibold text-base-content active:bg-base-200 focus-visible-ring"
      >
        {sort_label(@board_sort)}
        <span class="hero-chevron-down size-3.5 shrink-0" aria-hidden="true"></span>
      </button>
      <.link
        :for={f <- @filters}
        patch={f.remove}
        data-role="tasks-filter-chip"
        data-chip={f.key}
        aria-label={"Remove filter #{f.label}"}
        class="inline-flex h-8 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-full border border-edge bg-base-100 px-3 text-[13px] text-base-content active:bg-base-200 focus-visible-ring"
      >
        {f.label}<span class="text-[15px] leading-none text-subtle" aria-hidden="true">×</span>
      </.link>
      <.link
        :if={length(@filters) >= 2}
        patch={@clear_href}
        data-role="tasks-clear-all"
        class="sticky -right-4 -mr-4 ml-auto inline-flex h-8 shrink-0 items-center whitespace-nowrap bg-base-200 pr-4 pl-1 text-[13px] font-medium text-base-content underline focus-visible-ring"
      >
        Clear all
      </.link>
    </div>
    """
  end
end
