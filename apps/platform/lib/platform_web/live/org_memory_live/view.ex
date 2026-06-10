defmodule PlatformWeb.OrgMemoryLive do
  @moduledoc """
  Org Memory wiki LiveView (ADR-0041 T7).

  Three-pane shell (stage 3):

    * left — `PlatformWeb.OrgMemoryLive.NamespaceTree` (collapsible
      namespace tree over `Wiki.list_pages/1`)
    * main — `PlatformWeb.OrgMemoryLive.PageViewer` (stage-4 stub) plus
      the carried-over editor / create panels
    * right — `PlatformWeb.OrgMemoryLive.RightPane` (stage-5 stub)

  State lives here; the pane modules are stateless function components.
  `@view_mode` is `:pages` only for now — the enum extends when the
  top-bar tabs land in stage 6.

  Routes: `/org_memory` (`:index`) and `/org_memory/:file_key` (`:show`).
  Legacy `/org-context*` paths 301-redirect in `PageController`.
  """

  use PlatformWeb, :live_view

  alias Platform.Org.Context
  alias Platform.Org.Wiki
  alias PlatformWeb.OrgMemoryLive.NamespaceTree
  alias PlatformWeb.OrgMemoryLive.PageViewer
  alias PlatformWeb.OrgMemoryLive.RightPane

  @impl true
  def mount(_params, _session, socket) do
    pages = Wiki.list_pages()
    tree = NamespaceTree.build(pages)

    {:ok,
     socket
     |> assign(:page_title, "Org Memory")
     |> assign(:pages, pages)
     |> assign(:namespace_tree, tree)
     |> assign(:expanded_prefixes, NamespaceTree.default_expanded(tree))
     |> assign(:selected_page, nil)
     |> assign(:view_mode, :pages)
     |> assign(:editing, false)
     |> assign(:editor_content, "")
     |> assign(:preview_html, "")
     |> assign(:creating, false)
     |> assign(:new_file_key, "")
     |> assign(:new_file_template, nil)
     |> assign(:save_error, nil)
     |> assign(:confirm_delete, nil)}
  end

  @impl true
  def handle_params(%{"file_key" => file_key}, _url, socket) do
    case Wiki.get_page(file_key) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Page not found: #{file_key}")
         |> push_patch(to: ~p"/org_memory")}

      page ->
        {:noreply,
         socket
         |> assign(:selected_page, page)
         |> assign(:editor_content, page.content)
         |> assign(:preview_html, render_markdown(page.content))
         |> assign(:editing, false)
         |> assign(:creating, false)
         |> assign(:save_error, nil)
         |> assign(:confirm_delete, nil)
         |> update(
           :expanded_prefixes,
           &MapSet.union(&1, NamespaceTree.ancestor_prefixes(page.file_key))
         )}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_page, nil)
     |> assign(:editing, false)
     |> assign(:creating, false)}
  end

  # ── Events: tree ────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_page", %{"file_key" => file_key}, socket) do
    {:noreply, push_patch(socket, to: ~p"/org_memory/#{file_key}")}
  end

  @impl true
  def handle_event("toggle_namespace", %{"prefix" => prefix}, socket) do
    {:noreply,
     update(socket, :expanded_prefixes, fn expanded ->
       if MapSet.member?(expanded, prefix) do
         MapSet.delete(expanded, prefix)
       else
         MapSet.put(expanded, prefix)
       end
     end)}
  end

  # ── Events: editing ─────────────────────────────────────────────────────

  @impl true
  def handle_event("start_edit", _params, socket) do
    {:noreply, assign(socket, :editing, true)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    page = socket.assigns.selected_page

    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:editor_content, page.content)
     |> assign(:save_error, nil)}
  end

  @impl true
  def handle_event("update_preview", %{"content" => content}, socket) do
    {:noreply,
     socket
     |> assign(:editor_content, content)
     |> assign(:preview_html, render_markdown(content))}
  end

  @impl true
  def handle_event("save_file", %{"content" => content}, socket) do
    %{selected_page: page, current_user_id: current_user_id} = socket.assigns

    case Wiki.upsert_page(page.file_key, %{content: content, updated_by: current_user_id}) do
      {:ok, updated_page} ->
        {:noreply,
         socket
         |> refresh_pages()
         |> assign(:selected_page, updated_page)
         |> assign(:editor_content, updated_page.content)
         |> assign(:preview_html, render_markdown(updated_page.content))
         |> assign(:editing, false)
         |> assign(:save_error, nil)
         |> put_flash(:info, "#{updated_page.file_key} saved (v#{updated_page.version})")}

      {:error, :stale} ->
        {:noreply,
         assign(
           socket,
           :save_error,
           "Page was updated elsewhere — reload and re-apply your edit."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :save_error, changeset_error_message(changeset))}
    end
  end

  # ── Events: create ──────────────────────────────────────────────────────

  @impl true
  def handle_event("show_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
     |> assign(:new_file_key, "")
     |> assign(:new_file_template, nil)}
  end

  @impl true
  def handle_event("cancel_create", _params, socket) do
    {:noreply, assign(socket, :creating, false)}
  end

  @impl true
  def handle_event("select_template", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> assign(:new_file_key, key)
     |> assign(:new_file_template, Context.default_template(key))}
  end

  @impl true
  def handle_event("update_new_file_key", %{"value" => value}, socket) do
    {:noreply, assign(socket, :new_file_key, value)}
  end

  @impl true
  def handle_event("create_file", %{"file_key" => file_key}, socket) do
    file_key = String.trim(file_key)

    # Ensure .md extension
    file_key =
      if String.ends_with?(file_key, ".md"), do: file_key, else: file_key <> ".md"

    template =
      Context.default_template(file_key) || "# #{String.replace(file_key, ".md", "")}\n\n"

    case Wiki.upsert_page(file_key, %{
           content: template,
           updated_by: socket.assigns.current_user_id
         }) do
      {:ok, _page} ->
        {:noreply,
         socket
         |> refresh_pages()
         |> assign(:creating, false)
         |> push_patch(to: ~p"/org_memory/#{file_key}")
         |> put_flash(:info, "Created #{file_key}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error_message(changeset))}

      {:error, :stale} ->
        {:noreply, put_flash(socket, :error, "Conflicting update for #{file_key} — try again")}
    end
  end

  # ── Events: delete ──────────────────────────────────────────────────────

  @impl true
  def handle_event("confirm_delete", %{"key" => file_key}, socket) do
    {:noreply, assign(socket, :confirm_delete, file_key)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, :confirm_delete, nil)}
  end

  @impl true
  def handle_event("delete_file", %{"key" => file_key}, socket) do
    case Wiki.delete_page(file_key) do
      {:ok, _} ->
        {:noreply,
         socket
         |> refresh_pages()
         |> assign(:confirm_delete, nil)
         |> push_patch(to: ~p"/org_memory")
         |> put_flash(:info, "Deleted #{file_key}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{file_key}")}
    end
  end

  # ── Events: seeding ─────────────────────────────────────────────────────

  @impl true
  def handle_event("seed_defaults", _params, socket) do
    Context.seed_defaults(updated_by: socket.assigns.current_user_id)

    {:noreply,
     socket
     |> refresh_pages()
     |> put_flash(:info, "Default org memory pages created")}
  end

  # ── Rendering ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="grid grid-cols-[16rem_minmax(0,1fr)_18rem] h-full overflow-hidden">
      <NamespaceTree.namespace_tree
        tree={@namespace_tree}
        expanded_prefixes={@expanded_prefixes}
        selected_file_key={@selected_page && @selected_page.file_key}
      />

      <div class="flex min-h-0 flex-col overflow-hidden">
        <%= if @creating do %>
          <.create_panel
            new_file_key={@new_file_key}
            new_file_template={@new_file_template}
            pages={@pages}
          />
        <% else %>
          <%= if @editing && @selected_page do %>
            <.editor_panel
              page={@selected_page}
              editor_content={@editor_content}
              preview_html={@preview_html}
              save_error={@save_error}
            />
          <% else %>
            <PageViewer.page_viewer
              page={@selected_page}
              preview_html={@preview_html}
              confirm_delete={@confirm_delete}
            />
          <% end %>
        <% end %>
      </div>

      <RightPane.right_pane page={@selected_page} />
    </div>
    """
  end

  # ── Local panels (editor flow stays here until a later stage) ───────────

  attr(:page, :any, required: true)
  attr(:editor_content, :string, required: true)
  attr(:preview_html, :string, required: true)
  attr(:save_error, :string, default: nil)

  defp editor_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Editor toolbar --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div class="flex items-center gap-3">
          <span class={[NamespaceTree.file_icon(@page.file_key), "size-5 text-warning"]}></span>
          <div>
            <h1 class="text-lg font-bold">
              Editing {@page.file_key}
            </h1>
            <p class="text-xs text-base-content/40">
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

      <%!-- Split editor + preview --%>
      <div class="flex flex-1 overflow-hidden">
        <%!-- Editor pane --%>
        <div class="flex flex-1 flex-col border-r border-base-300">
          <div class="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-base-content/40 border-b border-base-300">
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
          <div class="px-4 py-2 text-xs font-semibold uppercase tracking-wider text-base-content/40 border-b border-base-300">
            Preview
          </div>
          <div class="flex-1 overflow-y-auto px-6 py-4">
            <article class="prose prose-sm max-w-none text-base-content">
              {raw(@preview_html)}
            </article>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr(:new_file_key, :string, required: true)
  attr(:new_file_template, :string, default: nil)
  attr(:pages, :list, required: true)

  defp create_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div>
          <h1 class="text-lg font-bold">Create Memory Page</h1>
          <p class="text-xs text-base-content/40">Choose a template or create a custom page</p>
        </div>
        <button phx-click="cancel_create" class="btn btn-ghost btn-sm">
          Cancel
        </button>
      </div>

      <div class="flex-1 overflow-y-auto px-6 py-6">
        <%!-- Template cards --%>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Templates
        </h2>
        <div class="grid grid-cols-2 gap-3 mb-8">
          <%= for {key, _template} <- Context.default_templates() do %>
            <% existing = Enum.any?(@pages, &(&1.file_key == key)) %>
            <button
              phx-click="select_template"
              phx-value-key={key}
              disabled={existing}
              class={[
                "flex flex-col items-start rounded-lg border p-4 text-left transition-colors",
                if(existing,
                  do: "border-base-300 bg-base-200/50 opacity-50 cursor-not-allowed",
                  else: "border-base-300 hover:border-primary hover:bg-primary/5 cursor-pointer"
                ),
                if(@new_file_key == key,
                  do: "border-primary bg-primary/5 ring-1 ring-primary",
                  else: ""
                )
              ]}
            >
              <span class={[
                NamespaceTree.file_icon(key),
                "size-5 mb-2",
                if(existing, do: "text-base-content/30", else: "text-primary")
              ]}>
              </span>
              <span class="text-sm font-medium">{key}</span>
              <span class="text-xs text-base-content/40 mt-0.5">
                {template_description(key)}
              </span>
              <span :if={existing} class="mt-1 text-xs text-base-content/30">
                Already exists
              </span>
            </button>
          <% end %>
        </div>

        <%!-- Custom page input --%>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Custom Page
        </h2>
        <div class="flex items-end gap-3">
          <div class="flex-1">
            <label class="text-xs text-base-content/50 mb-1 block">
              Page path (e.g. <code>org/custom.md</code>)
            </label>
            <input
              type="text"
              value={@new_file_key}
              phx-keyup="update_new_file_key"
              placeholder="org/custom.md"
              class="input input-bordered input-sm w-full font-mono"
            />
          </div>
          <button
            phx-click="create_file"
            phx-value-file_key={@new_file_key}
            disabled={@new_file_key == ""}
            class="btn btn-primary btn-sm gap-1"
          >
            <span class="hero-plus size-4"></span> Create
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp refresh_pages(socket) do
    pages = Wiki.list_pages()
    tree = NamespaceTree.build(pages)

    socket
    |> assign(:pages, pages)
    |> assign(:namespace_tree, tree)
    |> update(:expanded_prefixes, &MapSet.union(&1, NamespaceTree.default_expanded(tree)))
  end

  defp changeset_error_message(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp render_markdown(nil), do: ""
  defp render_markdown(""), do: ""

  defp render_markdown(content) do
    options = %Earmark.Options{
      code_class_prefix: "language-",
      smartypants: false,
      breaks: true
    }

    case Earmark.as_html(content, options) do
      {:ok, html, _warnings} ->
        html

      {:error, _html, _errors} ->
        Phoenix.HTML.html_escape(content) |> Phoenix.HTML.safe_to_string()
    end
  end

  defp template_description("org/identity.md"), do: "Mission, values, product summary"
  defp template_description("org/memory.md"), do: "Long-term curated org knowledge"
  defp template_description("org/agents.md"), do: "Agent registry and roles"
  defp template_description("org/directory.md"), do: "Auto-generated user/agent roster"
  defp template_description(_), do: "Custom memory page"
end
