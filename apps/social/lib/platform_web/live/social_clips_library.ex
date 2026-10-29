defmodule PlatformWeb.SocialClipsLibrary do
  @moduledoc "The current authorized profile's searchable, streamed clip Library."
  use PlatformWeb, :live_component

  alias Platform.{Accounts, Social}
  alias Platform.Social.ClipLibrary
  alias PlatformWeb.SocialCalendar
  alias Phoenix.LiveView.JS

  @filters [
    {"show", "Show"},
    {"episode", "Episode"},
    {"date", "Date"},
    {"platform", "Platform"},
    {"status", "Status"}
  ]
  @platforms [{"instagram", "IG"}, {"youtube", "YT"}, {"tiktok", "TT"}]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:filters, %{})
     |> assign(:show_chip?, false)
     |> assign(:loaded_profile_id, nil)
     |> stream_configure(:clips, dom_id: &"library-clip-#{&1.clip.id}")}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, Map.drop(assigns, [:refresh]))
    profile_id = socket.assigns[:profile] && socket.assigns.profile.id
    changed? = socket.assigns.loaded_profile_id != profile_id

    socket =
      if changed? do
        assign(socket, :show_chip?, socket.assigns.loaded_profile_id != nil)
      else
        socket
      end

    {:ok, socket |> assign(:loaded_profile_id, profile_id) |> load()}
  end

  @impl true
  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    {:noreply, socket |> assign(:filters, put_filter(socket.assigns.filters, "q", q)) |> load()}
  end

  def handle_event("filter", %{"key" => key, "option" => value}, socket)
      when key in ~w(episode date platform status) and is_binary(value) do
    filters = put_filter(socket.assigns.filters, key, value)
    {:noreply, load_filters(socket, filters)}
  end

  def handle_event("select_show", %{"profile_id" => id}, socket) do
    selected? = Enum.any?(visible_profiles(socket), &(&1.id == id))
    {:noreply, socket |> assign(:show_chip?, selected?) |> load()}
  end

  def handle_event("clear_filter", %{"key" => "show"}, socket),
    do: {:noreply, socket |> assign(:show_chip?, false) |> load()}

  def handle_event("clear_filter", %{"key" => key}, socket)
      when key in ~w(episode date platform status q) do
    {:noreply, socket |> assign(:filters, Map.delete(socket.assigns.filters, key)) |> load()}
  end

  def handle_event("clear_all", _params, socket) do
    {:noreply, socket |> assign(:filters, %{}) |> assign(:show_chip?, false) |> load()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, load(socket)}

  defp put_filter(filters, key, value) when value in [nil, ""], do: Map.delete(filters, key)
  defp put_filter(filters, key, value), do: Map.put(filters, key, value)

  # The parent owns profile selection. Re-read visibility for every update/event;
  # the client's filter values can never expand this read scope.
  defp visible_profiles(socket) do
    socket.assigns[:user_id] |> Accounts.get_user() |> Social.list_profiles_for_user()
  end

  defp authorized_profile(socket, profiles) do
    id = socket.assigns[:profile] && socket.assigns.profile.id
    Enum.find(profiles, &(&1.id == id))
  end

  defp load_filters(socket, filters) do
    profiles = visible_profiles(socket)

    case authorized_profile(socket, profiles) do
      nil ->
        load(socket)

      profile ->
        case ClipLibrary.list(profile.org_id, Map.put(filters, "show", profile.id)) do
          {:error, :invalid_filter} -> load(socket)
          result -> socket |> assign(:filters, filters) |> load_result(profiles, profile, result)
        end
    end
  end

  defp load(socket) do
    profiles = visible_profiles(socket)

    case authorized_profile(socket, profiles) do
      nil ->
        socket
        |> assign(:visible_profiles, [])
        |> assign(:library_profile, nil)
        |> assign(:counts, %{})
        |> assign(:total, 0)
        |> assign(:baseline, 0)
        |> assign(:menus, [])
        |> assign(:chips, [])
        |> stream(:clips, [], reset: true)

      profile ->
        result =
          ClipLibrary.list(profile.org_id, Map.put(socket.assigns.filters, "show", profile.id))

        load_result(socket, profiles, profile, result)
    end
  end

  defp load_result(socket, profiles, profile, result) do
    baseline = ClipLibrary.list(profile.org_id, %{"show" => profile.id}).total

    # Show uses the same list/count semantics but spans only the profiles this
    # user may select. Each profile may belong to a different visible org.
    show_counts =
      Map.new(profiles, fn p ->
        {p.id, ClipLibrary.list(p.org_id, Map.put(socket.assigns.filters, "show", p.id)).total}
      end)

    counts = Map.put(result.counts, "show", show_counts)
    filters = socket.assigns.filters

    chips =
      Enum.flat_map(@filters, fn {key, label} ->
        cond do
          key == "show" and socket.assigns.show_chip? -> [{key, label, profile.name}]
          key != "show" and filters[key] -> [{key, label, option_label(key, filters[key])}]
          true -> []
        end
      end)

    chips = if filters["q"], do: chips ++ [{"q", "Search", filters["q"]}], else: chips

    menus =
      Enum.map(@filters, fn {key, label} ->
        options =
          if key == "show" do
            Enum.map(profiles, &{&1.id, &1.name, Map.get(show_counts, &1.id, 0)})
          else
            options = Map.get(counts, key, %{})
            options = if filters[key], do: Map.put_new(options, filters[key], 0), else: options

            options
            |> Enum.sort()
            |> Enum.map(fn {value, count} -> {value, option_label(key, value), count} end)
          end

        %{key: key, label: label, options: options}
      end)

    socket
    |> assign(:visible_profiles, profiles)
    |> assign(:library_profile, profile)
    |> assign(:counts, counts)
    |> assign(:total, result.total)
    |> assign(:baseline, baseline)
    |> assign(:menus, menus)
    |> assign(:chips, chips)
    |> stream(:clips, result.items, reset: true)
  end

  defp option_label("date", "today"), do: "Today"
  defp option_label("date", "this_week"), do: "This week"
  defp option_label("date", "older"), do: "Older"
  defp option_label("platform", "instagram"), do: "Instagram"
  defp option_label("platform", "youtube"), do: "YouTube"
  defp option_label("platform", "tiktok"), do: "TikTok"
  defp option_label(_key, value), do: value

  defp duration(nil), do: ""

  defp duration(seconds) do
    seconds = trunc(seconds)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp meta(clip),
    do:
      Enum.reject([clip.episode_code, duration(clip.duration_s)], &(&1 in [nil, ""]))
      |> Enum.join(" · ")

  defp mark("Failed"), do: SocialCalendar.mark(:failed)
  defp mark("Rejected"), do: SocialCalendar.mark(:refused)
  defp mark("Scheduled"), do: SocialCalendar.mark(:scheduled)
  defp mark("Published"), do: SocialCalendar.mark(:published)
  defp mark("In review"), do: SocialCalendar.mark(:waiting)
  defp mark(_), do: SocialCalendar.mark(:uploading)

  defp platform_rows(item) do
    Enum.flat_map(@platforms, fn {platform, label} ->
      case Enum.filter(item.platforms, &(&1.platform == platform)) do
        [] ->
          [
            {label,
             if(platform in (item.clip.platforms || []), do: "Not posted", else: "Not selected"),
             nil}
          ]

        entries ->
          Enum.map(entries, &{label, platform_label(&1.state), &1.state})
      end
    end)
  end

  defp platform_label(:published), do: "Published"
  defp platform_label(:scheduled), do: "Scheduled"
  defp platform_label(:uploading), do: "Uploading"
  defp platform_label(:queued), do: "Queued"
  defp platform_label(:failed), do: "Failed"

  @impl true
  def render(assigns) do
    ~H"""
    <section id="social-clips-library" data-role="clips-library" class="space-y-4">
      <div class="flex flex-wrap items-center gap-3">
        <form phx-change="search" phx-submit="search" phx-target={@myself} class="min-w-0 flex-1">
          <label class="input input-bordered flex w-full items-center gap-2 border-base-300 bg-base-100">
            <.icon name="hero-magnifying-glass" class="size-4 shrink-0 text-subtle" />
            <input
              id="library-search"
              data-role="library-search"
              name="q"
              type="search"
              value={@filters["q"] || ""}
              phx-debounce="200"
              placeholder="Search title, caption, transcript"
              aria-label="Search title, caption, transcript"
              class="min-w-0 w-full bg-transparent text-sm"
            />
          </label>
        </form>
        <span class="text-xs text-subtle">sort: newest</span>
      </div>
      <div class="flex flex-wrap gap-2" data-role="library-filters">
        <details :for={menu <- @menus} id={"library-filter-#{menu.key}"} class="dropdown">
          <summary class="btn btn-sm border-base-300 bg-base-100" data-role="library-filter-trigger">
            {menu.label} ▾
          </summary>
          <ul
            class="dropdown-content menu z-20 max-h-64 w-56 overflow-y-auto rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
            aria-label={menu.label}
          >
            <li :for={{value, label, count} <- menu.options}>
              <button
                :if={menu.key == "show"}
                type="button"
                phx-click={
                  JS.push("select_show", target: @myself, value: %{profile_id: value})
                  |> JS.push("switch_profile", value: %{profile_id: value})
                }
                data-role="library-show-option"
                data-value={value}
                class="flex justify-between"
              >
                <span>{label}</span><span data-role="library-option-count" class="text-subtle">{count}</span>
              </button>
              <button
                :if={menu.key != "show"}
                type="button"
                phx-click={
                  JS.push("filter") |> JS.remove_attribute("open", to: "#library-filter-#{menu.key}")
                }
                phx-target={@myself}
                phx-value-key={menu.key}
                phx-value-option={value}
                data-role="library-filter-option"
                data-key={menu.key}
                data-value={value}
                aria-pressed={@filters[menu.key] == value}
                class="flex justify-between"
              >
                <span>{label}</span><span data-role="library-option-count" class="text-subtle">{count}</span>
              </button>
            </li>
          </ul>
        </details>
      </div>
      <div :if={@chips != []} data-role="library-chips" class="flex flex-wrap items-center gap-2">
        <button
          :for={{key, label, value} <- @chips}
          type="button"
          data-role="library-chip"
          data-key={key}
          phx-click="clear_filter"
          phx-target={@myself}
          phx-value-key={key}
          aria-label={"Clear #{label}: #{value}"}
          class="badge badge-outline h-auto gap-2 border-base-300 px-3 py-1 text-xs"
        >
          {label}: {value} ×
        </button>
        <button
          type="button"
          data-role="library-clear-all"
          phx-click="clear_all"
          phx-target={@myself}
          class="btn btn-ghost btn-xs"
        >
          Clear all
        </button>
      </div>
      <p data-role="library-count" class="text-xs text-subtle">{@total} of {@baseline} clips</p>
      <div
        id="library-grid"
        phx-update="stream"
        data-role="library-grid"
        class="grid grid-cols-2 gap-3 min-[761px]:grid-cols-3 min-[1100px]:grid-cols-4"
      >
        <article
          :for={{dom_id, item} <- @streams.clips}
          id={dom_id}
          data-role="library-clip"
          data-clip-id={item.clip.id}
          class="min-w-0 overflow-hidden rounded-box border border-base-300 bg-base-100"
        >
          <div
            class="relative aspect-[9/16] overflow-hidden bg-base-200"
            data-role="library-thumbnail"
          >
            <video
              :if={item.clip.render_file_id}
              src={"/files/blob/#{item.clip.render_file_id}#t=0.1"}
              preload="metadata"
              muted
              playsinline
              class="h-full w-full object-cover"
              aria-label={item.clip.title || "Untitled clip"}
            >
            </video>
            <% {icon, badge} = mark(item.state) %>
            <span
              data-role="library-state"
              class={["badge absolute left-2 top-2 h-auto gap-1 px-2 py-1 text-xs", badge]}
            >
              <.icon name={icon} class="size-3" />{item.state}
            </span>
            <span
              :if={item.clip.duration_s}
              class="absolute bottom-2 right-2 rounded bg-base-100 px-1.5 py-0.5 text-xs font-medium"
            >
              {duration(item.clip.duration_s)}
            </span>
          </div>
          <div class="space-y-2 p-3">
            <h3 data-role="library-title" class="line-clamp-2 text-sm font-semibold">
              {item.clip.title || "Untitled clip"}
            </h3>
            <p data-role="library-meta" class="text-xs text-subtle">{meta(item.clip)}</p>
            <div class="space-y-1">
              <div
                :for={{label, state, kind} <- platform_rows(item)}
                data-role="library-platform"
                class="flex items-center justify-between gap-1 text-xs"
              >
                <span class="font-medium">{label}</span><span class={
                  if kind == :failed, do: "text-error", else: "text-subtle"
                }>{state}</span>
              </div>
            </div>
            <.live_component
              module={PlatformWeb.SocialClipRemoval}
              id={"library-remove-#{item.clip.id}"}
              clip={item.clip}
              profile={@library_profile}
              user_id={@user_id}
            />
          </div>
        </article>
      </div>
      <div
        :if={@total == 0}
        data-role="library-empty"
        class="rounded-box border border-dashed border-base-300 bg-base-100 p-8 text-center text-sm text-subtle"
      >
        <p :if={@baseline == 0}>No clips in Library.</p>
        <span>No clips match.</span>
        <button type="button" phx-click="clear_all" phx-target={@myself} class="btn btn-ghost btn-sm">
          Clear all filters
        </button>
      </div>
    </section>
    """
  end
end
