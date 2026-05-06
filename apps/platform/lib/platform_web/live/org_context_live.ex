defmodule PlatformWeb.OrgContextLive do
  use PlatformWeb, :live_view

  alias Platform.Org.Context

  @impl true
  def mount(_params, _session, socket) do
    files = Context.list_files()

    {:ok,
     socket
     |> assign(:page_title, "Org Context")
     |> assign(:files, files)
     |> assign(:selected_file, nil)
     |> assign(:editing, false)
     |> assign(:editor_content, "")
     |> assign(:preview_html, "")
     |> assign(:creating, false)
     |> assign(:new_file_key, "")
     |> assign(:new_file_template, nil)
     |> assign(:save_error, nil)
     |> assign(:confirm_delete, nil)
     |> assign(:view_mode, :files)
     |> assign(:memory_entries, [])
     |> assign(:memory_authors, %{})
     |> assign(:memory_search, "")}
  end

  @impl true
  def handle_params(%{"file_key" => file_key}, _url, socket) do
    case Context.get_file(file_key) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "File not found: #{file_key}")
         |> push_patch(to: ~p"/org-context")}

      file ->
        preview = render_markdown(file.content)

        {:noreply,
         socket
         |> assign(:selected_file, file)
         |> assign(:editor_content, file.content)
         |> assign(:preview_html, preview)
         |> assign(:editing, false)
         |> assign(:creating, false)
         |> assign(:save_error, nil)
         |> assign(:confirm_delete, nil)}
    end
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:selected_file, nil)
     |> assign(:editing, false)
     |> assign(:creating, false)}
  end

  # ── Events ──────────────────────────────────────────────────────────────

  @impl true
  def handle_event("select_file", %{"key" => file_key}, socket) do
    {:noreply, push_patch(socket, to: ~p"/org-context/#{file_key}")}
  end

  @impl true
  def handle_event("start_edit", _params, socket) do
    {:noreply, assign(socket, :editing, true)}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    file = socket.assigns.selected_file

    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:editor_content, file.content)
     |> assign(:save_error, nil)}
  end

  @impl true
  def handle_event("update_preview", %{"content" => content}, socket) do
    preview = render_markdown(content)

    {:noreply,
     socket
     |> assign(:editor_content, content)
     |> assign(:preview_html, preview)}
  end

  @impl true
  def handle_event("save_file", %{"content" => content}, socket) do
    %{selected_file: file, current_user: current_user} = socket.assigns

    case Context.upsert_file(%{
           file_key: file.file_key,
           content: content,
           updated_by: current_user
         }) do
      {:ok, updated_file} ->
        files = Context.list_files()
        preview = render_markdown(updated_file.content)

        {:noreply,
         socket
         |> assign(:files, files)
         |> assign(:selected_file, updated_file)
         |> assign(:editor_content, updated_file.content)
         |> assign(:preview_html, preview)
         |> assign(:editing, false)
         |> assign(:save_error, nil)
         |> put_flash(:info, "#{file.file_key} saved (v#{updated_file.version})")}

      {:error, changeset} ->
        error_msg =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply, assign(socket, :save_error, error_msg)}
    end
  end

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

    case Context.upsert_file(%{
           file_key: file_key,
           content: template,
           updated_by: socket.assigns.current_user
         }) do
      {:ok, _file} ->
        files = Context.list_files()

        {:noreply,
         socket
         |> assign(:files, files)
         |> assign(:creating, false)
         |> push_patch(to: ~p"/org-context/#{file_key}")
         |> put_flash(:info, "Created #{file_key}")}

      {:error, changeset} ->
        error_msg =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply, put_flash(socket, :error, error_msg)}
    end
  end

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
    case Context.delete_file(file_key) do
      {:ok, _} ->
        files = Context.list_files()

        {:noreply,
         socket
         |> assign(:files, files)
         |> assign(:confirm_delete, nil)
         |> push_patch(to: ~p"/org-context")
         |> put_flash(:info, "Deleted #{file_key}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete #{file_key}")}
    end
  end

  @impl true
  def handle_event("switch_to_files", _params, socket) do
    {:noreply, assign(socket, :view_mode, :files)}
  end

  @impl true
  def handle_event("switch_to_memory", _params, socket) do
    entries = Context.recent_memory(7)
    authors = Context.resolve_authors(entries)

    {:noreply,
     socket
     |> assign(:view_mode, :memory)
     |> assign(:memory_entries, entries)
     |> assign(:memory_authors, authors)
     |> assign(:selected_file, nil)
     |> assign(:editing, false)
     |> assign(:creating, false)}
  end

  @impl true
  def handle_event("memory_search", %{"query" => query}, socket) do
    opts = if query == "", do: [], else: [query: query]
    entries = Context.recent_memory(7, opts)
    authors = Context.resolve_authors(entries)

    {:noreply,
     socket
     |> assign(:memory_entries, entries)
     |> assign(:memory_authors, authors)
     |> assign(:memory_search, query)}
  end

  @impl true
  def handle_event("seed_defaults", _params, socket) do
    Context.seed_defaults(updated_by: socket.assigns.current_user)
    files = Context.list_files()

    {:noreply,
     socket
     |> assign(:files, files)
     |> put_flash(:info, "Default org context files created")}
  end

  # ── Rendering ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full overflow-hidden">
      <%!-- Sidebar --%>
      <aside class="flex w-64 flex-col border-r border-base-300 bg-base-200/40">
        <%!-- Tab switcher --%>
        <div class="flex border-b border-base-300">
          <button
            phx-click="switch_to_files"
            class={[
              "flex-1 px-4 py-2.5 text-xs font-semibold uppercase tracking-wider transition-colors",
              if(@view_mode == :files,
                do: "text-primary border-b-2 border-primary",
                else: "text-base-content/40 hover:text-base-content/60"
              )
            ]}
          >
            Files
          </button>
          <button
            phx-click="switch_to_memory"
            class={[
              "flex-1 px-4 py-2.5 text-xs font-semibold uppercase tracking-wider transition-colors",
              if(@view_mode == :memory,
                do: "text-primary border-b-2 border-primary",
                else: "text-base-content/40 hover:text-base-content/60"
              )
            ]}
          >
            Memory
          </button>
        </div>

        <%= if @view_mode == :files do %>
          <%!-- Files header --%>
          <div class="flex items-center justify-between px-4 py-3">
            <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/50">
              Context Files
            </h2>
            <button
              phx-click="show_create"
              class="rounded-lg p-1 text-base-content/50 hover:bg-base-300 hover:text-base-content transition-colors"
              title="New file"
            >
              <span class="hero-plus size-4"></span>
            </button>
          </div>

          <%!-- File list --%>
          <div class="flex-1 overflow-y-auto py-2">
            <%= if @files == [] do %>
              <div class="px-4 py-8 text-center">
                <span class="hero-document-text mb-2 size-8 text-base-content/30 mx-auto block">
                </span>
                <p class="text-sm text-base-content/40 mb-3">No context files yet</p>
                <button
                  phx-click="seed_defaults"
                  class="btn btn-primary btn-xs"
                >
                  Create defaults
                </button>
              </div>
            <% else %>
              <%= for file <- @files do %>
                <button
                  phx-click="select_file"
                  phx-value-key={file.file_key}
                  class={[
                    "flex w-full items-center gap-2 px-4 py-2 text-left text-sm transition-colors hover:bg-base-300",
                    if(@selected_file && @selected_file.id == file.id,
                      do: "bg-base-300 text-primary font-medium",
                      else: "text-base-content/70"
                    )
                  ]}
                >
                  <span class={file_icon(file.file_key)}></span>
                  <span class="truncate">{file.file_key}</span>
                  <span class="ml-auto text-xs text-base-content/30">v{file.version}</span>
                </button>
              <% end %>
            <% end %>
          </div>

          <%!-- Sidebar footer --%>
          <div class="border-t border-base-300 px-4 py-3">
            <button
              phx-click="seed_defaults"
              class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-xs text-base-content/40 hover:bg-base-300 hover:text-base-content/60 transition-colors"
            >
              <span class="hero-arrow-path size-3.5"></span> Seed missing defaults
            </button>
          </div>
        <% else %>
          <%!-- Memory sidebar: search + type legend --%>
          <div class="px-4 py-3">
            <form phx-change="memory_search" phx-submit="memory_search">
              <input
                type="text"
                name="query"
                value={@memory_search}
                phx-debounce="300"
                placeholder="Search memory..."
                class="input input-bordered input-sm w-full"
              />
            </form>
          </div>
          <div class="flex-1 overflow-y-auto px-4 py-2">
            <div class="space-y-2 text-xs text-base-content/50">
              <div class="flex items-center gap-2">
                <span class="inline-block size-2 rounded-full bg-info"></span> Daily notes
              </div>
              <div class="flex items-center gap-2">
                <span class="inline-block size-2 rounded-full bg-success"></span> Long-term memory
              </div>
            </div>
          </div>
        <% end %>
      </aside>

      <%!-- Main content area --%>
      <div class="flex flex-1 flex-col overflow-hidden">
        <%= if @view_mode == :memory do %>
          <.memory_feed entries={@memory_entries} authors={@memory_authors} />
        <% else %>
          <%= if @creating do %>
            <.create_panel
              new_file_key={@new_file_key}
              new_file_template={@new_file_template}
              files={@files}
            />
          <% else %>
            <%= if @selected_file do %>
              <%= if @editing do %>
                <.editor_panel
                  file={@selected_file}
                  editor_content={@editor_content}
                  preview_html={@preview_html}
                  save_error={@save_error}
                />
              <% else %>
                <.viewer_panel
                  file={@selected_file}
                  preview_html={@preview_html}
                  confirm_delete={@confirm_delete}
                />
              <% end %>
            <% else %>
              <.empty_state />
            <% end %>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  # ── Sub-components ──────────────────────────────────────────────────────

  defp empty_state(assigns) do
    ~H"""
    <div class="flex flex-1 items-center justify-center">
      <div class="text-center">
        <span class="hero-document-text mb-3 size-16 text-base-content/20 mx-auto block"></span>
        <h3 class="text-lg font-medium text-base-content/50">Org Context</h3>
        <p class="mt-1 text-sm text-base-content/40">
          Select a file from the sidebar to view or edit organizational context.
        </p>
      </div>
    </div>
    """
  end

  defp viewer_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Toolbar --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div class="flex items-center gap-3">
          <span class={[file_icon(@file.file_key), "size-5 text-primary"]}></span>
          <div>
            <h1 class="text-lg font-bold">{@file.file_key}</h1>
            <p class="text-xs text-base-content/40">
              Version {@file.version}
              <span :if={@file.updated_at}>
                · Updated {format_relative(@file.updated_at)}
              </span>
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="start_edit"
            class="btn btn-primary btn-sm gap-1"
          >
            <span class="hero-pencil-square size-4"></span> Edit
          </button>
          <div class="relative">
            <button
              phx-click="confirm_delete"
              phx-value-key={@file.file_key}
              class="btn btn-ghost btn-sm text-error/60 hover:text-error"
              title="Delete file"
            >
              <span class="hero-trash size-4"></span>
            </button>
            <%!-- Delete confirmation popover --%>
            <%= if @confirm_delete == @file.file_key do %>
              <div class="absolute right-0 top-full mt-1 z-50 rounded-lg border border-base-300 bg-base-100 p-4 shadow-lg w-64">
                <p class="text-sm font-medium mb-3">
                  Delete {@file.file_key}?
                </p>
                <p class="text-xs text-base-content/50 mb-3">
                  This action cannot be undone.
                </p>
                <div class="flex justify-end gap-2">
                  <button phx-click="cancel_delete" class="btn btn-ghost btn-xs">
                    Cancel
                  </button>
                  <button
                    phx-click="delete_file"
                    phx-value-key={@file.file_key}
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
          {raw(@preview_html)}
        </article>
      </div>

      <%!-- File metadata footer --%>
      <div class="flex items-center gap-4 border-t border-base-300 px-6 py-2 text-xs text-base-content/40">
        <span class="flex items-center gap-1">
          <span class="hero-document size-3.5"></span>
          {byte_size(@file.content)} bytes
        </span>
        <span class="flex items-center gap-1">
          <span class="hero-hashtag size-3.5"></span>
          {line_count(@file.content)} lines
        </span>
        <span class="flex items-center gap-1">
          <span class="hero-arrow-up-circle size-3.5"></span> v{@file.version}
        </span>
        <span :if={@file.inserted_at} class="flex items-center gap-1">
          <span class="hero-clock size-3.5"></span>
          Created {Calendar.strftime(@file.inserted_at, "%b %-d, %Y")}
        </span>
      </div>
    </div>
    """
  end

  defp editor_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Editor toolbar --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div class="flex items-center gap-3">
          <span class={[file_icon(@file.file_key), "size-5 text-warning"]}></span>
          <div>
            <h1 class="text-lg font-bold">
              Editing {@file.file_key}
            </h1>
            <p class="text-xs text-base-content/40">
              Markdown supported · Changes are not saved until you click Save
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <button
            phx-click="cancel_edit"
            class="btn btn-ghost btn-sm"
          >
            Cancel
          </button>
          <button
            id="org-context-save-btn"
            phx-click={JS.dispatch("org-context:save", to: "#org-context-editor")}
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
            id="org-context-editor"
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

  defp create_panel(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div>
          <h1 class="text-lg font-bold">Create Context File</h1>
          <p class="text-xs text-base-content/40">Choose a template or create a custom file</p>
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
            <% existing = Enum.any?(@files, &(&1.file_key == key)) %>
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
                file_icon(key),
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

        <%!-- Custom file input --%>
        <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
          Custom File
        </h2>
        <div class="flex items-end gap-3">
          <div class="flex-1">
            <label class="text-xs text-base-content/50 mb-1 block">File name (UPPER_CASE.md)</label>
            <input
              type="text"
              value={@new_file_key}
              phx-keyup="update_new_file_key"
              placeholder="CUSTOM_CONTEXT.md"
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

  defp memory_feed(assigns) do
    ~H"""
    <div class="flex flex-1 flex-col overflow-hidden">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-3">
        <div>
          <h1 class="text-lg font-bold">Org Memory Feed</h1>
          <p class="text-xs text-base-content/40">
            Recent memory entries from the last 7 days
          </p>
        </div>
      </div>

      <%!-- Feed content --%>
      <div class="flex-1 overflow-y-auto px-6 py-4">
        <%= if @entries == [] do %>
          <div class="flex flex-col items-center justify-center py-16">
            <span class="hero-light-bulb mb-3 size-12 text-base-content/20 block"></span>
            <h3 class="text-base font-medium text-base-content/50">No memory entries yet</h3>
            <p class="mt-1 text-sm text-base-content/40 max-w-sm text-center">
              Memory entries are created by agents as they work. Daily notes and long-term insights will appear here.
            </p>
          </div>
        <% else %>
          <div class="space-y-6">
            <%= for {date, entries} <- @entries do %>
              <div>
                <%!-- Date header --%>
                <div class="sticky top-0 z-10 flex items-center gap-3 bg-base-100 py-2">
                  <span class="text-sm font-semibold text-base-content/70">
                    {format_memory_date(date)}
                  </span>
                  <div class="flex-1 border-t border-base-300"></div>
                  <span class="text-xs text-base-content/30">
                    {length(entries)} {if length(entries) == 1, do: "entry", else: "entries"}
                  </span>
                </div>

                <%!-- Day's entries --%>
                <div class="space-y-3 pl-2">
                  <%= for entry <- entries do %>
                    <div class="rounded-lg border border-base-300 bg-base-100 p-4">
                      <div class="mb-2 flex items-center gap-2">
                        <span class={[
                          "inline-block size-2 rounded-full",
                          if(entry.memory_type == "daily", do: "bg-info", else: "bg-success")
                        ]}>
                        </span>
                        <span class="text-xs font-medium text-base-content/60">
                          {String.capitalize(String.replace(entry.memory_type, "_", " "))}
                        </span>
                        <.author_byline
                          :if={entry.authored_by}
                          authors={@authors}
                          id={entry.authored_by}
                        />
                        <span class="ml-auto text-xs text-base-content/30">
                          {Calendar.strftime(entry.inserted_at, "%H:%M")}
                        </span>
                      </div>
                      <article class="prose prose-sm max-w-none text-base-content">
                        {raw(render_markdown(entry.content))}
                      </article>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:authors, :map, required: true)
  attr(:id, :string, required: true)

  defp author_byline(assigns) do
    case Map.get(assigns.authors, assigns.id) do
      %{kind: :agent, name: name} ->
        assigns = assign(assigns, :name, name)

        ~H"""
        <span class="inline-flex items-center gap-1 text-xs text-base-content/40">
          <span class="hero-cpu-chip size-3"></span>
          <span>{@name}</span>
        </span>
        """

      %{kind: :user, name: name} ->
        assigns = assign(assigns, :name, name)

        ~H"""
        <span class="inline-flex items-center gap-1 text-xs text-base-content/40">
          <span class="hero-user size-3"></span>
          <span>{@name}</span>
        </span>
        """

      _ ->
        ~H"""
        <span class="text-xs text-base-content/30">
          by {truncate_id(@id)}
        </span>
        """
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

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

  defp file_icon("ORG_IDENTITY" <> _), do: "hero-identification size-4"
  defp file_icon("ORG_MEMORY" <> _), do: "hero-light-bulb size-4"
  defp file_icon("ORG_AGENTS" <> _), do: "hero-cpu-chip size-4"
  defp file_icon("ORG_DIRECTORY" <> _), do: "hero-users size-4"
  defp file_icon(_), do: "hero-document-text size-4"

  defp template_description("ORG_IDENTITY.md"), do: "Mission, values, product summary"
  defp template_description("ORG_MEMORY.md"), do: "Long-term curated org knowledge"
  defp template_description("ORG_AGENTS.md"), do: "Agent registry and roles"
  defp template_description("ORG_DIRECTORY.md"), do: "Auto-generated user/agent roster"
  defp template_description(_), do: "Custom context file"

  defp format_relative(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %-d, %Y")
    end
  end

  defp line_count(content) when is_binary(content) do
    content |> String.split("\n") |> length()
  end

  defp line_count(_), do: 0

  defp format_memory_date(date) do
    today = Date.utc_today()

    cond do
      date == today -> "Today"
      date == Date.add(today, -1) -> "Yesterday"
      true -> Calendar.strftime(date, "%A, %b %-d")
    end
  end

  defp truncate_id(id) when is_binary(id) do
    String.slice(id, 0, 8) <> "..."
  end

  defp truncate_id(_), do: ""
end
