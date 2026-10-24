defmodule PlatformWeb.OrgMemoryLive.PageViewer do
  @moduledoc """
  Main-pane page viewer for the Org Memory wiki (ADR-0041 T7 stage 4).

  Three sub-states, driven by the `@editing` assign:

    * **viewer** — read-only render of the wikilink-aware HTML produced
      by `PlatformWeb.OrgMemoryLive.MarkdownRenderer`.
    * **editor** — frontmatter form (one row per flat top-level key,
      `preamble` as a checkbox; non-scalar frontmatter falls back to a
      read-only `<pre>` with an "edit YAML directly in body" hint)
      above the markdown textarea + live preview split.
  History meta (`vN · updated by <who> · NN ago`) moved to
  `PlatformWeb.OrgMemoryLive.RightPane` in stage 5 — the right pane is
  the canonical home for page metadata, so the toolbar here carries the
  file_key only.

  Stateless — receives the selected `Platform.Org.WikiPage` (or `nil`)
  plus editor state from `PlatformWeb.OrgMemoryLive`. Emits
  `"start_edit"`, `"cancel_edit"`, `"save_page"`, `"update_frontmatter"`,
  `"confirm_delete"`, `"cancel_delete"`, and `"delete_file"` events
  handled by the parent LiveView.

  Burrow Docs pages (task 01a10a44 stage 5) render through
  `product_viewer/1` instead: the frontmatter title as the h1, the base-200
  provenance strip and the cyan spine, and NO Edit or Delete control (absent,
  not disabled: the page never becomes editable, and a disabled control
  explains itself only on hover). The bytes/lines footer is dropped too. The
  Overview (`burrow/page/index.md`) renders as `ProductDocs.overview/1`. The
  parent LiveView refuses the edit and delete events for these keys on the
  server, so a forged event changes nothing either.
  """

  use Phoenix.Component

  import PlatformWeb.CoreComponents, only: [input: 1]
  import PlatformWeb.OrgMemoryLive.NamespaceTree, only: [file_icon: 1]

  alias Phoenix.LiveView.JS
  alias PlatformWeb.OrgMemoryLive.ProductDocs

  attr(:page, :any, default: nil, doc: "selected Platform.Org.WikiPage or nil")
  attr(:editing, :boolean, default: false)
  attr(:editor_content, :string, default: "")
  attr(:preview_html, :string, default: "")
  attr(:save_error, :string, default: nil)
  attr(:confirm_delete, :string, default: nil)
  attr(:fm_form, :any, default: nil, doc: "to_form/2 over flat frontmatter, or nil")
  attr(:fm_complex, :string, default: nil, doc: "raw YAML block when frontmatter is non-flat")
  attr(:doc, :map, default: nil, doc: "ProductDocs entry when @page is a Burrow Docs page")
  attr(:burrow_docs, :list, default: [], doc: "all ProductDocs entries, for the Overview")

  def page_viewer(assigns) do
    ~H"""
    <%= cond do %>
      <% @page && @doc -> %>
        <.product_viewer doc={@doc} burrow_docs={@burrow_docs} preview_html={@preview_html} />
      <% @page && @editing -> %>
        <.editor
          page={@page}
          editor_content={@editor_content}
          preview_html={@preview_html}
          save_error={@save_error}
          fm_form={@fm_form}
          fm_complex={@fm_complex}
        />
      <% @page -> %>
        <.viewer page={@page} preview_html={@preview_html} confirm_delete={@confirm_delete} />
      <% true -> %>
        <.empty_state />
    <% end %>
    """
  end

  # ── Sub-state: viewer (read-only, with optional history meta) ──────────

  attr(:page, :any, required: true)
  attr(:preview_html, :string, required: true)
  attr(:confirm_delete, :string, default: nil)

  defp viewer(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Toolbar --%>
      <div class="flex items-center justify-between border-b border-edge px-6 py-3">
        <div class="flex items-center gap-3">
          <span class={[file_icon(@page.file_key), "size-5 text-primary"]}></span>
          <%!-- Version / updated-by / relative-time meta lives in the
               right pane (canonical home as of stage 5). --%>
          <h1 class="text-lg font-bold">{@page.file_key}</h1>
        </div>
        <div class="flex items-center gap-2">
          <button phx-click="start_edit" class="btn btn-primary btn-sm gap-1">
            <span class="hero-pencil-square size-4"></span> Edit
          </button>
          <div class="relative">
            <button
              phx-click="confirm_delete"
              phx-value-key={@page.file_key}
              class="btn btn-ghost btn-sm text-error/60 hover:text-error"
              title="Delete page"
            >
              <span class="hero-trash size-4"></span>
            </button>
            <%!-- Delete confirmation popover --%>
            <%= if @confirm_delete == @page.file_key do %>
              <div class="absolute right-0 top-full mt-1 z-50 rounded-lg border border-edge bg-base-100 p-4 shadow-lg w-64">
                <p class="text-sm font-medium mb-3">
                  Delete {@page.file_key}?
                </p>
                <p class="text-xs text-subtle mb-3">
                  This action cannot be undone.
                </p>
                <div class="flex justify-end gap-2">
                  <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                    Cancel
                  </button>
                  <button
                    phx-click="delete_file"
                    phx-value-key={@page.file_key}
                    class="btn btn-error btn-xs"
                  >
                    Delete
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Rendered preview --%>
      <div class="flex-1 overflow-y-auto px-8 py-6">
        <article class="prose prose-sm max-w-none text-base-content">
          {Phoenix.HTML.raw(@preview_html)}
        </article>
      </div>

      <%!-- Content stats footer (version / dates live in the right pane) --%>
      <div class="flex items-center gap-4 border-t border-edge px-6 py-2 text-xs text-subtle">
        <span class="flex items-center gap-1">
          <span class="hero-document size-3.5"></span>
          {byte_size(@page.content)} bytes
        </span>
        <span class="flex items-center gap-1">
          <span class="hero-hashtag size-3.5"></span>
          {line_count(@page.content)} lines
        </span>
      </div>
    </div>
    """
  end

  # ── Sub-state: Burrow Docs page (read-only, product-owned) ─────────────

  attr(:doc, :map, required: true)
  attr(:burrow_docs, :list, default: [])
  attr(:preview_html, :string, required: true)

  defp product_viewer(%{doc: %{index?: true}} = assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-y-auto" data-role="burrow-page">
      <ProductDocs.overview entries={@burrow_docs} />
    </div>
    """
  end

  defp product_viewer(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden" data-role="burrow-page">
      <div class="flex border-b border-edge" data-role="burrow-page-header">
        <ProductDocs.spine />
        <div class="min-w-0 flex-1">
          <div class="px-6 py-3">
            <h1 class="text-lg font-bold" data-role="burrow-page-title">{@doc.title}</h1>
          </div>
          <ProductDocs.provenance_strip sha={@doc.verified_at} />
        </div>
      </div>

      <div class="flex-1 overflow-y-auto px-8 py-6">
        <article class="prose prose-sm max-w-none text-base-content">
          {Phoenix.HTML.raw(@preview_html)}
        </article>
      </div>
    </div>
    """
  end

  # ── Sub-state: editor (frontmatter form + textarea + preview) ──────────

  attr(:page, :any, required: true)
  attr(:editor_content, :string, required: true)
  attr(:preview_html, :string, required: true)
  attr(:save_error, :string, default: nil)
  attr(:fm_form, :any, default: nil)
  attr(:fm_complex, :string, default: nil)

  defp editor(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Editor toolbar --%>
      <div class="flex items-center justify-between border-b border-edge px-6 py-3">
        <div class="flex items-center gap-3">
          <span class={[file_icon(@page.file_key), "size-5 text-warning"]}></span>
          <div>
            <h1 class="text-lg font-bold">
              Editing {@page.file_key}
            </h1>
            <p class="text-xs text-subtle">
              Markdown supported · Changes are not saved until you click Save
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button phx-click="cancel_edit" class="btn btn-ghost btn-sm">
            Cancel
          </button>
          <button
            id="org-memory-save-btn"
            phx-click={JS.dispatch("org-memory:save", to: "#org-memory-editor")}
            class="btn btn-primary btn-sm gap-1"
          >
            <span class="hero-check size-4"></span> Save
          </button>
        </div>
      </div>

      <%!-- Error banner --%>
      <div
        :if={@save_error}
        class="mx-6 mt-3 rounded-lg bg-error/10 border border-error/20 px-4 py-2 text-sm text-error"
      >
        {@save_error}
      </div>

      <%!-- Frontmatter editor (flat string-keyed scalars) --%>
      <.form
        :if={@fm_form}
        for={@fm_form}
        id="org-memory-frontmatter-form"
        phx-change="update_frontmatter"
        phx-submit="save_page"
        class="border-b border-edge bg-base-200/40 px-6 py-3"
      >
        <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content">
          Frontmatter
        </h2>
        <div class="grid grid-cols-2 gap-x-6 gap-y-1">
          <%= for key <- frontmatter_keys(@fm_form) do %>
            <%= if key == "preamble" do %>
              <.input type="checkbox" field={@fm_form[key]} label="preamble" />
            <% else %>
              <.input type="text" field={@fm_form[key]} label={key} />
            <% end %>
          <% end %>
        </div>
      </.form>

      <%!-- Complex frontmatter fallback: read-only, edit YAML in body --%>
      <div :if={@fm_complex} class="border-b border-edge bg-base-200/40 px-6 py-3">
        <h2 class="mb-2 text-xs font-semibold uppercase tracking-wider text-base-content">
          Frontmatter
        </h2>
        <pre
          class="rounded-lg bg-base-100 p-3 font-mono text-xs text-base-content overflow-x-auto"
          data-role="complex-frontmatter"
        >{@fm_complex}</pre>
        <p class="mt-1 text-xs text-subtle">
          complex frontmatter — edit YAML directly in body
        </p>
      </div>

      <%!-- Split editor + preview --%>
      <div class="flex flex-1 overflow-hidden">
        <%!-- Editor pane --%>
        <div class="flex flex-1 flex-col border-r border-edge">
          <div class="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-base-content border-b border-edge">
            Markdown
          </div>
          <textarea
            id="org-memory-editor"
            phx-hook="MarkdownEditor"
            phx-debounce="300"
            class="flex-1 resize-none bg-base-100 p-4 font-mono text-sm text-base-content focus:outline-none"
            spellcheck="false"
          >{@editor_content}</textarea>
        </div>

        <%!-- Preview pane --%>
        <div class="flex flex-1 flex-col">
          <div class="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-base-content border-b border-edge">
            Preview
          </div>
          <div class="flex-1 overflow-y-auto px-6 py-4">
            <article class="prose prose-sm max-w-none text-base-content">
              {Phoenix.HTML.raw(@preview_html)}
            </article>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── Empty state ─────────────────────────────────────────────────────────

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-1 items-center justify-center">
      <div class="text-center">
        <span class="hero-document-text mb-3 size-16 text-subtle mx-auto block"></span>
        <h3 class="text-lg font-medium text-base-content">Org memory</h3>
        <p class="mt-1 text-sm text-subtle">
          Select a page from the namespace tree to view or edit organizational memory.
        </p>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  # Stable key order for the frontmatter rows (maps are unordered).
  # LiveView's `_unused_*` change-tracking params are not real keys.
  defp frontmatter_keys(form) do
    form.params
    |> Map.keys()
    |> Enum.reject(&String.starts_with?(&1, "_"))
    |> Enum.sort()
  end

  defp line_count(content) when is_binary(content) do
    content |> String.split("\n") |> length()
  end

  defp line_count(_), do: 0
end
