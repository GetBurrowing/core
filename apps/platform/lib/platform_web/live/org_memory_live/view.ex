defmodule PlatformWeb.OrgMemoryLive do
  @moduledoc """
  Org Memory wiki LiveView (ADR-0041 T7).

  Three-pane shell:

    * left — `PlatformWeb.OrgMemoryLive.NamespaceTree` (collapsible
      namespace tree over `Wiki.list_pages/1`)
    * main — `PlatformWeb.OrgMemoryLive.PageViewer` (stage 4: viewer /
      editor / history-meta sub-states with wikilink-aware rendering
      via `PlatformWeb.OrgMemoryLive.MarkdownRenderer`) plus the
      create panel
    * right — `PlatformWeb.OrgMemoryLive.RightPane` (stage-5 stub)

  State lives here; the pane modules are stateless function components.
  `@view_mode` is `:pages` only for now — the enum extends when the
  top-bar tabs land in stage 6.

  Agent gate (design lock §6): the `"save_page"` handler fails closed
  when `current_user` is shaped like a `Platform.Agents.Agent` — UI
  editing is for humans; agents propose changes via `memory_create`.

  Routes: `/org_memory` (`:index`) and `/org_memory/:file_key` (`:show`).
  Legacy `/org-context*` paths 301-redirect in `PageController`.
  """

  use PlatformWeb, :live_view

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Org.Context
  alias Platform.Org.Wiki
  alias PlatformWeb.OrgMemoryLive.MarkdownRenderer
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
     |> assign(:confirm_delete, nil)
     |> assign(:fm_form, nil)
     |> assign(:fm_complex, nil)
     |> assign(:updated_by_display, nil)}
  end

  @impl true
  def handle_params(%{"file_key" => file_key}, _url, socket) do
    # Glob route — `file_key` arrives as a list of path segments.
    file_key = if is_list(file_key), do: Enum.join(file_key, "/"), else: file_key

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
         |> assign(:preview_html, render_markdown(page.content, socket.assigns.pages))
         |> assign(:editing, false)
         |> assign(:creating, false)
         |> assign(:save_error, nil)
         |> assign(:confirm_delete, nil)
         |> assign(:fm_form, nil)
         |> assign(:fm_complex, nil)
         |> assign(:updated_by_display, updated_by_display(page.updated_by))
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
    {:noreply, push_patch(socket, to: ~p"/org_memory/#{String.split(file_key, "/")}")}
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
    page = socket.assigns.selected_page
    {frontmatter, body} = Wiki.parse_frontmatter(page.content)

    socket =
      cond do
        frontmatter == %{} ->
          # No frontmatter — the textarea edits the full content.
          socket
          |> assign(:fm_form, nil)
          |> assign(:fm_complex, nil)
          |> assign(:editor_content, page.content)

        flat_frontmatter?(frontmatter) ->
          # Flat string-keyed scalars: one form row per key; the
          # textarea edits the body only (frontmatter is rebuilt from
          # the form on save).
          socket
          |> assign(:fm_form, to_form(frontmatter, as: :frontmatter))
          |> assign(:fm_complex, nil)
          |> assign(:editor_content, body)

        true ->
          # Nested / non-scalar frontmatter: read-only display, edit
          # the YAML directly in the body textarea.
          socket
          |> assign(:fm_form, nil)
          |> assign(:fm_complex, leading_frontmatter_block(page.content, body))
          |> assign(:editor_content, page.content)
      end

    {:noreply,
     socket
     |> assign(:editing, true)
     |> assign(
       :preview_html,
       render_markdown(socket.assigns.editor_content, socket.assigns.pages)
     )}
  end

  @impl true
  def handle_event("cancel_edit", _params, socket) do
    page = socket.assigns.selected_page

    {:noreply,
     socket
     |> assign(:editing, false)
     |> assign(:editor_content, page.content)
     |> assign(:preview_html, render_markdown(page.content, socket.assigns.pages))
     |> assign(:fm_form, nil)
     |> assign(:fm_complex, nil)
     |> assign(:save_error, nil)}
  end

  @impl true
  def handle_event("update_preview", %{"content" => content}, socket) do
    {:noreply,
     socket
     |> assign(:editor_content, content)
     |> assign(:preview_html, render_markdown(content, socket.assigns.pages))}
  end

  @impl true
  def handle_event("update_frontmatter", %{"frontmatter" => params}, socket) do
    {:noreply, assign(socket, :fm_form, to_form(params, as: :frontmatter))}
  end

  @impl true
  def handle_event("save_page", params, socket) do
    # Design lock §6: agents must propose changes via memory_create —
    # the UI save path fails closed for Agent-shaped users without
    # touching the domain layer.
    if agent_actor?(socket.assigns) do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Agents must propose changes via memory_create. UI editing is for humans only."
       )}
    else
      save_page(params, socket)
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
         |> push_patch(to: ~p"/org_memory/#{String.split(file_key, "/")}")
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
          <PageViewer.page_viewer
            page={@selected_page}
            editing={@editing}
            editor_content={@editor_content}
            preview_html={@preview_html}
            save_error={@save_error}
            confirm_delete={@confirm_delete}
            fm_form={@fm_form}
            fm_complex={@fm_complex}
            updated_by_display={@updated_by_display}
          />
        <% end %>
      </div>

      <RightPane.right_pane page={@selected_page} />
    </div>
    """
  end

  # ── Local panels (create flow stays here until a later stage) ───────────

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

  # Body source: explicit `content` param (textarea save via the
  # MarkdownEditor hook) or the tracked `@editor_content` (frontmatter
  # form submit). When the frontmatter form is active the textarea
  # holds the body only, so the serialized frontmatter block is
  # prepended before the upsert.
  defp save_page(params, socket) do
    %{selected_page: page, current_user_id: current_user_id} = socket.assigns

    body = Map.get(params, "content", socket.assigns.editor_content)
    content = prepend_frontmatter(body, params, socket.assigns.fm_form)

    case Wiki.upsert_page(page.file_key, %{content: content, updated_by: current_user_id}) do
      {:ok, updated_page} ->
        socket = refresh_pages(socket)

        {:noreply,
         socket
         |> assign(:selected_page, updated_page)
         |> assign(:editor_content, updated_page.content)
         |> assign(:preview_html, render_markdown(updated_page.content, socket.assigns.pages))
         |> assign(:editing, false)
         |> assign(:save_error, nil)
         |> assign(:fm_form, nil)
         |> assign(:fm_complex, nil)
         |> assign(:updated_by_display, updated_by_display(updated_page.updated_by))
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

  # Render markdown with wikilinks swapped. The lookup table is built
  # once per render: direct hits against the already-loaded `@pages`
  # list, `Wiki.resolve_alias/2` fallback for misses — so the renderer
  # itself stays pure (no DB calls inside `MarkdownRenderer.render/2`).
  defp render_markdown(content, pages) do
    MarkdownRenderer.render(content, wikilink_lookup(content, pages))
  end

  defp wikilink_lookup(content, pages) when is_binary(content) do
    page_keys = MapSet.new(pages, & &1.file_key)

    content
    |> Wiki.parse_wikilinks()
    |> Enum.map(& &1.target_path)
    |> Enum.uniq()
    |> Map.new(fn target ->
      cond do
        MapSet.member?(page_keys, target) ->
          {target, target}

        page = Wiki.resolve_alias(target) ->
          {target, page.file_key}

        true ->
          {target, nil}
      end
    end)
  end

  defp wikilink_lookup(_content, _pages), do: %{}

  # ── Agent gate (design lock §6) ─────────────────────────────────────────

  # `ShellLive` puts the user struct in `:current_user_record` (with a
  # display string in `:current_user`); check both shapes so an
  # Agent-shaped principal fails closed regardless of which assign it
  # arrived through.
  defp agent_actor?(assigns) do
    match?(%Agent{}, assigns[:current_user_record]) or match?(%Agent{}, assigns[:current_user])
  end

  # ── Frontmatter editor helpers ──────────────────────────────────────────

  defp flat_frontmatter?(frontmatter) do
    Enum.all?(frontmatter, fn {_key, value} ->
      is_binary(value) or is_boolean(value) or is_number(value) or is_nil(value)
    end)
  end

  # The frontmatter block is the leading slice of `content` that
  # `Wiki.parse_frontmatter/1` stripped to produce `body`.
  defp leading_frontmatter_block(content, body) do
    prefix_len = byte_size(content) - byte_size(body)
    binary_part(content, 0, max(prefix_len, 0))
  end

  # Rebuild the page content for the upsert. When the frontmatter form
  # is active, serialize its current values (submit params win over the
  # phx-change-tracked form state) into a YAML block and prepend it to
  # the body. Otherwise the body already is the full content.
  defp prepend_frontmatter(body, params, fm_form) do
    fm_params =
      case params do
        %{"frontmatter" => fm} when is_map(fm) -> fm
        _ -> fm_form && fm_form.params
      end

    if fm_params do
      serialize_frontmatter(fm_params) <> body
    else
      body
    end
  end

  # Hand-serialized YAML for flat string-keyed scalars (the only shape
  # the form edits — `Wiki.parse_frontmatter/1` produces string keys,
  # and non-scalar values route to the read-only fallback instead).
  # LiveView's `_unused_*` change-tracking params are dropped.
  defp serialize_frontmatter(params) do
    lines =
      params
      |> Enum.reject(fn {key, _value} -> String.starts_with?(key, "_") end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> "#{key}: #{yaml_scalar(value)}" end)

    "---\n" <> Enum.join(lines, "\n") <> "\n---\n"
  end

  defp yaml_scalar(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp yaml_scalar(nil), do: ~s("")

  defp yaml_scalar(value) when is_binary(value) do
    cond do
      value in ~w(true false) -> value
      match?({_, ""}, Integer.parse(value)) -> value
      match?({_, ""}, Float.parse(value)) -> value
      true -> inspect(value)
    end
  end

  defp yaml_scalar(value), do: inspect(to_string(value))

  # ── History meta ────────────────────────────────────────────────────────

  defp updated_by_display(nil), do: nil

  defp updated_by_display(user_id) do
    case Accounts.get_user(user_id) do
      %{name: name} when is_binary(name) and name != "" -> name
      %{email: email} when is_binary(email) -> email
      _ -> String.slice(user_id, 0, 8)
    end
  end

  defp template_description("org/identity.md"), do: "Mission, values, product summary"
  defp template_description("org/memory.md"), do: "Long-term curated org knowledge"
  defp template_description("org/agents.md"), do: "Agent registry and roles"
  defp template_description("org/directory.md"), do: "Auto-generated user/agent roster"
  defp template_description(_), do: "Custom memory page"
end
