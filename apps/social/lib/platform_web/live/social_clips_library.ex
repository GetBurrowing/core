defmodule PlatformWeb.SocialClipsLibrary do
  @moduledoc "The current authorized profile's searchable, streamed clip Library."
  use PlatformWeb, :live_component

  alias Platform.{Accounts, Repo, Social}
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
     |> assign(:detail_id, nil)
     |> assign(:detail, nil)
     |> assign(:reconnecting, %{})
     |> assign(:retry_error, nil)
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
        socket
        |> assign(:show_chip?, socket.assigns.loaded_profile_id != nil)
        |> assign(:detail_id, nil)
        |> assign(:detail, nil)
        |> assign(:reconnecting, %{})
        |> assign(:retry_error, nil)
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

  def handle_event("open_detail", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:detail_id, id) |> assign(:retry_error, nil) |> load()}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply,
     socket |> assign(:detail_id, nil) |> assign(:detail, nil) |> assign(:retry_error, nil)}
  end

  def handle_event("reconnect", %{"clip_id" => id, "post_id" => post_id}, socket) do
    socket = socket |> assign(:detail_id, id) |> load()

    socket =
      case detail_row(socket, post_id) do
        %{auth_error?: true, can_connect?: true, account: account} ->
          assign(
            socket,
            :reconnecting,
            Map.put(socket.assigns.reconnecting, account.id, account.updated_at)
          )

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_event("retry", %{"clip_id" => id, "post_id" => post_id}, socket) do
    socket = socket |> assign(:detail_id, id) |> assign(:retry_error, nil) |> load()

    socket =
      case detail_row(socket, post_id) do
        %{entry: %{state: :failed}, can_retry?: true} ->
          case Social.retry_post(
                 socket.assigns.library_profile.org_id,
                 post_id,
                 socket.assigns.user_id
               ) do
            {:ok, _} ->
              socket

            {:error, _} ->
              assign(
                socket,
                :retry_error,
                "Retry could not complete. Refresh the account and try again."
              )
          end

        _ ->
          socket
      end

    {:noreply, load(socket)}
  end

  def handle_event(event, _params, socket) when event in ~w(open_detail retry reconnect) do
    {:noreply, socket |> assign(:detail_id, nil) |> load()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, load(socket)}

  defp detail_row(%{assigns: %{detail: %{rows: rows}}}, post_id),
    do: Enum.find(rows, &(&1.entry.post_id == post_id))

  defp detail_row(_, _), do: nil

  # Only the current visible profile can supply a detail, including forged
  # events and refreshes. UUID casting happens before any database query.
  defp load_detail(socket) do
    with %{org_id: org_id, id: profile_id} = profile <- socket.assigns.library_profile,
         {:ok, id} <- Ecto.UUID.cast(socket.assigns.detail_id),
         %{profile_id: ^profile_id, review_status: status} = clip <- Social.get_clip(org_id, id),
         true <- status in ~w(pending approved rejected) do
      clip = Repo.preload(clip, [:submitted_by_agent, :reviewed_by_user])

      rows =
        Enum.flat_map(ClipLibrary.clip_status(clip), fn entry ->
          case Social.get_account(org_id, entry.account_id) do
            %{profile_id: ^profile_id} = account ->
              [
                %{
                  entry: entry,
                  account: account,
                  auth_error?: auth_error?(entry, account),
                  reconnected?: reconnected?(socket.assigns.reconnecting, account),
                  can_connect?:
                    is_nil(account.archived_at) and
                      Social.approver_check(org_id, profile, socket.assigns.user_id) == :ok,
                  can_retry?:
                    is_nil(account.archived_at) and
                      Social.post_approver_check(org_id, profile, account, socket.assigns.user_id) ==
                        :ok
                }
              ]

            _ ->
              []
          end
        end)

      missing =
        Enum.reject(@platforms, fn {platform, _} ->
          Enum.any?(rows, &(&1.entry.platform == platform))
        end)

      assign(socket, :detail, %{clip: clip, rows: rows, missing: missing})
    else
      _ -> socket |> assign(:detail_id, nil) |> assign(:detail, nil) |> assign(:retry_error, nil)
    end
  end

  defp reconnected?(pending, %{id: id, status: "connected", updated_at: updated}) do
    case pending[id] do
      %DateTime{} = before -> DateTime.compare(updated, before) == :gt
      _ -> false
    end
  end

  defp reconnected?(_, _), do: false

  defp auth_error?(%{state: :failed, error: error}, account) do
    (is_nil(error) and account.status == "reauth_needed") or
      (is_binary(error) and
         Regex.match?(
           ~r/token[_ ]expired|access_token_invalid|invalid[_ ]token|unauthorized|reauth|signed.out|disconnected.this.account|credentials.are.unavailable/i,
           error
         ))
  end

  defp auth_error?(_, _), do: false

  defp status_line(entry) do
    label =
      if entry.state == :uploading and entry.pct != nil,
        do: "Uploading #{entry.pct}%",
        else: platform_label(entry.state)

    [
      label,
      time(entry.at),
      if(entry.state == :published and entry.views != nil, do: "#{entry.views} views"),
      if(entry.state == :failed, do: "#{entry.attempts} attempts"),
      if(entry.state == :queued, do: "publishes when the undo window closes")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp platform_name("instagram"), do: "Instagram"
  defp platform_name("youtube"), do: "YouTube"
  defp platform_name("tiktok"), do: "TikTok"
  defp platform_name("linkedin"), do: "LinkedIn"
  defp platform_name("x"), do: "X"
  defp platform_name(_), do: "Platform"

  defp time(nil), do: nil
  defp time(%DateTime{} = at), do: Calendar.strftime(at, "%d %b %Y · %H:%M UTC")

  defp safe_post_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["https", "http"] and is_binary(host) -> url
      _ -> nil
    end
  end

  defp safe_post_url(_), do: nil

  defp renderer(%{submitted_by_agent: %{name: name}}) when is_binary(name),
    do: "rendered by #{name}"

  defp renderer(_), do: nil

  defp decision(%{review_status: status, reviewed_by_user: %{name: name}, reviewed_at: at})
       when status in ["approved", "rejected"] do
    "#{if status == "approved", do: "Approved", else: "Rejected"} by #{name} · #{time(at)}"
  end

  defp decision(_), do: nil

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
        |> load_detail()

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
    |> load_detail()
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
    <section
      id="social-clips-library"
      data-role="clips-library"
      class={["space-y-4", @detail && "min-[761px]:pr-[376px]"]}
    >
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
              placeholder="Search title, caption"
              aria-label="Search title, caption"
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
          <button
            type="button"
            phx-click="open_detail"
            phx-target={@myself}
            phx-value-id={item.clip.id}
            aria-label={"Open clip: #{item.clip.title || "Untitled clip"}"}
            class="relative block w-full aspect-[9/16] overflow-hidden bg-base-200 text-left"
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
          </button>
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
      <.detail_panel
        :if={@detail}
        detail={@detail}
        myself={@myself}
        profile={@library_profile}
        retry_error={@retry_error}
      />
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

  defp detail_panel(assigns) do
    ~H"""
    <div data-role="library-detail-overlay" class="pointer-events-none fixed inset-0 z-40">
      <button
        type="button"
        aria-label="Close clip detail"
        phx-click="close_detail"
        phx-target={@myself}
        class="pointer-events-auto absolute inset-0 bg-base-300/50 min-[761px]:hidden"
      />
      <aside
        id="library-detail"
        role="dialog"
        aria-modal="true"
        aria-labelledby="library-detail-title"
        phx-window-keydown="close_detail"
        phx-key="Escape"
        phx-target={@myself}
        phx-mounted={JS.focus_first()}
        class="pointer-events-auto absolute inset-x-0 bottom-0 max-h-[85dvh] overflow-y-auto rounded-t-2xl border border-base-300 bg-base-100 shadow-xl min-[761px]:inset-x-auto min-[761px]:right-0 min-[761px]:top-[98px] min-[761px]:max-h-full min-[761px]:w-[360px] min-[761px]:rounded-none"
      >
        <header class="sticky top-0 z-10 flex items-center justify-between gap-2 border-b border-base-300 bg-base-100 p-4">
          <span class="text-sm font-semibold">Clip · clip {String.slice(@detail.clip.id, 0, 8)}</span>
          <button
            type="button"
            phx-click="close_detail"
            phx-target={@myself}
            aria-label="Close clip detail"
            class="btn btn-ghost btn-sm btn-square"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </header>
        <div class="space-y-5 p-4">
          <div class="flex gap-3">
            <video
              :if={@detail.clip.render_file_id}
              src={"/files/blob/#{@detail.clip.render_file_id}"}
              controls
              playsinline
              preload="metadata"
              class="aspect-[9/16] w-24 shrink-0 self-start rounded-lg bg-base-200 object-cover"
            />
            <div class="min-w-0 space-y-2">
              <h2 id="library-detail-title" class="break-words text-base font-semibold">
                {@detail.clip.title || "Untitled clip"}
              </h2>
              <p class="text-xs text-subtle">{meta(@detail.clip)}</p>
              <p :if={renderer(@detail.clip)} data-role="library-renderer" class="text-xs text-subtle">
                {renderer(@detail.clip)}
              </p>
              <p :if={decision(@detail.clip)} data-role="library-decision" class="text-xs text-subtle">
                {decision(@detail.clip)}
              </p>
              <blockquote
                :if={@detail.clip.review_status == "rejected" and @detail.clip.review_note}
                data-role="library-rejection"
                class="break-words text-sm"
              >
                “{@detail.clip.review_note}”
              </blockquote>
              <a
                href={"/m/social?tab=clips&view=review&clip=#{@detail.clip.id}&profile=#{@profile.id}"}
                data-role="library-open-review"
                class="link link-primary text-xs"
              >
                Open in Review
              </a>
            </div>
          </div>
          <section aria-label="Platforms" class="space-y-3">
            <h3 class="text-xs font-semibold uppercase tracking-wider text-subtle">Platforms</h3>
            <article
              :for={row <- @detail.rows}
              data-role="library-detail-platform"
              data-post-id={row.entry.post_id}
              class="space-y-2 rounded-box border border-base-300 bg-base-200 p-3 text-xs"
            >
              <div class="flex items-center justify-between gap-2">
                <span class="font-semibold">{platform_name(row.entry.platform)}</span>
                <% {icon, badge} =
                  mark(
                    if row.entry.state == :queued,
                      do: "Publishing",
                      else: platform_label(row.entry.state)
                  ) %>
                <span class={["badge badge-sm gap-1", badge]}>
                  <.icon name={icon} class="size-3" />{platform_label(row.entry.state)}
                </span>
              </div>
              <p :if={row.account.handle} class="text-subtle">{row.account.handle}</p>
              <p data-role="library-platform-status" class="text-subtle">{status_line(row.entry)}</p>
              <a
                :if={row.entry.state == :published and safe_post_url(row.entry.url)}
                href={safe_post_url(row.entry.url)}
                target="_blank"
                rel="noopener noreferrer"
                class="link link-primary"
              >
                View post ↗
              </a>
              <button
                :if={row.entry.state == :scheduled}
                type="button"
                data-role="library-reschedule"
                phx-click={
                  JS.push("select_tab", value: %{tab: "calendar"})
                  |> JS.push("open_post", value: %{id: row.entry.post_id})
                }
                class="btn btn-ghost btn-xs"
              >
                Reschedule
              </button>
              <div :if={row.entry.state == :failed} class="space-y-2">
                <p
                  :if={row.entry.error}
                  data-role="library-error-code"
                  class="break-words font-mono text-error"
                >
                  {row.entry.error}
                </p>
                <p :if={row.auth_error?} class="break-words">
                  {platform_name(row.entry.platform)} signed us out. Reconnect the account, then retry; the other platforms are unaffected.
                </p>
                <div class="flex flex-wrap gap-2">
                  <span :if={row.reconnected?} data-role="library-reconnected" class="text-success">
                    Reconnected
                  </span>
                  <button
                    :if={row.auth_error? and row.can_connect? and not row.reconnected?}
                    type="button"
                    data-role="library-reconnect"
                    phx-click={
                      JS.push("reconnect",
                        target: @myself,
                        value: %{clip_id: @detail.clip.id, post_id: row.entry.post_id}
                      )
                      |> JS.push("select_tab", value: %{tab: "connections"})
                      |> JS.push("connect_account", value: %{id: row.account.id})
                    }
                    class="btn btn-primary btn-xs"
                  >
                    Reconnect {platform_name(row.entry.platform)}
                  </button>
                  <button
                    :if={row.can_retry?}
                    type="button"
                    data-role="library-retry"
                    phx-click="retry"
                    phx-target={@myself}
                    phx-value-clip_id={@detail.clip.id}
                    phx-value-post_id={row.entry.post_id}
                    class="btn btn-outline btn-xs"
                  >
                    Retry
                  </button>
                </div>
              </div>
            </article>
            <div
              :for={{platform, _} <- @detail.missing}
              data-role="library-not-posted"
              class="flex justify-between rounded-box border border-base-300 p-3 text-xs"
            >
              <span>{platform_name(platform)}</span><span class="text-subtle">{if platform in (@detail.clip.platforms || []), do: "Not posted", else: "Not selected"}</span>
            </div>
          </section>
          <p :if={@retry_error} role="alert" class="text-sm text-error">{@retry_error}</p>
        </div>
      </aside>
    </div>
    """
  end
end
