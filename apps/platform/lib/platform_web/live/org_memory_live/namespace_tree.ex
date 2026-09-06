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

  # ── Components ─────────────────────────────────────────────────────────

  attr(:tree, :map, required: true, doc: "root node from build/1")
  attr(:expanded_prefixes, :any, required: true, doc: "MapSet of expanded folder prefixes")
  attr(:selected_file_key, :string, default: nil)

  def namespace_tree(assigns) do
    ~H"""
    <aside class="flex min-h-0 flex-col overflow-hidden border-r border-edge bg-base-200/40">
      <div class="flex items-center justify-between px-4 py-3">
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
        "flex w-full items-center gap-2 py-1.5 pr-4 text-left text-sm transition-colors hover:bg-base-300",
        if(@selected?, do: "bg-base-300 text-primary font-medium", else: "text-base-content/70")
      ]}
    >
      <span class={[file_icon(@page.file_key), "shrink-0"]}></span>
      <span class="truncate">{leaf_label(@page.file_key)}</span>
      <span class="ml-auto text-xs text-base-content/30">v{@page.version}</span>
    </button>
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
