defmodule PlatformWeb.ChangelogLive do
  use PlatformWeb, :live_view

  alias Platform.Changelog

  @page_size 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Changelog.subscribe()

    entries = Changelog.list_entries(limit: @page_size)
    grouped = Changelog.group_by_date(entries)

    {:ok,
     socket
     |> assign(:page_title, "Changelog")
     |> assign(:entries, entries)
     |> assign(:grouped, grouped)
     |> assign(:tag_filter, nil)
     |> assign(:has_more, length(entries) >= @page_size)
     |> assign(:loading_more, false)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_tag", %{"tag" => tag}, socket) do
    tag = if tag == "", do: nil, else: tag

    entries = Changelog.list_entries(tag: tag, limit: @page_size)
    grouped = Changelog.group_by_date(entries)

    {:noreply,
     socket
     |> assign(:tag_filter, tag)
     |> assign(:entries, entries)
     |> assign(:grouped, grouped)
     |> assign(:has_more, length(entries) >= @page_size)}
  end

  @impl true
  def handle_event("load_more", _params, socket) do
    %{entries: entries, tag_filter: tag} = socket.assigns
    oldest = List.last(entries)

    if oldest do
      more =
        Changelog.list_entries(
          tag: tag,
          before: oldest.merged_at,
          limit: @page_size
        )

      all_entries = entries ++ more
      grouped = Changelog.group_by_date(all_entries)

      {:noreply,
       socket
       |> assign(:entries, all_entries)
       |> assign(:grouped, grouped)
       |> assign(:has_more, length(more) >= @page_size)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:new_changelog_entry, entry}, socket) do
    entries = [entry | socket.assigns.entries]
    grouped = Changelog.group_by_date(entries)

    {:noreply,
     socket
     |> assign(:entries, entries)
     |> assign(:grouped, grouped)}
  end

  # ── Rendering ────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full flex-col">
      <%!-- Header --%>
      <div class="flex items-center justify-between border-b border-base-300 px-6 py-4">
        <div>
          <h1 class="text-xl font-bold">Changelog</h1>
          <p class="text-sm text-base-content/60">Recent changes merged to main</p>
        </div>
        <div>
          <select
            phx-change="filter_tag"
            name="tag"
            class="select select-sm select-bordered"
          >
            <option value="">All changes</option>
            <option value="feature" selected={@tag_filter == "feature"}>Features</option>
            <option value="fix" selected={@tag_filter == "fix"}>Fixes</option>
            <option value="improvement" selected={@tag_filter == "improvement"}>Improvements</option>
            <option value="chore" selected={@tag_filter == "chore"}>Chores</option>
            <option value="docs" selected={@tag_filter == "docs"}>Docs</option>
          </select>
        </div>
      </div>

      <%!-- Feed --%>
      <div class="flex-1 overflow-y-auto px-6 py-4">
        <%= if @grouped == [] do %>
          <div class="flex flex-col items-center justify-center py-16 text-base-content/40">
            <span class="hero-newspaper mb-3 size-12"></span>
            <p class="text-lg font-medium">No changes yet</p>
            <p class="text-sm">Merged PRs will appear here automatically.</p>
          </div>
        <% else %>
          <div class="space-y-8">
            <%= for {label, entries} <- @grouped do %>
              <div>
                <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/50">
                  {label}
                </h2>
                <div class="space-y-3">
                  <%= for entry <- entries do %>
                    <.changelog_entry entry={entry} />
                  <% end %>
                </div>
              </div>
            <% end %>
          </div>

          <%= if @has_more do %>
            <div class="mt-6 flex justify-center">
              <button
                phx-click="load_more"
                class="btn btn-ghost btn-sm"
              >
                Load more
              </button>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp changelog_entry(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-300 bg-base-100 p-4 transition-colors hover:bg-base-200/50">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0 flex-1">
          <%!-- Title + tags --%>
          <div class="flex flex-wrap items-center gap-2">
            <h3 class="font-medium">{@entry.title}</h3>
            <%= for tag <- @entry.tags do %>
              <.tag_badge tag={tag} />
            <% end %>
          </div>

          <%!-- Description --%>
          <%= if @entry.description do %>
            <p class="mt-1 line-clamp-2 text-sm text-base-content/60">
              {@entry.description}
            </p>
          <% end %>

          <%!-- Meta row: author, PR link, linked task --%>
          <div class="mt-2 flex flex-wrap items-center gap-3 text-xs text-base-content/50">
            <%= if @entry.author do %>
              <span class="flex items-center gap-1">
                <span class="hero-user-circle size-3.5"></span>
                {@entry.author}
              </span>
            <% end %>

            <%= if @entry.pr_url do %>
              <a
                href={@entry.pr_url}
                target="_blank"
                rel="noopener"
                class="flex items-center gap-1 hover:text-primary"
              >
                <span class="hero-arrow-top-right-on-square size-3.5"></span> PR #{@entry.pr_number}
              </a>
            <% end %>

            <%= if @entry.task do %>
              <.link
                navigate={"/tasks/#{@entry.task_id}"}
                class="flex items-center gap-1 hover:text-primary"
              >
                <span class="hero-rectangle-stack size-3.5"></span>
                {@entry.task.title}
              </.link>
            <% end %>

            <span class="text-base-content/30">
              {format_time(@entry.merged_at)}
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp tag_badge(assigns) do
    color =
      case assigns.tag do
        "feature" -> "badge-primary"
        "fix" -> "badge-error"
        "improvement" -> "badge-info"
        "chore" -> "badge-ghost"
        "docs" -> "badge-warning"
        _ -> "badge-ghost"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"badge badge-sm #{@color}"}>
      {@tag}
    </span>
    """
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%-I:%M %p")
  end
end
