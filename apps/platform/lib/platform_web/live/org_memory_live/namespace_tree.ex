defmodule PlatformWeb.OrgMemoryLive.NamespaceTree do
  @moduledoc """
  Left-pane namespace tree for the Org Memory wiki (ADR-0041 T7 stage 3).

  Stateless function components — the tree structure, expansion set, and
  selection all live on `PlatformWeb.OrgMemoryLive`. Events emitted (and
  handled by the parent LiveView):

    * `"select_page"`      with `%{"file_key" => ...}` — leaf click
    * `"toggle_namespace"` with `%{"prefix" => ...}`   — folder expand/collapse
    * `"show_create"` / `"seed_defaults"`              — header / empty-state
      affordances

  Also owns the pure grouping logic (`build/1`) that turns the flat
  `Wiki.list_pages/1` result into a nested folder tree keyed by the
  `/`-separated segments of each `file_key` (`org/page/identity.md`,
  `project/<uuid>/page/decisions.md`, `space/<uuid>/page/playbook.md`, ...).

  Page-grammar display (Sloane-authorized, 2026-06-11): canonical page
  keys carry a `page/` segment right after the namespace
  (`<ns>/page/<rest>` — T5 routing grammar). The interposed `page`
  folder is pure routing noise for humans, so rendering collapses it:
  a folder literally named `page` sitting directly under a namespace
  node (`org/`, `project/<x>/`, `space/<x>/`) is hoisted — its pages
  and sub-folders render as the namespace's own children
  (`identity.md` directly under `org/`). `data-file-key` attributes
  keep the REAL full keys; `journal/` / `private/` folders (and any
  deeper `page` segments) render as-is.
  """

  use Phoenix.Component

  alias PlatformWeb.OrgMemoryLive.ProductDocs

  # ── Tree building (pure) ───────────────────────────────────────────────

  @doc """
  Group a flat list of `Platform.Org.WikiPage` structs into a nested
  folder tree.

  Returns the root node — a map of shape
  `%{name: nil, prefix: "", folders: %{segment => node}, pages: [page]}`
  where each child node carries its cumulative `prefix`
  (e.g. `"project/<uuid>/"`). Pages whose `file_key` has no `/` land in
  the root node's `pages` list.
  """
  @spec build([struct()]) :: map()
  def build(pages) when is_list(pages) do
    Enum.reduce(pages, new_node(nil, ""), fn page, acc ->
      insert(acc, String.split(page.file_key, "/"), page, "")
    end)
  end

  defp new_node(name, prefix), do: %{name: name, prefix: prefix, folders: %{}, pages: []}

  defp insert(node, [_leaf], page, _prefix) do
    %{node | pages: [page | node.pages]}
  end

  defp insert(node, [segment | rest], page, prefix) do
    child_prefix = prefix <> segment <> "/"
    child = Map.get(node.folders, segment, new_node(segment, child_prefix))
    %{node | folders: Map.put(node.folders, segment, insert(child, rest, page, child_prefix))}
  end

  @doc """
  Top-level namespace prefixes of a built tree (`org/`, `project/`, ...).
  These are expanded by default; deeper folders start collapsed.
  """
  @spec default_expanded(map()) :: MapSet.t()
  def default_expanded(%{folders: folders}) do
    folders |> Map.values() |> Enum.map(& &1.prefix) |> MapSet.new()
  end

  @doc """
  All ancestor folder prefixes of a file_key, so a deep-linked page can
  be revealed: `"project/x/decisions.md"` → `MapSet.new(["project/", "project/x/"])`.
  """
  @spec ancestor_prefixes(String.t()) :: MapSet.t()
  def ancestor_prefixes(file_key) when is_binary(file_key) do
    segments = String.split(file_key, "/")

    segments
    |> Enum.drop(-1)
    |> Enum.scan("", fn segment, acc -> acc <> segment <> "/" end)
    |> MapSet.new()
  end

  @doc """
  Hero-icon class for a file_key. Shared by the tree leaves, the page
  viewer toolbar, and the create panel's template cards.
  """
  @spec file_icon(String.t()) :: String.t()
  # Page-grammar file_keys (2026-06-11 key migration):
  # org/page/identity.md, org/page/memory.md, org/page/agents.md
  def file_icon("org/page/identity" <> _), do: "hero-identification size-4"
  def file_icon("org/page/memory" <> _), do: "hero-light-bulb size-4"
  def file_icon("org/page/agents" <> _), do: "hero-cpu-chip size-4"
  def file_icon("org/page/directory" <> _), do: "hero-users size-4"
  # Flat path-style file_keys (T1..rollup) — still resolvable via the
  # 20260611120000 alias backfill; kept so legacy rows render right.
  def file_icon("org/identity" <> _), do: "hero-identification size-4"
  def file_icon("org/memory" <> _), do: "hero-light-bulb size-4"
  def file_icon("org/agents" <> _), do: "hero-cpu-chip size-4"
  def file_icon("org/directory" <> _), do: "hero-users size-4"
  # Legacy V1 keys — still resolved via alias-compat; kept so any
  # pre-migration rows or alias rows render with the right icon.
  def file_icon("ORG_IDENTITY" <> _), do: "hero-identification size-4"
  def file_icon("ORG_MEMORY" <> _), do: "hero-light-bulb size-4"
  def file_icon("ORG_AGENTS" <> _), do: "hero-cpu-chip size-4"
  def file_icon("ORG_DIRECTORY" <> _), do: "hero-users size-4"
  def file_icon(_), do: "hero-document-text size-4"

  # ── Selected-leaf styling (task 01a10a44 stage 6) ─────────────────────
  #
  # One pair of class lists for BOTH leaf kinds (Burrow Docs and the Pages
  # tree), so the two cannot drift apart again. The selected leaf keeps the
  # canvas's `--color-interactive` text and sits on `base-100`, the lightest
  # ground each theme ships. `base-300` failed AA in light: #087f93 on
  # #D7D7D7 is 3.27:1; on base-100 it is 4.70:1 light and 10.00:1 dark
  # (pinned in selected_leaf_contrast_test.exs, computed from app.css). The
  # global `--color-interactive` token is untouched; it colours every link
  # in the product.
  #
  # `base-100` is close to the Pages tree's own ground in light (base-200 at
  # 40% over base-100), so the row also takes an inset `--edge` hairline,
  # the same "selected sits raised on base-100 inside an edge" idiom as the
  # selected tab in view.ex. The hover ground lives on the UNSELECTED list
  # only: hovering the selected row must not repaint it base-300 and bring
  # the 3.27:1 pair back.
  @selected_leaf_class "bg-base-100 font-medium text-[var(--color-interactive)] ring-1 ring-inset ring-edge"
  @unselected_leaf_class "text-base-content/70 hover:bg-base-300"

  @doc false
  @spec selected_leaf_class() :: String.t()
  def selected_leaf_class, do: @selected_leaf_class

  @doc false
  @spec unselected_leaf_class() :: String.t()
  def unselected_leaf_class, do: @unselected_leaf_class

  # ── Components ─────────────────────────────────────────────────────────

  attr(:tree, :map, required: true, doc: "root node from build/1")
  attr(:expanded_prefixes, :any, required: true, doc: "MapSet of expanded folder prefixes")
  attr(:selected_file_key, :string, default: nil)

  attr(:burrow_docs, :list,
    default: [],
    doc: "ProductDocs entries, in product order; the section is hidden when empty"
  )

  def namespace_tree(assigns) do
    ~H"""
    <aside class="flex min-h-0 flex-col overflow-hidden border-r border-edge bg-base-200/40">
      <.burrow_docs_section
        :if={@burrow_docs != []}
        entries={@burrow_docs}
        open={MapSet.member?(@expanded_prefixes || MapSet.new(), burrow_prefix())}
        selected_file_key={@selected_file_key}
      />

      <div class="flex items-center justify-between px-4 py-3" data-role="pages-tree-header">
        <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Pages
        </h2>
        <button
          phx-click="show_create"
          class="rounded-lg p-1 text-base-content/50 hover:bg-base-300 hover:text-base-content transition-colors"
          title="New page"
        >
          <span class="hero-plus size-4"></span>
        </button>
      </div>

      <div class="flex-1 overflow-y-auto py-2">
        <%= if @tree.folders == %{} and @tree.pages == [] do %>
          <div class="px-4 py-8 text-center">
            <span class="hero-document-text mb-2 size-8 text-base-content/30 mx-auto block"></span>
            <p class="text-sm text-base-content/40 mb-3">No pages yet</p>
            <button phx-click="seed_defaults" class="btn btn-primary btn-xs">
              Create defaults
            </button>
          </div>
        <% else %>
          <.tree_folder
            :for={node <- sorted_folders(@tree)}
            node={node}
            expanded_prefixes={@expanded_prefixes}
            selected_file_key={@selected_file_key}
            depth={0}
          />
          <.tree_leaf
            :for={page <- sorted_pages(@tree)}
            page={page}
            selected_file_key={@selected_file_key}
            depth={0}
          />
        <% end %>
      </div>

      <div class="border-t border-edge px-4 py-3">
        <button
          phx-click="seed_defaults"
          class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-xs text-base-content/40 hover:bg-base-300 hover:text-base-content/60 transition-colors"
        >
          <span class="hero-arrow-path size-3.5"></span> Seed missing defaults
        </button>
      </div>
    </aside>
    """
  end

  attr(:node, :map, required: true)
  attr(:expanded_prefixes, :any, required: true)
  attr(:selected_file_key, :string, default: nil)
  attr(:depth, :integer, default: 0)

  defp tree_folder(assigns) do
    assigns =
      assigns
      |> assign(:node, hoist_page_folder(assigns.node))
      |> assign(
        :expanded?,
        MapSet.member?(assigns.expanded_prefixes, assigns.node.prefix)
      )

    ~H"""
    <div>
      <button
        phx-click="toggle_namespace"
        phx-value-prefix={@node.prefix}
        data-namespace-prefix={@node.prefix}
        style={indent(@depth)}
        class="flex w-full items-center gap-1.5 py-1.5 pr-4 text-left text-sm text-base-content/70 transition-colors hover:bg-base-300"
      >
        <span class={[
          if(@expanded?, do: "hero-chevron-down", else: "hero-chevron-right"),
          "size-3 shrink-0 text-base-content/40"
        ]}>
        </span>
        <span class="hero-folder size-4 shrink-0 text-base-content/40"></span>
        <span class="truncate">{@node.name}</span>
      </button>

      <div :if={@expanded?}>
        <.tree_folder
          :for={child <- sorted_folders(@node)}
          node={child}
          expanded_prefixes={@expanded_prefixes}
          selected_file_key={@selected_file_key}
          depth={@depth + 1}
        />
        <.tree_leaf
          :for={page <- sorted_pages(@node)}
          page={page}
          selected_file_key={@selected_file_key}
          depth={@depth + 1}
        />
      </div>
    </div>
    """
  end

  attr(:page, :any, required: true)
  attr(:selected_file_key, :string, default: nil)
  attr(:depth, :integer, default: 0)

  defp tree_leaf(assigns) do
    assigns = assign(assigns, :selected?, assigns.selected_file_key == assigns.page.file_key)

    ~H"""
    <button
      phx-click="select_page"
      phx-value-file_key={@page.file_key}
      data-file-key={@page.file_key}
      style={indent(@depth)}
      class={[
        "flex w-full items-center gap-2 py-1.5 pr-4 text-left text-sm transition-colors",
        if(@selected?, do: selected_leaf_class(), else: unselected_leaf_class())
      ]}
      aria-current={@selected? && "page"}
    >
      <span class={[file_icon(@page.file_key), "shrink-0"]}></span>
      <span class="truncate">{leaf_label(@page.file_key)}</span>
      <span class="ml-auto text-xs text-base-content/30">v{@page.version}</span>
    </button>
    """
  end

  # ── Burrow Docs section (task 01a10a44 stage 5) ──────────────────────
  #
  # Product docs sit in their own section ABOVE the Pages header, on a
  # base-200 ground with the cyan spine down its full height. Topics show
  # by frontmatter title in product `order`: no filename, no `vN` (the
  # version moves on every deploy that edits a doc and means nothing to a
  # reader) and no `+` (nothing can be created here). Collapsed by default;
  # the parent opens it (`"burrow/"` in `@expanded_prefixes`) when a Burrow
  # page is selected or the install has no org pages. Rows are 44px under
  # `lg` because the mobile drawer renders this same component.

  @burrow_prefix "burrow/"

  @doc "The expansion key of the Burrow Docs section in `expanded_prefixes`."
  @spec burrow_prefix() :: String.t()
  def burrow_prefix, do: @burrow_prefix

  attr(:entries, :list, required: true)
  attr(:open, :boolean, default: false)
  attr(:selected_file_key, :string, default: nil)

  defp burrow_docs_section(assigns) do
    assigns = assign(assigns, :prefix, @burrow_prefix)

    ~H"""
    <section
      class="mx-2 mt-2 flex max-h-[60%] shrink-0 overflow-y-auto rounded-lg bg-base-200"
      data-role="burrow-docs-section"
    >
      <ProductDocs.spine />
      <div class="min-w-0 flex-1 py-1">
        <button
          type="button"
          phx-click="toggle_namespace"
          phx-value-prefix={@prefix}
          data-role="burrow-docs-toggle"
          aria-expanded={to_string(@open)}
          class="flex min-h-11 w-full items-center justify-between gap-2 px-3 text-left text-sm font-semibold text-base-content transition-colors hover:bg-base-300 lg:min-h-9"
        >
          <span>Burrow Docs</span>
          <span class={[
            if(@open, do: "hero-chevron-down", else: "hero-chevron-right"),
            "size-3.5 shrink-0 text-base-content/60"
          ]}>
          </span>
        </button>
        <div :if={@open} data-role="burrow-docs-leaves">
          <button
            :for={entry <- @entries}
            type="button"
            phx-click="select_page"
            phx-value-file_key={entry.file_key}
            data-file-key={entry.file_key}
            data-burrow-leaf={entry.file_key}
            aria-current={@selected_file_key == entry.file_key && "page"}
            class={[
              "flex min-h-11 w-full items-center px-3 pl-6 text-left text-sm transition-colors lg:min-h-8",
              if(@selected_file_key == entry.file_key,
                do: selected_leaf_class(),
                else: unselected_leaf_class()
              )
            ]}
          >
            <span class="truncate">{ProductDocs.label(entry)}</span>
          </button>
        </div>
      </div>
    </section>
    """
  end

  # ── Render helpers ─────────────────────────────────────────────────────

  # Collapse the interposed `page` folder under a namespace node (see
  # moduledoc): its pages and sub-folders become the namespace's own
  # children for display. Render-only — the underlying tree (and every
  # data-file-key / data-namespace-prefix attribute on the hoisted
  # children's own sub-folders) keeps the real keys/prefixes.
  defp hoist_page_folder(%{prefix: prefix, folders: folders} = node) do
    case Map.pop(folders, "page") do
      {%{} = page_node, rest} ->
        if namespace_prefix?(prefix) do
          %{
            node
            | folders: Map.merge(page_node.folders, rest),
              pages: node.pages ++ page_node.pages
          }
        else
          node
        end

      {nil, _} ->
        node
    end
  end

  # `org/`, `project/<x>/`, `space/<x>/` — the namespace roots of the
  # T5 routing grammar (display-level check; no UUID validation here).
  defp namespace_prefix?(prefix) do
    Regex.match?(~r{\A(org|project/[^/]+|space/[^/]+)/\z}, prefix)
  end

  defp sorted_folders(%{folders: folders}) do
    folders |> Map.values() |> Enum.sort_by(& &1.name)
  end

  defp sorted_pages(%{pages: pages}) do
    Enum.sort_by(pages, & &1.file_key)
  end

  defp leaf_label(file_key) do
    file_key |> String.split("/") |> List.last()
  end

  defp indent(depth), do: "padding-left: #{1 + depth * 0.875}rem"
end
