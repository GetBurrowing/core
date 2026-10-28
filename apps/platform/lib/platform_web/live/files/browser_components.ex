defmodule PlatformWeb.Files.BrowserComponents do
  @moduledoc """
  Function components for the Files & Canvases browser in
  `PlatformWeb.FilesLive` (Burrow redesign rung 16, task 01a1557a-b5f9 stage 2;
  masters prototype 01a137f2 `master-mobile.html` v3 :641-646, :361-412,
  :1119-1192 and `master-desktop.html` :942-955; Saru's direction canvas
  01a161fc-d30b, nodes `pal`, `type`, `lay`, `rules`).

  The data comes from `Platform.Files.Browser`; the LiveView owns the URL and
  hands these components a `browser` map (mode, node, type, sort, query, items)
  and a `labels` map built at render time through the name-masking context, so
  no org, project or channel name reaches markup except through `labels`.

  ## Rows are two sibling links

  Each list row (and grid tile) holds the ITEM link and, where it applies, the
  LOCATION link, as siblings inside the `<li>`, never nested. Neither carries a
  `phx-click`: a bare-string `phx-click` on a live link throws
  `TypeError: this[kind] is not a function` and a `JS.push` on a redirect link
  never reaches the server (both measured in rung 5). State changes happen in
  `FilesLive.handle_params/3`.

    * a project file links with `patch` (same LiveView: `?file=` opens the
      detail pane);
    * a canvas links with `navigate` (`/canvases/:id` is another live
      session, so this is a full load);
    * a space file (chat attachment) is a plain `href`.

  ## No hover utilities

  No hover-variant utility class appears anywhere in this module (phone
  surfaces have no hover). The pressed state is `active:bg-base-100`; desktop
  hover is plain CSS in app.css (rung 16 stage 4).
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.CoreComponents, only: [icon: 1]

  alias Platform.Files.Browser.Item
  alias PlatformWeb.Components.ChatHelpers
  alias PlatformWeb.Files.BrowserView
  alias PlatformWeb.FilesLive

  @type_words %{file: "Files", canvas: "Canvases", game: "Games", doc: "Docs", image: "Images"}
  @type_singular %{file: "files", canvas: "canvases", game: "games", doc: "docs", image: "images"}
  @type_icons %{
    canvas: "hero-rectangle-group",
    game: "hero-puzzle-piece",
    doc: "hero-document-text",
    image: "hero-photo"
  }

  @doc "The h1 word for a type chip at All (prototype :944)."
  def type_word(type), do: Map.get(@type_words, type, "Files")

  @doc "The glyph for an item type."
  def type_icon(type), do: Map.get(@type_icons, type, "hero-document")

  # ── Header ───────────────────────────────────────────────────────────────

  attr :browser, :map, required: true
  attr :new_open, :boolean, default: false
  slot :new_panel, doc: "the desktop New menu, positioned under the ＋ button"

  @doc """
  The header: a 44px back button to More (`open_more_sheet`, handled by
  ShellLive, as rung 14's inbox-back; phone only), the h1, a search link and
  the ＋ New button, the page's one primary control (stage 3). ＋ opens the
  New sheet on phone and the `:new_panel` menu on desktop.
  """
  def browser_header(assigns) do
    ~H"""
    <header data-role="files-header" class="flex h-13 shrink-0 items-center gap-2.5 px-4">
      <button
        type="button"
        phx-click="open_more_sheet"
        aria-label="Back to More"
        data-role="files-back"
        class="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-subtle focus-visible-ring lg:hidden"
      >
        <.icon name="hero-chevron-left" class="size-[22px]" />
      </button>
      <h1
        data-role="files-title"
        class="min-w-0 flex-1 truncate text-[17px] font-semibold text-base-content"
      >
        {header_title(@browser)}
      </h1>
      <.link
        :if={@browser.mode != :search}
        patch={BrowserView.browser_path(%{"q" => ""}, %{"type" => @browser.params["type"]})}
        aria-label="Search files and canvases"
        data-role="files-search-open"
        class="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-base-content active:bg-base-100 focus-visible-ring"
      >
        <.icon name="hero-magnifying-glass" class="size-5" />
      </.link>
      <div class="relative shrink-0">
        <button
          type="button"
          phx-click="toggle_new_sheet"
          aria-label="New"
          aria-haspopup="dialog"
          aria-expanded={to_string(@new_open)}
          data-role="files-new"
          class="btn btn-primary btn-circle size-11 min-h-11 focus-visible-ring"
        >
          <.icon name="hero-plus" class="size-6" />
        </button>
        {render_slot(@new_panel)}
      </div>
    </header>
    """
  end

  defp header_title(%{mode: :browse, node: :all, type: type}) when not is_nil(type),
    do: type_word(type)

  defp header_title(%{mode: :starred}), do: "Starred"

  defp header_title(_browser), do: "Files"

  # ── Search ───────────────────────────────────────────────────────────────

  attr :browser, :map, required: true

  @doc "The search field (`?q=` mode). `phx-change` patches `q` after 300ms."
  def search_field(assigns) do
    ~H"""
    <form
      id="files-search-form"
      phx-change="browser_search"
      phx-submit="browser_search"
      data-role="files-search-form"
      class="mx-4 mb-2 flex h-10 shrink-0 items-center gap-2 rounded-field border border-edge bg-base-100 px-3"
    >
      <.icon name="hero-magnifying-glass" class="size-4 shrink-0 text-subtle" />
      <label for="files-search-input" class="sr-only">Search files and canvases</label>
      <input
        id="files-search-input"
        type="text"
        enterkeyhint="search"
        name="q"
        value={@browser.q}
        phx-debounce="300"
        phx-mounted={Phoenix.LiveView.JS.focus()}
        autocomplete="off"
        placeholder="Search files and canvases"
        data-role="files-search-input"
        class="min-w-0 flex-1 border-0 bg-transparent text-sm text-base-content outline-none"
      />
      <.link
        patch={BrowserView.browser_path(@browser.params, %{"q" => nil})}
        data-role="files-search-close"
        class="inline-flex h-10 shrink-0 items-center text-sm font-medium text-base-content focus-visible-ring"
      >
        Cancel
      </.link>
    </form>
    """
  end

  # ── New menu ─────────────────────────────────────────────────────────────

  attr :mode, :atom, required: true, doc: ":menu, :spaces or :projects"
  attr :browser, :map, required: true
  attr :tree, :map, required: true
  attr :labels, :map, required: true
  attr :desktop, :boolean, default: false

  @doc """
  The ＋ New items (stage 3), shared by the phone sheet and the desktop menu.
  `:menu` lists New canvas and Upload; `:spaces` and `:projects` are the
  pickers they open outside a space or project node. Every item is a
  `<button>` whose handler re-checks the id against the viewer's own tree.
  There is no New folder (D2) and no Game canvas (rung 21).
  """
  def new_menu(assigns) do
    assigns =
      assign(assigns,
        spaces: Enum.flat_map(assigns.tree.orgs, & &1.spaces) ++ assigns.tree.other.spaces,
        projects: Enum.flat_map(assigns.tree.orgs, & &1.projects) ++ assigns.tree.other.projects,
        in_project?: match?({:project, _}, assigns.browser.node)
      )

    ~H"""
    <div data-role="files-new-items" data-mode={@mode} class="flex flex-col">
      <%= case @mode do %>
        <% :spaces -> %>
          <.new_picker_head label="Choose a space" />
          <button
            :for={space <- @spaces}
            type="button"
            phx-click="new_canvas"
            phx-value-space-id={space.id}
            data-role="files-new-space"
            class={new_item_class()}
          >
            <.icon name="hero-hashtag" class="size-5 shrink-0 text-subtle" />
            <span class="min-w-0 truncate">
              {Map.get(@labels.spaces, space.id, @labels.unknown_space)}
            </span>
            <span class="ml-auto shrink-0 text-xs text-subtle">
              {if space.org_id,
                do: Map.get(@labels.orgs, space.org_id, @labels.unknown_org),
                else: @labels.other}
            </span>
          </button>
        <% :projects -> %>
          <.new_picker_head label="Upload to which project?" />
          <button
            :for={project <- @projects}
            type="button"
            phx-click="upload_to_project"
            phx-value-project-id={project.id}
            data-role="files-new-project"
            class={new_item_class()}
          >
            <.icon name="hero-folder" class="size-5 shrink-0 text-subtle" />
            <span class="min-w-0 truncate">
              {Map.get(@labels.projects, project.id, @labels.unknown_project)}
            </span>
          </button>
        <% _menu -> %>
          <button
            type="button"
            phx-click="new_canvas"
            data-role="files-new-canvas"
            class={new_item_class()}
          >
            <.icon name="hero-rectangle-group" class="size-5 shrink-0" /> New canvas
          </button>
          <button
            type="button"
            phx-click={
              if @desktop and @in_project?,
                do:
                  Phoenix.LiveView.JS.push("close_new_sheet")
                  |> Phoenix.LiveView.JS.dispatch("click",
                    to: "#files-upload-form input[type=file]"
                  ),
                else: "new_upload"
            }
            data-role="files-new-upload"
            class={new_item_class()}
          >
            <.icon name="hero-arrow-up-tray" class="size-5 shrink-0" /> Upload
          </button>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true

  defp new_picker_head(assigns) do
    ~H"""
    <div class="flex min-h-11 items-center gap-1 px-2">
      <button
        type="button"
        phx-click="new_sheet_back"
        aria-label="Back to New"
        data-role="files-new-back"
        class="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-subtle focus-visible-ring"
      >
        <.icon name="hero-chevron-left" class="size-5" />
      </button>
      <span class="text-sm font-semibold text-base-content">{@label}</span>
    </div>
    """
  end

  defp new_item_class,
    do:
      "flex min-h-11 w-full items-center gap-3 px-4 text-left text-sm text-base-content active:bg-base-200 focus-visible-ring"

  # ── Chips ────────────────────────────────────────────────────────────────

  attr :browser, :map, required: true
  attr :games, :boolean, required: true

  @doc """
  Recents / Browse, then the type chips All / Canvases / Games (only when the
  `game_stream` kind is registered) / Docs / Images. Scrolls sideways on phone.
  Selected chips are neutral: base-content on base-300 with border-edge.
  """
  def browser_chips(assigns) do
    assigns =
      assign(
        assigns,
        :types,
        [nil, :canvas] ++ if(assigns.games, do: [:game], else: []) ++ [:file, :doc, :image]
      )

    ~H"""
    <nav
      data-role="files-chips"
      aria-label="Files views"
      class="flex shrink-0 items-center gap-2 overflow-x-auto px-4 pb-2.5 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
    >
      <%= if @browser.mode != :search do %>
        <.chip
          href={BrowserView.browser_path(%{}, %{"type" => @browser.params["type"]})}
          selected={@browser.mode == :recents}
          role="files-tab-recents"
        >
          Recents
        </.chip>
        <.chip
          href={BrowserView.browser_path(%{"tab" => "browse"}, %{"type" => @browser.params["type"]})}
          selected={@browser.mode == :browse}
          role="files-tab-browse"
        >
          Browse
        </.chip>
        <.chip
          href={BrowserView.browser_path(%{"tab" => "starred"}, %{"type" => @browser.params["type"]})}
          selected={@browser.mode == :starred}
          role="files-tab-starred"
        >
          Starred
        </.chip>
        <span class="mx-1 h-5 w-px shrink-0 bg-edge" aria-hidden="true"></span>
      <% end %>
      <.chip
        :for={type <- @types}
        href={BrowserView.browser_path(@browser.params, %{"type" => type && Atom.to_string(type)})}
        selected={@browser.type == type}
        role="files-type-chip"
        chip={type || :all}
      >
        {if type, do: type_word(type), else: "All"}
      </.chip>
    </nav>
    """
  end

  attr :href, :string, required: true
  attr :selected, :boolean, default: false
  attr :role, :string, required: true
  attr :chip, :atom, default: nil
  slot :inner_block, required: true

  defp chip(assigns) do
    ~H"""
    <.link
      patch={@href}
      data-role={@role}
      data-chip={@chip}
      aria-current={if @selected, do: "page", else: "false"}
      class={
        [
          "inline-flex h-8 shrink-0 items-center whitespace-nowrap rounded-full border px-3 text-[13px] text-base-content focus-visible-ring",
          # Selected: base-300 fill, bold, and a --subtle border. border-edge
          # measured 1.34-1.68:1 against the base-200 list in 8 of 10 variants,
          # under the 3:1 non-text floor; --subtle clears it painted (stage 4,
          # files_browser_contrast_guard_test.exs).
          if(@selected,
            do: "bg-base-300 border-subtle font-semibold",
            else: "bg-base-100 border-edge active:bg-base-300"
          )
        ]
      }
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # ── Breadcrumbs ──────────────────────────────────────────────────────────

  attr :crumbs, :list, required: true, doc: "`[%{label, href | nil}]`, last is current"

  @doc "All > Org > Project|#space. The last crumb is `text-lg font-semibold`."
  def breadcrumbs(assigns) do
    ~H"""
    <nav
      data-role="files-breadcrumbs"
      aria-label="Location"
      class="flex min-w-0 shrink-0 items-center gap-1 px-4 pb-2"
    >
      <%= for {crumb, index} <- Enum.with_index(@crumbs) do %>
        <span
          :if={index > 0}
          class="shrink-0 text-sm text-subtle"
          aria-hidden="true"
        >
          ›
        </span>
        <%= if index == length(@crumbs) - 1 do %>
          <span
            data-role="files-crumb-current"
            aria-current="location"
            class="min-w-0 truncate text-lg font-semibold text-base-content"
          >
            {crumb.label}
          </span>
        <% else %>
          <.link
            patch={crumb.href}
            data-role="files-crumb"
            class="min-w-0 shrink truncate text-sm text-subtle focus-visible-ring"
          >
            {crumb.label}
          </.link>
        <% end %>
      <% end %>
    </nav>
    """
  end

  # ── Toolbar ──────────────────────────────────────────────────────────────

  attr :browser, :map, required: true
  attr :layout, :atom, required: true

  @doc "Count, the sort cycle (recent > name > type, prototype `fsort`) and list/grid."
  def toolbar(assigns) do
    ~H"""
    <div
      data-role="files-toolbar"
      class="flex shrink-0 items-center gap-2 px-4 pb-2 text-xs text-subtle"
    >
      <span data-role="files-count" class="min-w-0 flex-1 truncate">
        {count_text(@browser)}
      </span>
      <.link
        :if={@browser.mode != :starred}
        patch={BrowserView.browser_path(@browser.params, %{"sort" => next_sort(@browser.sort)})}
        data-role="files-sort"
        data-sort={@browser.sort}
        aria-label={"Sorted by #{sort_word(@browser.sort)}. Change sort"}
        class="inline-flex h-11 shrink-0 items-center gap-1 rounded-field px-2 text-xs font-medium text-base-content active:bg-base-100 focus-visible-ring"
      >
        <.icon name="hero-arrows-up-down" class="size-4" />
        {sort_word(@browser.sort)}
      </.link>
      <button
        type="button"
        phx-click="set_layout"
        phx-value-layout={if @layout == :grid, do: "list", else: "grid"}
        aria-pressed={to_string(@layout == :grid)}
        aria-label="Show as grid"
        data-role="files-layout-toggle"
        data-layout={@layout}
        class="inline-flex size-11 shrink-0 items-center justify-center rounded-field text-base-content active:bg-base-100 focus-visible-ring"
      >
        <.icon name="hero-squares-2x2" class="size-5" />
      </button>
    </div>
    """
  end

  defp count_text(%{items: items, nodes: nodes}) when items == [] and nodes != [],
    do: noun_count(length(nodes), "place")

  defp count_text(%{items: items}), do: noun_count(length(items), "item")

  defp noun_count(1, noun), do: "1 #{noun}"
  defp noun_count(n, noun), do: "#{n} #{noun}s"

  @doc false
  def next_sort(:recent), do: "name"
  def next_sort(:name), do: "type"
  def next_sort(_type), do: "recent"

  defp sort_word(:recent), do: "Recent"
  defp sort_word(:name), do: "Name"
  defp sort_word(:type), do: "Type"

  # ── Nodes (All and org levels) ───────────────────────────────────────────

  attr :nodes, :list, required: true, doc: "`[%{kind, id, href, label}]`"

  @doc "The child nodes of All or an org: orgs, projects and spaces, as plain patch links."
  def node_list(assigns) do
    ~H"""
    <ul data-role="files-node-list" class="flex flex-col">
      <li :for={node <- @nodes} data-role="files-node" data-node-kind={node.kind}>
        <.link
          patch={node.href}
          data-role="files-node-link"
          class="flex min-h-14 items-center gap-3 px-4 py-2 active:bg-base-100 focus-visible-ring"
        >
          <span class="inline-flex size-11 shrink-0 items-center justify-center rounded-box border border-edge bg-base-200 text-base-content">
            <.icon name={node_icon(node.kind)} class="size-5" />
          </span>
          <span class="min-w-0 flex-1 truncate text-sm font-medium text-base-content">
            {node.label}
          </span>
          <.icon name="hero-chevron-right" class="size-4 shrink-0 text-subtle" />
        </.link>
      </li>
    </ul>
    """
  end

  defp node_icon(:org), do: "hero-building-office-2"
  defp node_icon(:other), do: "hero-chat-bubble-left-right"
  defp node_icon(:project), do: "hero-folder"
  defp node_icon(:space), do: "hero-hashtag"

  # ── List ─────────────────────────────────────────────────────────────────

  attr :browser, :map,
    required: true,
    doc: "`@browser`: its items, and its params for the `from` a game link carries"

  attr :labels, :map, required: true
  attr :show_location, :boolean, required: true
  attr :file_rows, :map, default: %{}, doc: "file_id => %Files.File{} in a project node"
  attr :claims, :map, default: %{}

  @doc "The list layout (default)."
  attr :viewer, :map, default: %{}
  attr :editing, :any, default: nil
  attr :revision, :integer, default: 0

  def item_list(assigns) do
    assigns = assign_from(assigns)

    ~H"""
    <ul data-role="files-list" class="flex flex-col gap-1.5">
      <li
        :for={item <- @browser.items}
        data-role={if Map.has_key?(@file_rows, item.id), do: "files-row", else: "browser-row"}
        id={"browser-" <> Atom.to_string(item.kind) <> "-" <> item.id}
        phx-hook="BrowserRow"
        data-long-press-event="browser_open_actions"
        data-long-press-kind={item.kind}
        data-long-press-id={item.id}
        data-editing={to_string(@editing == {item.kind, item.id})}
        data-item-id={item.id}
        data-kind={item.kind}
        data-type={item.type}
        data-file-id={if item.kind == :file, do: item.id}
        data-ingest-status={file_attr(@file_rows, item, :ingest_status)}
        data-ingest-intent={file_attr(@file_rows, item, :ingest_intent)}
        data-location={to_string(@show_location)}
        data-row-grid
        class="group relative grid grid-cols-[2.75rem_minmax(0,1fr)_auto] grid-rows-[1fr_1fr] gap-x-3 px-4 py-2 active:bg-base-100 data-[location=false]:grid-rows-[1fr_0]"
      >
        <%!-- Prototype v3 :641-646: the title and the location line sit
             BESIDE the 44px tile, inside its height (row 60px). The item
             link is a subgrid over the tile column and the text column; the
             location link is its SIBLING in row 2 of the text column, never
             nested inside it. --%>
        <.item_link
          item={item}
          from={@from}
          class="col-start-1 col-end-3 row-start-1 row-end-3 grid grid-cols-subgrid grid-rows-subgrid focus-visible-ring"
        >
          <span class="row-start-1 row-end-3 flex self-center" data-role="files-row-tile">
            <.thumb item={item} />
          </span>
          <span
            :if={@editing != {item.kind, item.id}}
            class="min-w-0 flex-1 truncate lg:pr-16 text-[15px] font-semibold text-base-content col-start-2 row-start-1 self-end group-data-[location=false]:self-center"
          >
            {title(item)}
          </span>
        </.item_link>
        <PlatformWeb.Files.ItemActions.title_field
          :if={@editing == {item.kind, item.id}}
          item={item}
          class="col-start-2 row-start-1 relative z-20"
        />
        <PlatformWeb.Files.ItemActions.affordances item={item} viewer={@viewer} revision={@revision} />
        <%= if file = Map.get(@file_rows, item.id) do %>
          <span
            class={[
              FilesLive.status_badge_class(file.ingest_status),
              "col-start-3 row-start-1 row-end-3 shrink-0 self-center"
            ]}
            data-role="files-status-badge"
          >
            {FilesLive.status_label(file.ingest_status)}
          </span>
        <% end %>
        <.location_line
          :if={@show_location}
          item={item}
          labels={@labels}
          class="pointer-events-none relative z-10 col-start-2 col-end-4 row-start-2 self-start [&_a]:pointer-events-auto"
        >
          <span
            :if={item.type == :game}
            data-role="browser-game-meta"
            class="shrink-0 whitespace-nowrap"
          >
            {game_meta(item)}
          </span>
        </.location_line>
        <div
          :if={Map.has_key?(@claims, item.id)}
          class="col-start-2 col-end-4 pt-1"
        >
          <PlatformWeb.Components.SupersessionRuling.supersession_badge claim={
            Map.get(@claims, item.id)
          } />
        </div>
        <div :if={failed_file(@file_rows, item)} class="col-start-1 col-end-4 -mx-4 pt-2">
          <.failure_strip file={failed_file(@file_rows, item)} />
        </div>
      </li>
    </ul>
    """
  end

  defp file_attr(file_rows, item, field) do
    case Map.get(file_rows, item.id) do
      nil -> nil
      file -> Map.get(file, field)
    end
  end

  defp failed_file(file_rows, item) do
    case Map.get(file_rows, item.id) do
      %{ingest_status: "failed"} = file -> file
      _ -> nil
    end
  end

  attr :file, :map, required: true

  # The failure reason strip (task 01a0166d stage 4), unchanged in content:
  # TEXT on the row, never a tooltip or `title=`, the stage prefix never
  # truncates, the machine tail does, and the sweep-skipped clause is
  # appended rather than replacing the reason. No control inside it: the
  # unbounded retry is the detail pane's `files-detail-retry`.
  defp failure_strip(assigns) do
    ~H"""
    <div
      data-role="files-row-failure-reason"
      data-file-id={@file.id}
      class="mx-4 mb-2 flex flex-wrap items-baseline gap-x-2 gap-y-1 border-l-[3px] border-error bg-base-100 px-3 py-1.5"
    >
      <span class="shrink-0 whitespace-nowrap text-xs font-medium text-base-content">
        {FilesLive.failure_stage_label(@file.ingest_failure_stage)}:
      </span>
      <span class="min-w-0 truncate font-mono text-xs text-base-content">
        {FilesLive.failure_detail_text(@file.ingest_failure_detail)}
      </span>
      <span
        :if={FilesLive.sweep_skipped?(@file)}
        class="shrink-0 whitespace-nowrap font-mono text-xs text-base-content"
        data-role="files-row-sweep-skipped"
      >
        · {FilesLive.sweep_skipped_clause()}
      </span>
    </div>
    """
  end

  # ── Grid ─────────────────────────────────────────────────────────────────

  attr :browser, :map,
    required: true,
    doc: "`@browser`: its items, and its params for the `from` a game link carries"

  attr :labels, :map, required: true
  attr :show_location, :boolean, required: true

  @doc "The grid layout: base-100 tiles with border-edge, a thumbnail or the glyph."
  attr :viewer, :map, default: %{}
  attr :editing, :any, default: nil
  attr :revision, :integer, default: 0

  def item_grid(assigns) do
    assigns = assign_from(assigns)

    ~H"""
    <ul
      data-role="files-grid"
      class="grid grid-cols-2 gap-3 px-4 py-2 sm:grid-cols-3 xl:grid-cols-4"
    >
      <li
        :for={item <- @browser.items}
        data-role="browser-tile"
        id={"browser-" <> Atom.to_string(item.kind) <> "-" <> item.id}
        phx-hook="BrowserRow"
        data-long-press-event="browser_open_actions"
        data-long-press-kind={item.kind}
        data-long-press-id={item.id}
        data-editing={to_string(@editing == {item.kind, item.id})}
        data-item-id={item.id}
        data-kind={item.kind}
        data-type={item.type}
        class="group relative flex min-w-0 flex-col overflow-hidden rounded-box border border-edge bg-base-100"
      >
        <.item_link
          item={item}
          from={@from}
          class="flex min-w-0 flex-col active:bg-base-200 focus-visible-ring"
        >
          <.game_thumb :if={item.type == :game} item={item} />
          <span
            :if={item.type != :game}
            class="flex aspect-[4/3] w-full items-center justify-center overflow-hidden bg-base-200 text-base-content"
          >
            <img
              :if={item.thumb_src}
              src={item.thumb_src}
              alt=""
              loading="lazy"
              class="size-full object-cover"
            />
            <.icon :if={!item.thumb_src} name={type_icon(item.type)} class="size-8" />
          </span>
          <span
            :if={@editing != {item.kind, item.id}}
            class="line-clamp-2 px-3 pt-2 lg:pr-16 text-[15px] font-semibold text-base-content"
          >
            {title(item)}
          </span>
        </.item_link>
        <PlatformWeb.Files.ItemActions.title_field
          :if={@editing == {item.kind, item.id}}
          item={item}
          class="relative z-20 px-3 pt-2"
        />
        <PlatformWeb.Files.ItemActions.affordances item={item} viewer={@viewer} revision={@revision} />
        <%!-- Tiles show the copy marker always, and author and age as
             width allows, on a second line under the location (stage 5). --%>
        <.location_line
          :if={@show_location}
          item={item}
          labels={@labels}
          compact
          class="flex-wrap px-3 pb-2"
        />
        <span :if={!@show_location} class="pb-2"></span>
      </li>
    </ul>
    """
  end

  # ── Shared row parts ─────────────────────────────────────────────────────

  attr :item, Item, required: true
  attr :class, :string, default: nil
  attr :from, :string, default: nil
  slot :inner_block, required: true

  # The item link. A project file patches (same LiveView), a canvas
  # navigates (another live session), a space file is a plain href.
  defp item_link(%{item: %Item{kind: :file}} = assigns) do
    ~H"""
    <.link patch={@item.href} data-role="files-item-link" data-item-id={@item.id} class={@class}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp item_link(%{item: %Item{kind: :canvas}} = assigns) do
    assigns = assign(assigns, :to, canvas_link(assigns.item.href, assigns.from))

    ~H"""
    <.link navigate={@to} data-role="files-item-link" data-item-id={@item.id} class={@class}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  defp item_link(assigns) do
    ~H"""
    <.link href={@item.href} data-role="files-item-link" data-item-id={@item.id} class={@class}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :item, Item, required: true

  # 44px tile: an image's real thumbnail, else the type glyph. Never a fake
  # preview (Saru `rules`).
  defp thumb(%{item: %Item{type: :game}} = assigns) do
    ~H"""
    <span
      data-role="browser-game-icon"
      class="browser-icon-game inline-flex size-11 shrink-0 items-center justify-center rounded-box border border-edge overflow-hidden text-on-viewer"
    >
      <.icon name="hero-puzzle-piece" class="size-5" />
    </span>
    """
  end

  defp thumb(assigns) do
    ~H"""
    <span class="inline-flex size-11 shrink-0 items-center justify-center overflow-hidden rounded-box border border-edge bg-base-200 text-base-content">
      <img
        :if={@item.thumb_src}
        src={@item.thumb_src}
        alt=""
        loading="lazy"
        data-role="files-thumb"
        class="size-full object-cover"
      />
      <.icon :if={!@item.thumb_src} name={type_icon(@item.type)} class="size-5" />
    </span>
    """
  end

  attr :item, Item, required: true
  attr :labels, :map, required: true
  attr :class, :string, default: nil
  attr :compact, :boolean, default: false
  slot :inner_block, doc: "a prefix rendered before the location (a game's build and state)"

  # 'Org > Project' or 'Org > #space', then ' · copy', ' · author', ' · age'
  # and ' · Not shared with agents'. The location keeps at least 5rem and
  # shrinks first (org before place); then the author truncates (stage 5: a
  # long author pushed the age off the row); the copy marker and the age
  # never shrink; the agents note truncates first of all. The line never
  # scrolls sideways. `compact` (grid tiles) puts the copy marker, author
  # and age on a second line under the location (stage 5): a clone pair
  # stays distinguishable in grid.
  defp location_line(assigns) do
    assigns =
      assign(assigns,
        org: org_label(assigns.labels, assigns.item),
        place: place_label(assigns.labels, assigns.item)
      )

    ~H"""
    <div class={["flex min-w-0 items-baseline gap-1 overflow-hidden text-xs text-subtle", @class]}>
      {render_slot(@inner_block)}
      <.link
        patch={@item.location_href}
        data-role="files-location-link"
        class="flex min-w-[5rem] shrink-[3] items-baseline gap-1 focus-visible-ring"
      >
        <span data-role="files-location-org" class="min-w-0 shrink-[2] truncate">{@org}</span>
        <span aria-hidden="true" class="shrink-0">›</span>
        <span data-role="files-location-place" class="min-w-0 shrink truncate">{@place}</span>
      </.link>
      <span
        data-role="files-meta"
        class={[
          "flex min-w-0 items-baseline gap-1",
          if(@compact, do: "w-full overflow-hidden", else: "contents")
        ]}
      >
        <span :if={@item.cloned?} class="shrink-0" data-role="files-copy-marker">
          {if @compact, do: "copy", else: "· copy"}
        </span>
        <span
          :if={@item.author}
          class={if @compact, do: "min-w-0 truncate", else: "min-w-[2rem] truncate"}
        >
          {if @compact and not @item.cloned?, do: @item.author, else: "· #{@item.author}"}
        </span>
        <span :if={@item.at} class="shrink-0">
          {if @compact and not @item.cloned? and is_nil(@item.author), do: "", else: "· "}{ChatHelpers.relative_time(
            @item.at
          )}
        </span>
        <span
          :if={!@compact && @item.human_only?}
          class="min-w-0 truncate"
          data-role="files-not-shared"
        >
          · Not shared with agents
        </span>
      </span>
    </div>
    """
  end

  @doc "The masked org label for an item."
  def org_label(labels, %Item{org_id: nil}), do: labels.other

  def org_label(labels, %Item{org_id: org_id}),
    do: Map.get(labels.orgs, org_id, labels.unknown_org)

  @doc "The masked project or space label for an item."
  def place_label(labels, %Item{project_id: pid}) when is_binary(pid),
    do: Map.get(labels.projects, pid, labels.unknown_project)

  def place_label(labels, %Item{space_id: sid}) when is_binary(sid),
    do: Map.get(labels.spaces, sid, labels.unknown_space)

  def place_label(_labels, _item), do: ""

  defp title(%Item{title: title}) when is_binary(title) and title != "", do: title
  defp title(_item), do: "Untitled"

  # Masters `.frow .tx small` (:1221): "build {sha7} · {state} · " before the
  # location; the build part is absent when the node has no review_sha.
  defp game_meta(%Item{build: build, game_state: state}) do
    if(build, do: "build #{build} · ", else: "") <> "#{state} ·"
  end

  # The current browser URL. A game link into the Game view carries it as
  # `from`, so the view's Back returns to exactly this list.
  defp assign_from(assigns),
    do: assign(assigns, :from, BrowserView.browser_path(assigns.browser.params, %{}))

  # A game link into the Game view appends that URL, encoded.
  defp canvas_link("/m/games?" <> _ = href, from) when is_binary(from),
    do: href <> "&from=" <> URI.encode_www_form(from)

  defp canvas_link(href, _from), do: href

  attr :item, Item, required: true

  # Masters `.fcard.game .th` (:432-443): the stage-to-teal thumb, a centred
  # puzzle-piece glyph, the state tag bottom-left and the build tag
  # bottom-right. No star (rung 16 shipped no Starred) and no still (none is
  # stored).
  defp game_thumb(assigns) do
    ~H"""
    <span
      data-role="browser-game-thumb"
      class="browser-thumb-game relative flex aspect-[4/3] w-full items-center justify-center overflow-hidden text-on-viewer"
    >
      <.icon name="hero-puzzle-piece" class="size-10 text-on-viewer" />
      <%!-- State tag bottom-left as in the masters. The build tag sits
           TOP-right, not bottom-right: "build" plus a sha7 is wider than
           the masters' "build 0.4.2", and on a two-column phone tile the
           two tags cannot share the bottom edge without overlapping. --%>
      <span
        data-role="browser-game-state"
        data-state={@item.game_state}
        class={[
          "absolute bottom-2 left-2 rounded-full px-[7px] py-0.5 text-xs font-bold tracking-[.05em]",
          if(@item.game_state == :playable,
            do: "bg-success text-success-content",
            else: "bg-shade text-on-viewer"
          )
        ]}
      >
        {@item.game_state}
      </span>
      <span
        :if={@item.build}
        data-role="browser-game-build"
        class="absolute right-2 top-2 rounded-full bg-shade px-[7px] py-0.5 text-xs font-bold tracking-[.05em] text-on-viewer"
      >
        build {@item.build}
      </span>
    </span>
    """
  end

  # ── Desktop tree ─────────────────────────────────────────────────────────

  attr :tree, :map, required: true
  attr :labels, :map, required: true
  attr :collapsed, :any, required: true, doc: "MapSet of collapsed org ids"
  attr :browser, :map, required: true

  @doc """
  Desktop (lg+) tree: Recents, then each org expandable to its projects and
  spaces, then Other spaces. Expand state is per-LiveView, never persisted.
  """
  def tree_sidebar(assigns) do
    ~H"""
    <aside
      data-role="files-tree"
      aria-label="Files and canvases"
      class="hidden w-64 shrink-0 flex-col overflow-y-auto border-r border-edge bg-base-100 lg:flex"
    >
      <.link
        patch={~p"/files"}
        data-role="files-tree-recents"
        aria-current={if @browser.mode == :recents, do: "page", else: "false"}
        class={[
          "mx-2 mt-3 flex min-h-11 items-center gap-2 rounded-field px-3 text-sm text-base-content focus-visible-ring",
          if(@browser.mode == :recents, do: "bg-base-300 font-semibold", else: "active:bg-base-200")
        ]}
      >
        <.icon name="hero-clock" class="size-4" /> Recents
      </.link>
      <.link
        patch="/files?tab=starred"
        data-role="files-tree-starred"
        aria-current={if @browser.mode == :starred, do: "page", else: "false"}
        class={[
          "mx-2 flex min-h-11 items-center gap-2 rounded-field px-3 text-sm text-base-content focus-visible-ring",
          if(@browser.mode == :starred, do: "bg-base-300 font-semibold", else: "active:bg-base-200")
        ]}
      >
        <.icon name="hero-star" class="size-4" /> Starred
      </.link>
      <div
        :for={%{org: org, projects: projects, spaces: spaces} <- @tree.orgs}
        data-role="files-tree-org"
        data-org-slug={org.slug}
        data-org-id={org.id}
        class="mt-2"
      >
        <div class="flex items-center">
          <button
            type="button"
            phx-click="toggle_tree_org"
            phx-value-id={org.id}
            aria-expanded={to_string(!MapSet.member?(@collapsed, org.id))}
            aria-label="Show or hide this workspace's projects and spaces"
            class="inline-flex size-11 shrink-0 items-center justify-center text-subtle focus-visible-ring"
          >
            <.icon
              name={
                if MapSet.member?(@collapsed, org.id),
                  do: "hero-chevron-right",
                  else: "hero-chevron-down"
              }
              class="size-4"
            />
          </button>
          <.link
            patch={BrowserView.browser_path(%{"tab" => "browse", "org" => org.id}, %{})}
            data-role="files-tree-org-link"
            class="min-w-0 flex-1 truncate py-2 pr-3 text-xs font-semibold uppercase tracking-widest text-base-content focus-visible-ring"
          >
            {Map.get(@labels.orgs, org.id, @labels.unknown_org)}
          </.link>
        </div>
        <ul :if={!MapSet.member?(@collapsed, org.id)} class="flex flex-col">
          <li :for={project <- projects}>
            <.tree_leaf
              href={~p"/files/#{project.id}"}
              icon="hero-folder"
              label={Map.get(@labels.projects, project.id, @labels.unknown_project)}
              current={match?({:project, %{id: id}} when id == project.id, @browser.node)}
              role="files-tree-project"
              id={project.id}
            />
          </li>
          <li :for={space <- spaces}>
            <.tree_leaf
              href={BrowserView.browser_path(%{"space" => space.id}, %{})}
              icon="hero-hashtag"
              label={Map.get(@labels.spaces, space.id, @labels.unknown_space)}
              current={match?({:space, %{id: id}} when id == space.id, @browser.node)}
              role="files-tree-space"
              id={space.id}
            />
          </li>
        </ul>
      </div>
      <div
        :if={@tree.other.spaces != [] or @tree.other.projects != []}
        data-role="files-tree-other"
        class="mt-2 pb-4"
      >
        <.link
          patch={BrowserView.browser_path(%{"tab" => "browse", "org" => "other"}, %{})}
          class="block truncate px-5 py-2 text-xs font-semibold uppercase tracking-widest text-base-content focus-visible-ring"
        >
          {@labels.other}
        </.link>
        <ul class="flex flex-col">
          <li :for={project <- @tree.other.projects}>
            <.tree_leaf
              href={~p"/files/#{project.id}"}
              icon="hero-folder"
              label={Map.get(@labels.projects, project.id, @labels.unknown_project)}
              current={match?({:project, %{id: id}} when id == project.id, @browser.node)}
              role="files-tree-project"
              id={project.id}
            />
          </li>
          <li :for={space <- @tree.other.spaces}>
            <.tree_leaf
              href={BrowserView.browser_path(%{"space" => space.id}, %{})}
              icon="hero-hashtag"
              label={Map.get(@labels.spaces, space.id, @labels.unknown_space)}
              current={match?({:space, %{id: id}} when id == space.id, @browser.node)}
              role="files-tree-space"
              id={space.id}
            />
          </li>
        </ul>
      </div>
    </aside>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :current, :boolean, default: false
  attr :role, :string, required: true
  attr :id, :string, required: true

  defp tree_leaf(assigns) do
    ~H"""
    <.link
      patch={@href}
      data-role={@role}
      data-node-id={@id}
      aria-current={if @current, do: "page", else: "false"}
      class={[
        "mx-2 flex min-h-10 items-center gap-2 rounded-field pl-9 pr-3 text-sm text-base-content focus-visible-ring",
        if(@current, do: "bg-base-300 font-semibold", else: "active:bg-base-200")
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0 text-subtle" />
      <span class="min-w-0 truncate">{@label}</span>
    </.link>
    """
  end

  # ── Empty states ─────────────────────────────────────────────────────────

  attr :browser, :map, required: true
  attr :labels, :map, required: true

  @doc "Saru's empty copy (D3, D4), naming the node through the mask."
  def empty_state(assigns) do
    assigns = assign(assigns, :copy, empty_copy(assigns.browser, assigns.labels))

    ~H"""
    <div
      data-role="files-browser-empty"
      class="flex min-h-[40vh] flex-col items-center justify-center px-6 text-center"
    >
      <.icon :if={@browser.mode != :starred} name="hero-folder-open" class="size-10 text-subtle" />
      <p class="mt-3 max-w-md text-sm text-subtle">{@copy}</p>
    </div>
    """
  end

  @doc false
  def empty_copy(%{mode: :starred}, _labels), do: "Star canvases and files to keep them here."

  def empty_copy(%{mode: :search, q: q}, _labels),
    do: ~s(Nothing matches "#{q}". Searched project file names and canvas titles and text.)

  def empty_copy(%{mode: :recents, type: nil}, _labels), do: "Nothing changed in the last 3 days"

  def empty_copy(%{mode: :recents, type: type}, _labels),
    do: "No #{Map.fetch!(@type_singular, type)} changed in the last 3 days"

  def empty_copy(%{type: type, node: node}, labels) when not is_nil(type),
    do: "No #{Map.fetch!(@type_singular, type)} in #{node_name(node, labels)}"

  def empty_copy(_browser, _labels), do: "No files or canvases here"

  defp node_name({:project, project}, labels),
    do: Map.get(labels.projects, project.id, labels.unknown_project)

  defp node_name({:space, space}, labels),
    do: Map.get(labels.spaces, space.id, labels.unknown_space)

  defp node_name({:org, org}, labels), do: Map.get(labels.orgs, org.id, labels.unknown_org)
  defp node_name(:other, labels), do: labels.other
  defp node_name(_all, _labels), do: "your workspaces"

  attr :browser, :map, required: true

  @doc "A capped list ends with 'Showing the newest N'."
  def capped_note(assigns) do
    ~H"""
    <p
      :if={@browser.capped?}
      data-role="files-capped"
      class="px-4 py-3 text-center text-xs text-subtle"
    >
      Showing the newest {length(@browser.items)}
    </p>
    """
  end
end
