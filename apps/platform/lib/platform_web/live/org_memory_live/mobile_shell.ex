defmodule PlatformWeb.OrgMemoryLive.MobileShell do
  @moduledoc """
  Mobile (`lg:hidden`) shell for the Org Memory wiki (task 019f9282).

  The desktop three-pane grid in `PlatformWeb.OrgMemoryLive.render/1`
  stays untouched behind `hidden lg:grid`; this module is the sibling
  `lg:hidden` branch — a single flex column:

    * **App-bar** (`~h-11`) — a left menu icon (`open_tree_drawer`) and a
      right contextual icon (Pages tab → `show_create`). No module title;
      the segmented control below is the identity.
    * **Segmented tabs** — Pages / Journal / Search / Proposals, reusing
      the parent's `switch_tab` / `phx-value-tab` events + `@view_mode`.
      Active `btn-primary`, inactive `btn-ghost`, each ≥44px. Proposals
      carries the pending-count `badge-warning`.
    * **Scroll body** — one `overflow-y-auto` column whose bottom clears
      the app-wide bottom nav via `--bottom-nav-height`.

  Stateless — all state lives on `PlatformWeb.OrgMemoryLive`.

  The mobile branch renders in the SAME DOM as the desktop grid (CSS
  `lg:hidden` / `hidden lg:grid` toggle visibility, not presence), so it
  MUST NOT reuse the desktop pane components verbatim: their hard-coded
  element ids (`org-memory-journal-form`, `org-memory-proposals-table`,
  `org-memory-editor`, …) would appear twice and duplicate ids are
  undefined behavior in LiveView. Stage 1 therefore renders a read-only
  mobile Pages viewer plus id-safe section landings for Journal / Search
  / Proposals; later stages (3–5) replace those landings with the
  mobile-specific composer / cards / search-facet renders (each with
  mobile-scoped ids).

  Design source of truth: mockup canvas rev 6 "Org Memory — mobile
  mockup v3 · Suite tokens". Tokens only (base-100/200/300, primary,
  warning-yellow for unread/pending only); Hero icons, no emojis.
  """

  use Phoenix.Component

  import PlatformWeb.Components.Sheet, only: [sheet: 1]
  import PlatformWeb.CoreComponents, only: [icon: 1]
  import PlatformWeb.OrgMemoryLive.NamespaceTree, only: [file_icon: 1]

  alias Phoenix.LiveView.JS
  alias Platform.Memory.Proposals
  alias PlatformWeb.OrgMemoryLive.NamespaceTree

  @tabs [
    {"pages", "Pages"},
    {"journal", "Journal"},
    {"search", "Search"},
    {"proposals", "Proposals"}
  ]

  # ── Chrome ────────────────────────────────────────────────────────────
  attr(:view_mode, :atom, required: true)
  attr(:proposals_pending_count, :integer, default: 0)
  attr(:tree_drawer_open, :boolean, default: false)

  # ── Namespace tree (drawer + path chip) ─────────────────────────────────
  attr(:namespace_tree, :map, default: %{folders: %{}, pages: []})
  attr(:expanded_prefixes, :any, default: nil)

  # ── Pages tab ─────────────────────────────────────────────────────────
  attr(:creating, :boolean, default: false)
  attr(:page, :any, default: nil, doc: "selected Platform.Org.WikiPage or nil")
  attr(:preview_html, :string, default: "")
  attr(:editing, :boolean, default: false)
  attr(:editor_content, :string, default: "")
  attr(:save_error, :string, default: nil)
  attr(:confirm_delete, :string, default: nil)
  attr(:backlinks, :list, default: [])
  attr(:updated_by_display, :string, default: nil)

  # ── Journal tab ───────────────────────────────────────────────────────
  attr(:journal_groups, :list, default: [])
  attr(:journal_namespace, :string, default: "org")
  attr(:journal_draft, :string, default: "")
  attr(:journal_focus_date, :any, default: nil)

  # ── Search tab ────────────────────────────────────────────────────────
  attr(:search_query, :string, default: "")
  attr(:search_corpus, :string, default: "all")
  attr(:search_namespace, :string, default: "all")
  attr(:namespaces, :list, default: [])
  attr(:search_results, :list, default: [])
  attr(:search_performed, :boolean, default: false)
  attr(:search_truncated, :boolean, default: false)
  attr(:search_error, :string, default: nil)

  # ── Proposals tab ─────────────────────────────────────────────────────
  attr(:proposals, :list, default: [])
  attr(:show_reject_form_for, :any, default: nil)
  attr(:expanded_diffs, :any, default: nil)

  slot(:create_panel, doc: "desktop create panel, rendered on the Pages tab when @creating")

  def mobile_shell(assigns) do
    assigns = assign(assigns, :tabs, @tabs)

    ~H"""
    <div class="flex h-full flex-col overflow-hidden lg:hidden" data-role="mobile-shell">
      <%!-- Slim app-bar: menu left, contextual icon right, no title --%>
      <div
        class="flex h-11 shrink-0 items-center justify-between border-b border-edge bg-base-200/40 px-1"
        data-role="mobile-app-bar"
      >
        <button
          phx-click="open_tree_drawer"
          class="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-base-content/70 transition-colors hover:bg-base-300"
          aria-label="Open namespace tree"
          data-role="mobile-menu-button"
        >
          <.icon name="hero-bars-3" class="size-5" />
        </button>
        <button
          :if={@view_mode == :pages}
          phx-click="show_create"
          class="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-base-content/70 transition-colors hover:bg-base-300"
          aria-label="New page"
          data-role="mobile-app-bar-action"
        >
          <.icon name="hero-plus" class="size-5" />
        </button>
      </div>

      <%!-- Segmented section switcher --%>
      <div
        class="flex shrink-0 items-center gap-1 border-b border-edge bg-base-200/40 px-2 py-2"
        role="tablist"
        data-role="mobile-tabs"
      >
        <button
          :for={{tab, label} <- @tabs}
          phx-click="switch_tab"
          phx-value-tab={tab}
          data-mobile-tab={tab}
          role="tab"
          aria-selected={to_string(Atom.to_string(@view_mode) == tab)}
          class={[
            "btn min-h-11 flex-1 gap-1.5 border-none",
            if(Atom.to_string(@view_mode) == tab, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          {label}
          <span
            :if={tab == "proposals" and @proposals_pending_count > 0}
            class="badge badge-warning badge-sm"
            data-role="mobile-proposals-count"
          >
            {@proposals_pending_count}
          </span>
        </button>
      </div>

      <%!-- Namespace path chip — the signature breadcrumb. JetBrains Mono,
           horizontal-scroll; tapping any segment (or the chip) opens the
           tree drawer. Present on Pages / Journal / Proposals; ABSENT on
           Search (which swaps in the search input + facets in stage 5). --%>
      <div
        :if={@view_mode in [:pages, :journal, :proposals]}
        class="flex shrink-0 items-stretch overflow-x-auto border-b border-edge bg-base-100 px-2 font-mono text-sm"
        data-role="mobile-path-chip"
      >
        <button
          :for={{seg, idx} <- Enum.with_index(path_segments(@page, @journal_namespace))}
          phx-click="open_tree_drawer"
          data-chip-segment={seg}
          class="flex min-h-11 shrink-0 items-center gap-1 whitespace-nowrap px-1.5 text-base-content/60 transition-colors hover:text-base-content"
        >
          <span :if={idx > 0} class="hero-chevron-right size-3 shrink-0 text-base-content/30"></span>
          <span class={idx == last_index(@page, @journal_namespace) && "text-primary"}>{seg}</span>
        </button>
      </div>

      <%!-- Single scroll body, clearing the app-wide bottom nav --%>
      <div
        class="flex min-h-0 flex-1 flex-col overflow-y-auto pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px))]"
        data-role="mobile-body"
      >
        <%= case @view_mode do %>
          <% :pages -> %>
            <%= if @creating do %>
              {render_slot(@create_panel)}
            <% else %>
              <.mobile_pages_viewer
                page={@page}
                preview_html={@preview_html}
                editing={@editing}
                editor_content={@editor_content}
                save_error={@save_error}
                confirm_delete={@confirm_delete}
                backlinks={@backlinks}
                updated_by_display={@updated_by_display}
              />
            <% end %>
          <% :journal -> %>
            <.mobile_journal
              groups={@journal_groups}
              draft={@journal_draft}
              namespace={@journal_namespace}
              focus_date={@journal_focus_date}
            />
          <% :search -> %>
            <.mobile_search
              query={@search_query}
              corpus={@search_corpus}
              namespace={@search_namespace}
              namespaces={@namespaces}
              results={@search_results}
              performed={@search_performed}
              truncated={@search_truncated}
              error={@search_error}
            />
          <% :proposals -> %>
            <.mobile_proposals
              proposals={@proposals}
              show_reject_form_for={@show_reject_form_for}
              expanded_diffs={@expanded_diffs}
            />
        <% end %>
      </div>

      <%!-- Slide-out namespace tree drawer — reuses the desktop
           NamespaceTree via the shared Sheet component (backdrop-tap +
           Esc + focus management come from the Sheet hook). Selecting a
           leaf closes the drawer (parent `select_page` assigns
           `:tree_drawer_open` false). `lg:hidden` keeps it off desktop. --%>
      <.sheet
        id="org-memory-tree-drawer"
        placement={:left}
        class="lg:hidden"
        open={@tree_drawer_open}
        on_close="close_tree_drawer"
      >
        <:title>Pages</:title>
        <NamespaceTree.namespace_tree
          tree={@namespace_tree}
          expanded_prefixes={@expanded_prefixes}
          selected_file_key={@page && @page.file_key}
        />
      </.sheet>
    </div>
    """
  end

  # ── Pages viewer (mobile) ───────────────────────────────────────────────

  attr(:page, :any, default: nil)
  attr(:preview_html, :string, default: "")
  attr(:editing, :boolean, default: false)
  attr(:editor_content, :string, default: "")
  attr(:save_error, :string, default: nil)
  attr(:confirm_delete, :string, default: nil)
  attr(:backlinks, :list, default: [])
  attr(:updated_by_display, :string, default: nil)

  defp mobile_pages_viewer(assigns) do
    ~H"""
    <%= cond do %>
      <% @page && @editing -> %>
        <.mobile_editor page={@page} editor_content={@editor_content} save_error={@save_error} />
      <% @page -> %>
        <div class="flex flex-col" data-role="mobile-page-viewer">
          <%!-- Toolbar: icon + mono file key + edit / delete affordances --%>
          <div class="flex items-center gap-1 border-b border-edge px-3 py-2">
            <span class={[file_icon(@page.file_key), "size-5 shrink-0 text-primary"]}></span>
            <h1 class="min-w-0 flex-1 truncate font-mono text-sm font-semibold">
              {@page.file_key}
            </h1>
            <button
              phx-click="start_edit"
              class="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-base-content/60 transition-colors hover:bg-base-300 hover:text-primary"
              aria-label="Edit page"
            >
              <.icon name="hero-pencil-square" class="size-5" />
            </button>
            <div class="relative">
              <button
                phx-click="confirm_delete"
                phx-value-key={@page.file_key}
                class="flex min-h-11 min-w-11 items-center justify-center rounded-lg text-base-content/60 transition-colors hover:bg-base-300 hover:text-error"
                aria-label="Delete page"
              >
                <.icon name="hero-trash" class="size-5" />
              </button>
              <div
                :if={@confirm_delete == @page.file_key}
                class="absolute right-0 top-full z-50 mt-1 w-60 rounded-lg border border-edge bg-base-100 p-3 shadow-lg"
              >
                <p class="mb-1 text-sm font-medium">Delete {@page.file_key}?</p>
                <p class="mb-3 text-xs text-base-content/50">This action cannot be undone.</p>
                <div class="flex justify-end gap-2">
                  <button phx-click="cancel_delete" class="btn btn-ghost btn-sm min-h-11">
                    Cancel
                  </button>
                  <button
                    phx-click="delete_file"
                    phx-value-key={@page.file_key}
                    class="btn btn-error btn-sm min-h-11"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </div>
          </div>

          <%!-- Rendered page (read view) --%>
          <article class="prose prose-sm max-w-none px-4 py-4 text-base-content">
            {Phoenix.HTML.raw(@preview_html)}
          </article>

          <%!-- Details accordion (right-pane content folded inline) --%>
          <.mobile_details
            page={@page}
            backlinks={@backlinks}
            updated_by_display={@updated_by_display}
          />
        </div>
      <% true -> %>
        <div class="flex flex-1 items-center justify-center px-6 py-16">
          <div class="text-center">
            <span class="hero-document-text mx-auto mb-3 block size-14 text-base-content/20"></span>
            <h3 class="text-base font-medium text-base-content/50">Org Memory</h3>
            <p class="mt-1 text-sm text-base-content/40">
              Tap the menu to open the namespace tree and pick a page.
            </p>
          </div>
        </div>
    <% end %>
    """
  end

  # ── Pages editor (mobile) ───────────────────────────────────────────────

  # A single-textarea mobile editor with its OWN element ids
  # (`m-org-memory-editor`) so it never collides with the desktop
  # editor's `org-memory-editor`. The generic `MarkdownEditor` hook binds
  # to `this.el`, and Save dispatches `org-memory:save` to the mobile
  # textarea — so `save_page` runs with the mobile content while
  # `prepend_frontmatter/3` still folds in any active `fm_form` from the
  # server (mobile skips the desktop frontmatter form + preview split).
  attr(:page, :any, required: true)
  attr(:editor_content, :string, default: "")
  attr(:save_error, :string, default: nil)

  defp mobile_editor(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col" data-role="mobile-page-editor">
      <div class="flex items-center gap-1 border-b border-edge px-3 py-2">
        <span class={[file_icon(@page.file_key), "size-5 shrink-0 text-warning"]}></span>
        <h1 class="min-w-0 flex-1 truncate font-mono text-sm font-semibold">
          Editing {@page.file_key}
        </h1>
        <button phx-click="cancel_edit" class="btn btn-ghost btn-sm min-h-11">
          Cancel
        </button>
        <button
          id="m-org-memory-save-btn"
          phx-click={JS.dispatch("org-memory:save", to: "#m-org-memory-editor")}
          class="btn btn-primary btn-sm min-h-11 gap-1"
        >
          <.icon name="hero-check" class="size-4" /> Save
        </button>
      </div>
      <div
        :if={@save_error}
        class="mx-3 mt-2 rounded-lg border border-error/20 bg-error/10 px-3 py-2 text-sm text-error"
      >
        {@save_error}
      </div>
      <textarea
        id="m-org-memory-editor"
        phx-hook="MarkdownEditor"
        phx-debounce="300"
        class="min-h-64 flex-1 resize-none bg-base-100 p-4 font-mono text-sm text-base-content focus:outline-none"
        spellcheck="false"
      >{@editor_content}</textarea>
    </div>
    """
  end

  # ── Details accordion (mobile — folds the desktop right pane) ────────────

  attr(:page, :any, required: true)
  attr(:backlinks, :list, default: [])
  attr(:updated_by_display, :string, default: nil)

  defp mobile_details(assigns) do
    ~H"""
    <details class="group border-t border-edge" data-role="mobile-details">
      <summary class="flex min-h-11 cursor-pointer list-none items-center gap-2 px-4 text-sm font-medium text-base-content/70 marker:content-none [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-4 text-base-content/40 transition-transform group-open:rotate-90"
        /> Details
      </summary>

      <div class="space-y-4 px-4 pb-4">
        <%!-- Backlinks --%>
        <div data-role="mobile-backlinks">
          <h3 class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/40">
            Backlinks
          </h3>
          <%= if @backlinks == [] do %>
            <p class="text-xs text-base-content/40">No backlinks yet</p>
          <% else %>
            <ul class="flex flex-col">
              <li :for={source <- @backlinks}>
                <button
                  phx-click="select_page"
                  phx-value-file_key={source.file_key}
                  data-mobile-backlink={source.file_key}
                  title={source.file_key}
                  class="flex min-h-11 w-full items-center gap-2 rounded-lg px-2 text-left text-xs transition-colors hover:bg-base-300/60"
                >
                  <span class={[file_icon(source.file_key), "shrink-0 text-base-content/40"]}></span>
                  <span class="min-w-0 flex-1 truncate font-mono">{source.file_key}</span>
                </button>
              </li>
            </ul>
          <% end %>
        </div>

        <%!-- Version metadata (mono) --%>
        <dl class="flex flex-col gap-1.5 text-xs" data-role="mobile-page-meta">
          <div class="flex items-center justify-between gap-2">
            <dt class="text-base-content/40">Version</dt>
            <dd class="font-mono">v{@page.version}</dd>
          </div>
          <div
            :if={@page.updated_by && @updated_by_display}
            class="flex items-center justify-between gap-2"
          >
            <dt class="text-base-content/40">Updated by</dt>
            <dd class="min-w-0 truncate" title={@updated_by_display}>{@updated_by_display}</dd>
          </div>
          <div :if={@page.inserted_at} class="flex items-center justify-between gap-2">
            <dt class="text-base-content/40">Created</dt>
            <dd class="font-mono">{format_relative(@page.inserted_at)}</dd>
          </div>
          <div :if={@page.updated_at} class="flex items-center justify-between gap-2">
            <dt class="text-base-content/40">Updated</dt>
            <dd class="font-mono">{format_relative(@page.updated_at)}</dd>
          </div>
        </dl>
      </div>
    </details>
    """
  end

  # Relative timestamp for the metadata rows — mirrors RightPane's
  # `format_relative/1` (kept local so this component stays standalone).
  defp format_relative(%DateTime{} = datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end

  defp format_relative(_), do: "—"

  # ── Journal (mobile) ────────────────────────────────────────────────────

  attr(:groups, :list, default: [])
  attr(:draft, :string, default: "")
  attr(:namespace, :string, default: "org")
  attr(:focus_date, :any, default: nil)

  defp mobile_journal(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col" data-role="mobile-journal">
      <%!-- One-line "Note to today" composer. Collapsed to a single line;
           tap-expands (CSS :focus-within, view-only) to the full textarea
           + Append button. Append-only by contract — NO delete anywhere. --%>
      <form
        id="m-org-memory-journal-form"
        phx-submit="append_journal"
        phx-change="update_journal_draft"
        class="group shrink-0 border-b border-edge px-3 py-2"
      >
        <textarea
          name="content"
          rows="1"
          placeholder="Note to today…"
          class="textarea textarea-bordered min-h-11 w-full resize-none text-sm transition-all focus:min-h-24"
        >{@draft}</textarea>
        <div class="mt-2 hidden justify-end group-focus-within:flex">
          <button
            type="submit"
            class="btn btn-primary btn-sm min-h-11 gap-1"
            disabled={String.trim(@draft) == ""}
          >
            <.icon name="hero-plus" class="size-4" /> Append
          </button>
        </div>
      </form>

      <%!-- Day-grouped feed, newest day first --%>
      <div class="flex-1 px-3 py-3">
        <%= if @groups == [] do %>
          <div class="flex flex-col items-center justify-center py-16 text-center">
            <span class="hero-book-open mb-3 size-12 text-base-content/20"></span>
            <h3 class="text-base font-medium text-base-content/50">No journal entries yet</h3>
            <p class="mt-1 max-w-xs text-sm text-base-content/40">
              Notes appended here (or by agents via <code>memory_create</code>)
              show up grouped by day.
            </p>
          </div>
        <% else %>
          <div class="space-y-5">
            <div :for={{date, entries} <- @groups} id={"m-journal-day-#{Date.to_iso8601(date)}"}>
              <div class="mb-2 flex items-center gap-2">
                <span class={[
                  "text-sm font-semibold",
                  if(@focus_date == date, do: "text-primary", else: "text-base-content/70")
                ]}>
                  {format_journal_date(date)}
                </span>
                <div class="flex-1 border-t border-edge"></div>
                <span class="font-mono text-xs text-base-content/30">
                  {length(entries)} {pluralize(length(entries), "entry", "entries")}
                </span>
              </div>

              <div class="space-y-2">
                <div
                  :for={entry <- entries}
                  class={[
                    "rounded-lg border bg-base-100 p-3",
                    if(@focus_date == date, do: "border-primary/40", else: "border-edge")
                  ]}
                >
                  <div class="mb-1 flex items-center gap-2">
                    <%!-- new marker — warning-yellow token ONLY (today's entries) --%>
                    <span
                      :if={date == Date.utc_today()}
                      class="size-2 shrink-0 rounded-full bg-warning"
                      title="New"
                    >
                    </span>
                    <span class="ml-auto font-mono text-xs text-base-content/30">
                      {Calendar.strftime(entry.inserted_at, "%H:%M")}
                    </span>
                  </div>
                  <p class="whitespace-pre-wrap text-sm text-base-content">{entry.content}</p>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_journal_date(date) do
    today = Date.utc_today()

    cond do
      date == today -> "Today"
      date == Date.add(today, -1) -> "Yesterday"
      true -> Calendar.strftime(date, "%A, %b %-d")
    end
  end

  # ── Proposals (mobile) ──────────────────────────────────────────────────

  attr(:proposals, :list, default: [])
  attr(:show_reject_form_for, :any, default: nil)
  attr(:expanded_diffs, :any, default: nil)

  defp mobile_proposals(assigns) do
    assigns = assign(assigns, :expanded_diffs, assigns.expanded_diffs || MapSet.new())

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col" data-role="mobile-proposals">
      <%= if @proposals == [] do %>
        <div
          class="flex flex-1 items-center justify-center px-6 py-16"
          data-role="mobile-proposals-empty"
        >
          <div class="max-w-xs rounded-xl border border-edge bg-base-100 p-6 text-center">
            <span class="hero-sparkles mx-auto mb-3 block size-12 text-base-content/30"></span>
            <h3 class="text-base font-medium text-base-content/70">
              Nothing to review — the Historian's dreaming is quiet.
            </h3>
            <p class="mt-2 text-sm text-base-content/40">
              Rejected + expired proposals remain in the DB for post-hoc analysis
              but don't appear here.
            </p>
          </div>
        </div>
      <% else %>
        <div class="space-y-3 px-3 py-3">
          <div
            :for={proposal <- @proposals}
            data-mobile-proposal-id={proposal.id}
            class="rounded-xl border border-edge bg-base-100 p-3"
          >
            <%!-- category + confidence badges + age --%>
            <div class="mb-2 flex flex-wrap items-center gap-1.5">
              <span class={["badge badge-sm", category_badge_class(proposal.category)]}>
                {proposal.category}
              </span>
              <span class={["badge badge-sm", confidence_badge_class(proposal.confidence)]}>
                {proposal.confidence}
              </span>
              <span class="ml-auto font-mono text-xs text-base-content/40">
                {format_relative(proposal.inserted_at)}
              </span>
            </div>

            <%!-- target page key the body promotes into --%>
            <div class="mb-2 flex items-center gap-1 text-xs text-base-content/50">
              <.icon name="hero-arrow-down-tray" class="size-3.5 shrink-0" />
              <span class="min-w-0 truncate font-mono">{target_key(proposal)}</span>
            </div>

            <%!-- Additive diff. Long PROSE lines WRAP (whitespace-pre-wrap
                 + break-words) so the proposal is readable vertically, not
                 hidden behind horizontal scroll; the page stays at 375px.
                 overflow-x-auto is only a fallback for genuinely unbreakable
                 tokens. A generous height shows most proposals in full; a
                 truly long one clamps with a >=44px "Show full diff"
                 tap-to-expand (server-held, never silently truncated). --%>
            <% long? = long_body?(proposal.body) %>
            <% expanded? = MapSet.member?(@expanded_diffs, proposal.id) %>
            <div class="relative">
              <div
                class={[
                  "whitespace-pre-wrap break-words rounded-lg border border-edge bg-base-200/40 p-2 font-mono text-xs leading-relaxed",
                  if(long? and not expanded?,
                    do: "max-h-64 overflow-hidden",
                    else: "overflow-x-auto"
                  )
                ]}
                data-role="mobile-proposal-diff"
              >
                <div :for={line <- diff_lines(proposal.body)} class="text-success">
                  {"+ " <> line}
                </div>
              </div>
              <div
                :if={long? and not expanded?}
                class="pointer-events-none absolute inset-x-0 bottom-0 h-12 rounded-b-lg bg-gradient-to-t from-base-100 to-transparent"
              >
              </div>
            </div>
            <button
              :if={long?}
              phx-click="toggle_proposal_diff"
              phx-value-id={proposal.id}
              class="flex min-h-11 items-center gap-1 text-xs font-medium text-primary"
              data-role="mobile-diff-toggle"
            >
              <.icon
                name="hero-chevron-down"
                class={["size-4 transition-transform", expanded? && "rotate-180"]}
              />
              {if expanded?, do: "Show less", else: "Show full diff"}
            </button>

            <%!-- footer: Reject / Apply (>=44px) --%>
            <div class="mt-3 flex gap-2">
              <button
                phx-click="show_reject_form"
                phx-value-id={proposal.id}
                class="btn btn-ghost btn-sm min-h-11 flex-1 gap-1"
              >
                <.icon name="hero-x-mark" class="size-4" /> Reject
              </button>
              <button
                phx-click="approve_proposal"
                phx-value-id={proposal.id}
                class="btn btn-primary btn-sm min-h-11 flex-1 gap-1"
              >
                <.icon name="hero-check" class="size-4" /> Apply
              </button>
            </div>

            <%!-- inline reject feedback, expands within the card --%>
            <form
              :if={@show_reject_form_for == proposal.id}
              id={"m-proposal-reject-form-#{proposal.id}"}
              phx-submit="reject_proposal"
              class="mt-3 rounded-lg border border-warning/40 bg-warning/5 p-2"
              data-role="mobile-reject-form"
            >
              <%!-- `name="_id"` — see the desktop pane: name="id" on an input
                   overrides the form element's DOM id. --%>
              <input type="hidden" name="_id" value={proposal.id} />
              <label class="mb-1 block text-xs font-medium text-base-content/70">
                Why reject? Feedback trains the next dreaming run.
              </label>
              <textarea
                name="feedback"
                rows="2"
                placeholder="Optional feedback…"
                class="textarea textarea-bordered w-full text-sm"
              ></textarea>
              <div class="mt-2 flex justify-end gap-2">
                <button
                  type="button"
                  phx-click="cancel_reject"
                  phx-value-id={proposal.id}
                  class="btn btn-ghost btn-sm min-h-11"
                >
                  Cancel
                </button>
                <button type="submit" class="btn btn-warning btn-sm min-h-11">
                  Submit
                </button>
              </div>
            </form>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # Category / confidence badge tone — mirrors ProposalsPane's helpers.
  defp category_badge_class("emerging-risk"), do: "badge-warning"
  defp category_badge_class("stale-fact-candidate-retirement"), do: "badge-warning"
  defp category_badge_class("strategic-insight"), do: "badge-info"
  defp category_badge_class("recurring-theme"), do: "badge-info"
  defp category_badge_class("cross-project-pattern"), do: "badge-neutral"
  defp category_badge_class("unresolved-question"), do: "badge-neutral"
  defp category_badge_class(_), do: "badge-ghost"

  defp confidence_badge_class("high"), do: "badge-success"
  defp confidence_badge_class("medium"), do: "badge-warning"
  defp confidence_badge_class("low"), do: "badge-ghost"
  defp confidence_badge_class(_), do: "badge-ghost"

  # Target wiki page the body promotes into — the ingest-time
  # `target_page_key`, falling back to the same derivation the promotion
  # pipeline uses when the column is nil (pre-column rows).
  defp target_key(%{target_page_key: key}) when is_binary(key) and key != "", do: key

  defp target_key(%{category: category, evidence: evidence, body: body}),
    do: Proposals.derive_target_page_key(category, evidence, body)

  defp diff_lines(body) when is_binary(body), do: String.split(body, "\n")
  defp diff_lines(_), do: []

  # A proposal body is "long" (worth clamping behind a Show-full-diff
  # expander) when it has many hard lines or enough characters to wrap
  # past the generous default height. Short proposals render in full with
  # no clamp and no expander.
  defp long_body?(body) when is_binary(body),
    do: String.length(body) > 320 or length(String.split(body, "\n")) > 8

  defp long_body?(_), do: false

  # ── Search (mobile) ─────────────────────────────────────────────────────

  attr(:query, :string, default: "")
  attr(:corpus, :string, default: "all")
  attr(:namespace, :string, default: "all")
  attr(:namespaces, :list, default: [])
  attr(:results, :list, default: [])
  attr(:performed, :boolean, default: false)
  attr(:truncated, :boolean, default: false)
  attr(:error, :string, default: nil)

  defp mobile_search(assigns) do
    ~H"""
    <div class="flex min-h-0 flex-1 flex-col" data-role="mobile-search">
      <%!-- Persistent search input + facet chips REPLACE the path chip on
           the Search tab (search is corpus-wide). Reuses the existing
           search_memory event: the form submits query + current facets;
           each facet chip re-dispatches with its own value while
           preserving the other facet + the last query. --%>
      <form
        id="m-org-memory-search-form"
        phx-submit="search_memory"
        class="shrink-0 border-b border-edge px-3 py-2"
      >
        <input type="hidden" name="corpus" value={@corpus} />
        <input type="hidden" name="namespace" value={@namespace} />
        <div class="flex items-center gap-2">
          <div class="relative flex-1">
            <span class="hero-magnifying-glass pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-base-content/40">
            </span>
            <input
              type="text"
              name="query"
              value={@query}
              placeholder="Search org memory…"
              autocomplete="off"
              class="input input-bordered min-h-11 w-full pl-9 text-sm"
            />
          </div>
          <button type="submit" class="btn btn-primary min-h-11 min-w-11" aria-label="Search">
            <.icon name="hero-magnifying-glass" class="size-5" />
          </button>
        </div>

        <%!-- corpus facet chips --%>
        <div class="mt-2 flex flex-wrap gap-1.5" data-role="mobile-search-facets">
          <button
            :for={c <- ~w(all page journal message)}
            type="button"
            phx-click="search_memory"
            phx-value-query={@query}
            phx-value-corpus={c}
            phx-value-namespace={@namespace}
            data-facet-corpus={c}
            class={["btn btn-sm min-h-11", if(@corpus == c, do: "btn-primary", else: "btn-ghost")]}
          >
            {c}
          </button>
        </div>

        <%!-- namespace facet chips (mono) --%>
        <div :if={@namespaces != []} class="mt-1.5 flex flex-wrap gap-1.5">
          <button
            :for={ns <- ["all" | @namespaces]}
            type="button"
            phx-click="search_memory"
            phx-value-query={@query}
            phx-value-corpus={@corpus}
            phx-value-namespace={ns}
            data-facet-namespace={ns}
            class={[
              "btn btn-sm min-h-11 font-mono",
              if(@namespace == ns, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            {ns}
          </button>
        </div>
      </form>

      <%!-- Results — SearchPane's per-source rows restyled as mobile cards --%>
      <div class="flex-1 px-3 py-3">
        <p :if={@error} class="mb-3 text-sm text-error">{@error}</p>

        <%= cond do %>
          <% not @performed -> %>
            <div class="flex flex-col items-center justify-center py-16 text-center">
              <span class="hero-magnifying-glass mb-3 size-12 text-base-content/20"></span>
              <p class="text-sm text-base-content/40">Type a query to search the org's memory.</p>
            </div>
          <% @results == [] -> %>
            <div class="flex flex-col items-center justify-center py-16 text-center">
              <span class="hero-inbox mb-3 size-12 text-base-content/20"></span>
              <p class="text-sm text-base-content/40">No results.</p>
            </div>
          <% true -> %>
            <p :if={@truncated} class="mb-3 text-xs text-base-content/40">
              Some channels hit their result cap — a higher limit may surface more hits.
            </p>
            <ul class="space-y-2">
              <li :for={hit <- @results} data-role="mobile-search-result">
                <.mobile_result_hit hit={hit} />
              </li>
            </ul>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:hit, :map, required: true)

  defp mobile_result_hit(%{hit: %{source: "page"}} = assigns) do
    ~H"""
    <button
      phx-click="open_result_page"
      phx-value-file_key={@hit.path}
      class="w-full rounded-lg border border-edge bg-base-100 p-3 text-left transition-colors hover:border-primary"
    >
      <.mobile_result_meta hit={@hit} />
      <p class="mt-1 truncate font-mono text-sm font-medium">{@hit.path}</p>
      <p class="mt-1 line-clamp-3 break-words text-xs text-base-content/60">
        {snippet(@hit.content)}
      </p>
    </button>
    """
  end

  defp mobile_result_hit(%{hit: %{source: "journal"}} = assigns) do
    ~H"""
    <button
      phx-click="open_result_journal"
      phx-value-date={@hit.date_or_inserted_at}
      class="w-full rounded-lg border border-edge bg-base-100 p-3 text-left transition-colors hover:border-primary"
    >
      <.mobile_result_meta hit={@hit} />
      <p class="mt-1 truncate font-mono text-sm font-medium">{@hit.path}</p>
      <p class="mt-1 line-clamp-3 break-words text-xs text-base-content/60">
        {snippet(@hit.content)}
      </p>
    </button>
    """
  end

  defp mobile_result_hit(%{hit: %{source: "message"}} = assigns) do
    ~H"""
    <a
      href={"/chat/#{@hit.space_id}"}
      class="block w-full rounded-lg border border-edge bg-base-100 p-3 text-left transition-colors hover:border-primary"
    >
      <.mobile_result_meta hit={@hit} />
      <p class="mt-1 line-clamp-3 break-words text-xs text-base-content/60">
        {snippet(@hit.content)}
      </p>
    </a>
    """
  end

  defp mobile_result_hit(assigns) do
    ~H"""
    <div class="w-full rounded-lg border border-edge bg-base-100 p-3">
      <.mobile_result_meta hit={@hit} />
      <p class="mt-1 line-clamp-3 break-words text-xs text-base-content/60">
        {snippet(@hit.content)}
      </p>
    </div>
    """
  end

  attr(:hit, :map, required: true)

  defp mobile_result_meta(assigns) do
    ~H"""
    <div class="flex items-center gap-2 text-xs">
      <span class={["badge badge-sm font-semibold", source_badge_class(@hit.source)]}>
        {String.upcase(@hit.source)}
      </span>
      <span class="ml-auto font-mono text-base-content/30">{@hit.date_or_inserted_at}</span>
    </div>
    """
  end

  defp source_badge_class("page"), do: "badge-primary badge-outline"
  defp source_badge_class("journal"), do: "badge-info badge-outline"
  defp source_badge_class("message"), do: "badge-accent badge-outline"
  defp source_badge_class(_), do: "badge-ghost"

  defp snippet(content) when is_binary(content) do
    if String.length(content) > 240, do: String.slice(content, 0, 240) <> "…", else: content
  end

  defp snippet(_), do: ""

  # ── Path chip helpers ───────────────────────────────────────────────────

  # Breadcrumb segments for the selected page, collapsing the interposed
  # `page/` grammar segment the same way `NamespaceTree` hoists it and
  # dropping the `.md` on the leaf: `org/page/identity.md` → ["org",
  # "identity"], `project/<id>/page/decisions.md` → ["project", "<id>",
  # "decisions"]. With no page selected the chip shows the active
  # namespace root only (`"org"` → ["org"]).
  defp path_segments(nil, namespace), do: String.split(namespace || "org", "/")

  defp path_segments(%{file_key: file_key}, _namespace) do
    file_key
    |> String.split("/")
    |> Enum.reject(&(&1 == "page"))
    |> List.update_at(-1, &String.replace_suffix(&1, ".md", ""))
  end

  defp last_index(page, namespace), do: length(path_segments(page, namespace)) - 1

  # ── Small helpers ────────────────────────────────────────────────────────

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural
end
