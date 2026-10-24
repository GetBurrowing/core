defmodule PlatformWeb.SocialCalendarTab do
  @moduledoc """
  The Calendar tab (Social authoring 8/11). The week's data comes from
  `PlatformWeb.SocialCalendar`; the zone and posting slots from
  `PlatformWeb.SocialCalendarClock`.

    * Desktop: time rows (an hour with an item or a slot) by seven day
      columns. Phone: a day-by-day agenda. Both re-stream with `reset: true`
      on a profile switch, a week change, a brand toggle or a zone change.
    * One brand: the week is drawn in the profile's zone, and every
      account's posting slots shade their cells.
    * All brands: every visible profile (ids only ever from
      `Platform.Social.list_profiles_for_user/1`) gets a stable colour and a
      legend entry that toggles its items off. The week is drawn in the
      viewer's browser zone (sent once by the `SocialCalendarZone` hook,
      validated against Tzdata, else UTC). Slots shade only when exactly one
      brand is toggled on.
    * The label always names the zone.

  The post detail (`open_post`) is this tab's overlay: a side panel at lg, a
  bottom sheet below. The post is re-read through the org scope and must sit
  on an account of the current profile (All brands: of a visible profile);
  its body is shown only to an approver of that profile or once published.
  A post waiting on the viewer can be approved from it
  (`Platform.Social.Approvals.decide_approve/3`, the card's own path), and
  the week re-streams so the item turns solid with no reload. A post of an
  idea opens that idea on the Ideas tab (7/11) instead; a post with no idea
  opens the post detail.
  """

  use PlatformWeb.SocialTab

  alias Platform.Social
  alias Platform.Social.Approvals
  alias PlatformWeb.SocialCalendar, as: Cal
  alias PlatformWeb.SocialCalendarClock, as: Clock

  @impl true
  def enabled?, do: true

  @impl true
  def all_brands?, do: true

  @impl true
  def events,
    do:
      ~w(week_prev week_this week_next open_post close_post calendar_zone calendar_toggle_brand calendar_approve)

  @impl true
  def init(socket) do
    socket
    |> assign(:week_start, Cal.week_start(Date.utc_today()))
    |> assign(:detail, nil)
    |> assign(:calendar_browser_zone, nil)
    |> assign(:calendar_zone, Clock.utc())
    |> assign(:calendar_hidden, MapSet.new())
    |> assign(:calendar_brands, [])
    |> assign(:calendar_shading?, false)
    |> assign(:calendar_empty?, true)
    |> assign(:calendar_slots?, false)
  end

  @impl true
  def load(%{assigns: %{scope: :all, user: user, week_start: monday}} = socket)
      when not is_nil(user) do
    profiles = PlatformWeb.SocialScope.visible_profiles(socket)
    brands = Cal.brands(profiles)
    ids = MapSet.new(brands, & &1.id)
    hidden = MapSet.intersection(socket.assigns.calendar_hidden, ids)
    zone = socket.assigns.calendar_browser_zone || Clock.utc()
    accounts = Social.list_accounts_for_profiles(user, :all)
    extra = %{brands: Map.new(brands, &{&1.id, &1})}

    items =
      user
      |> Cal.items_for_user(accounts, monday, zone, extra)
      |> Enum.reject(&MapSet.member?(hidden, &1.account.profile_id))
      |> label_waiting(Map.new(profiles, &{&1.id, &1}), user)

    # Shading only when exactly one brand is on: its slots, in its zone,
    # drawn in the browser zone.
    shown = Enum.reject(profiles, &MapSet.member?(hidden, &1.id))

    slots =
      case shown do
        [one] -> slots(Enum.filter(accounts, &(&1.profile_id == one.id)), one, monday, zone)
        _ -> []
      end

    socket
    |> assign(
      :calendar_brands,
      Enum.map(brands, &Map.put(&1, :hidden?, MapSet.member?(hidden, &1.id)))
    )
    |> assign(:calendar_hidden, hidden)
    |> assign(:calendar_shading?, match?([_], shown))
    |> stream_week(zone, items, slots, monday)
  end

  def load(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:calendar_empty?, true)
    |> assign(:calendar_slots?, false)
    |> assign(:calendar_brands, [])
    |> assign(:calendar_zone, Clock.utc())
    |> stream(:calendar_rows, [], reset: true)
    |> stream(:agenda_days, [], reset: true)
  end

  def load(%{assigns: %{profile: profile, week_start: monday}} = socket) do
    zone = Clock.profile_zone(profile)
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)

    items =
      profile
      |> Cal.items(accounts, monday, zone)
      |> label_waiting(%{profile.id => profile}, socket.assigns[:user])

    socket
    |> assign(:calendar_brands, [])
    |> assign(:calendar_shading?, true)
    |> stream_week(zone, items, slots(accounts, profile, monday, zone), monday)
  end

  defp slots(accounts, profile, monday, draw_zone) do
    profile_zone = Clock.profile_zone(profile)
    Enum.flat_map(accounts, &Clock.slots_in_week(&1, profile_zone, monday, draw_zone))
  end

  defp stream_week(socket, zone, items, slots, monday) do
    socket
    |> assign(:detail, nil)
    |> assign(:calendar_zone, zone)
    |> assign(:calendar_empty?, items == [])
    |> assign(:calendar_slots?, slots != [])
    |> stream(:calendar_rows, Cal.rows(items, slots, monday), reset: true)
    |> stream(:agenda_days, Cal.agenda(items, monday), reset: true)
  end

  # "Waiting on you" when the viewer may approve the post's account now,
  # "Waiting on <owner>" on an owned account, else "Waiting on approval".
  # One check per account with a waiting item.
  defp label_waiting(items, profiles_by_id, user) do
    {items, _memo} =
      Enum.map_reduce(items, %{}, fn
        %{state: :waiting, account: account} = item, memo ->
          {label, memo} =
            case Map.fetch(memo, account.id) do
              {:ok, label} ->
                {label, memo}

              :error ->
                label = waiting_label(Map.get(profiles_by_id, account.profile_id), account, user)
                {label, Map.put(memo, account.id, label)}
            end

          {%{item | waiting_on: label}, memo}

        item, memo ->
          {item, memo}
      end)

    items
  end

  defp waiting_label(%Social.Profile{} = profile, account, %{id: user_id}) do
    cond do
      Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok ->
        "Waiting on you"

      is_binary(account.owner_user_id) ->
        "Waiting on " <> user_name(Platform.Accounts.get_user(account.owner_user_id))

      true ->
        "Waiting on approval"
    end
  end

  defp waiting_label(_profile, _account, _user), do: "Waiting on approval"

  @impl true
  def handle_event("week_" <> which, _params, socket) when which in ~w(prev this next) do
    week =
      case which do
        "prev" -> Date.add(socket.assigns.week_start, -7)
        "next" -> Date.add(socket.assigns.week_start, 7)
        "this" -> Cal.week_start(Clock.today(socket.assigns.calendar_zone))
      end

    {:noreply, socket |> assign(:week_start, week) |> load()}
  end

  # Sent once by the SocialCalendarZone hook. Anything Tzdata does not know
  # is ignored (the week stays in UTC).
  def handle_event("calendar_zone", %{"zone" => zone}, socket) do
    case Clock.valid_zone(zone) do
      nil ->
        {:noreply, socket}

      zone ->
        socket = assign(socket, :calendar_browser_zone, zone)

        socket =
          if PlatformWeb.SocialScope.all?(socket),
            do: load(socket),
            else: socket

        {:noreply, socket}
    end
  end

  # Only ever toggles a brand the viewer can see: a forged id changes nothing.
  def handle_event("calendar_toggle_brand", %{"id" => id}, socket) do
    if PlatformWeb.SocialScope.all?(socket) and
         Enum.any?(socket.assigns.calendar_brands, &(&1.id == id)) do
      hidden = socket.assigns.calendar_hidden

      hidden =
        if MapSet.member?(hidden, id), do: MapSet.delete(hidden, id), else: MapSet.put(hidden, id)

      {:noreply, socket |> assign(:calendar_hidden, hidden) |> load()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_post", %{"id" => id}, socket) do
    detail = detail_for(socket, id)

    case detail && PlatformWeb.SocialIdeasTab.open_idea(socket, detail.post.idea_id) do
      {:ok, socket} -> {:noreply, socket}
      _ -> {:noreply, assign(socket, :detail, detail)}
    end
  end

  def handle_event("close_post", _params, socket), do: {:noreply, assign(socket, :detail, nil)}

  # The approve path is the approval card's: the post is re-found through
  # the scope, then `decide_approve/3` re-checks the owner/approver rule and
  # the fingerprint the viewer was shown.
  def handle_event("calendar_approve", %{"id" => id} = params, socket) do
    with %{post: %{status: "needs_approval"} = post, can_approve?: true} <- detail_for(socket, id),
         %{canvas_id: canvas_id} <- Approvals.live_card(post.id),
         {:ok, %{post: approved}} <-
           Approvals.decide_approve(canvas_id, socket.assigns.user, params["fingerprint"]) do
      socket = load(socket)
      {:noreply, assign(socket, :detail, detail_for(socket, approved.id))}
    else
      _ ->
        {:noreply,
         socket
         |> notice(
           "That post could not be approved here. It may have changed; reopen it.",
           :warning
         )
         |> load()}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp detail_for(%{assigns: %{scope: :all} = assigns} = socket, id) do
    with %{id: user_id} <- assigns.user do
      socket
      |> PlatformWeb.SocialScope.visible_profiles()
      |> Enum.find_value(&detail_in(&1, user_id, id, socket.assigns.calendar_zone))
    end
  end

  defp detail_for(%{assigns: %{profile: %{} = profile, user: %{id: user_id}}} = socket, id),
    do: detail_in(profile, user_id, id, socket.assigns.calendar_zone)

  defp detail_for(_socket, _id), do: nil

  defp detail_in(profile, user_id, id, zone) do
    with %Social.Post{} = post <- Social.get_post(profile.org_id, id),
         %Social.Account{profile_id: profile_id} = account when profile_id == profile.id <-
           Social.get_account(profile.org_id, post.account_id),
         true <- post.status in Cal.statuses(),
         %DateTime{} = utc <- Cal.placed_at(post) do
      approver? = Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok
      waiting? = post.status == "needs_approval"

      %{
        post: post,
        account: account,
        at: Clock.local(utc, zone),
        zone: Clock.label(zone),
        state: Cal.state(post),
        show_body?: post.status == "published" or approver?,
        can_approve?: waiting? and approver? and account.approval_mode != "draft_only",
        fingerprint: if(waiting? and approver?, do: Approvals.fingerprint(post))
      }
    else
      _ -> nil
    end
  end

  @impl true
  def pane(assigns) do
    assigns =
      assign(assigns,
        days: Cal.days(assigns.week_start),
        all?: assigns.scope == :all,
        zone_label: Clock.label(assigns.calendar_zone)
      )

    ~H"""
    <div class="space-y-4" data-role="social-calendar">
      <span id="social-calendar-zone" phx-hook="SocialCalendarZone" class="hidden"></span>
      <div class="flex flex-wrap items-center gap-2" data-role="social-week-nav">
        <button type="button" class="btn btn-ghost btn-sm" phx-click="week_prev" data-role="week-prev">
          <.icon name="hero-chevron-left-micro" class="size-4" /> prev week
        </button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="week_this" data-role="week-this">
          This week
        </button>
        <button type="button" class="btn btn-ghost btn-sm" phx-click="week_next" data-role="week-next">
          next week <.icon name="hero-chevron-right-micro" class="size-4" />
        </button>
        <span class="text-sm text-base-content" data-role="social-week-label">
          Week of {Calendar.strftime(@week_start, "%-d %b %Y")}, times in
          <span class="font-semibold" data-role="social-week-zone" data-zone={@calendar_zone}>
            {@zone_label}
          </span>
          <%= if @all? do %>
            (your browser)
          <% end %>
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2 text-xs" data-role="social-calendar-legend">
        <span class="rounded border border-dashed border-base-content/70 bg-base-100 px-1.5 py-0.5">
          <Cal.state_mark state={:waiting} label="Waiting on you" />
        </span>
        <span class="rounded border border-solid border-base-content/40 bg-base-100 px-1.5 py-0.5">
          <Cal.state_mark state={:scheduled} label="scheduled" />
        </span>
        <span class="rounded border border-solid border-base-content/20 bg-base-300 px-1.5 py-0.5">
          <Cal.state_mark state={:published} label="published" />
        </span>
        <span class="rounded border-2 border-solid border-error bg-base-100 px-1.5 py-0.5">
          <Cal.state_mark state={:failed} label="failed or refused" />
        </span>
        <span
          :if={@calendar_slots?}
          class="inline-flex items-center gap-1 rounded bg-info/15 px-1.5 py-0.5 text-base-content"
        >
          <.icon name="hero-clock-micro" class="size-3" /> posting slot
        </span>
      </div>

      <div
        :if={@all? and @calendar_brands != []}
        class="flex flex-wrap items-center gap-2"
        data-role="social-calendar-brands"
      >
        <span class="text-xs text-base-content">Brands:</span>
        <button
          :for={brand <- @calendar_brands}
          type="button"
          class={[
            "btn btn-xs gap-1",
            if(brand.hidden?, do: "btn-ghost line-through", else: "btn-outline")
          ]}
          phx-click="calendar_toggle_brand"
          phx-value-id={brand.id}
          aria-pressed={to_string(!brand.hidden?)}
          data-role="social-calendar-brand-toggle"
          data-brand-id={brand.id}
          data-hidden={to_string(brand.hidden?)}
        >
          <span class={["size-3 rounded-sm border", brand.colour]} aria-hidden="true"></span>
          {brand.name}
          <span class="sr-only">{if brand.hidden?, do: "(hidden)", else: "(shown)"}</span>
        </button>
        <span :if={!@calendar_shading?} class="text-xs text-base-content">
          Show one brand to see its posting slots.
        </span>
      </div>

      <p :if={@calendar_empty?} class="text-base-content" data-role="social-empty">
        <%= if @all? do %>
          Nothing scheduled in any brand this week.
        <% else %>
          Nothing scheduled for {@profile.name} this week.
        <% end %>
      </p>

      <%!-- Desktop: time rows by seven day columns. --%>
      <div class="hidden overflow-x-auto lg:block">
        <div class="grid min-w-[56rem] grid-cols-[4.5rem_repeat(7,minmax(0,1fr))] gap-px rounded-t-lg border border-base-300 bg-base-300">
          <div class="bg-base-100 p-2 text-xs text-base-content" title={@calendar_zone}>
            {Clock.abbreviation(@week_start, @calendar_zone)}
          </div>
          <div
            :for={day <- @days}
            class="bg-base-100 p-2 text-xs font-semibold text-base-content"
            data-role="social-day-head"
          >
            {Cal.day_name(day)} {day.day}
          </div>
        </div>
        <div
          id="social-calendar-rows"
          phx-update="stream"
          class="grid min-w-[56rem] grid-cols-[4.5rem_repeat(7,minmax(0,1fr))] gap-px border-x border-b border-base-300 bg-base-300"
          data-role="social-calendar-rows"
        >
          <div
            :for={{dom_id, row} <- @streams.calendar_rows}
            id={dom_id}
            class="contents"
            data-role="social-calendar-row"
            data-hour={row.label}
          >
            <div class="bg-base-100 p-2 font-mono text-xs text-base-content">{row.label}</div>
            <div
              :for={cell <- row.days}
              class={[
                "min-h-14 space-y-1 p-1",
                if(cell.slots != [], do: "bg-info/15", else: "bg-base-200")
              ]}
              data-role="social-calendar-cell"
              data-date={Date.to_iso8601(cell.date)}
              data-hour={row.label}
              data-slot={to_string(cell.slots != [])}
            >
              <p
                :for={slot <- cell.slots}
                class="flex items-center gap-1 text-xs text-base-content"
                data-role="social-slot"
                data-time={slot.time}
              >
                <.icon name="hero-clock-micro" class="size-3" /> slot {slot.time}
              </p>
              <Cal.group_chip :for={group <- cell.groups} group={group} show_brand?={@all?} />
            </div>
          </div>
        </div>
      </div>

      <%!-- Phone: a day-by-day agenda. --%>
      <div
        id="social-agenda"
        phx-update="stream"
        class="space-y-3 lg:hidden"
        data-role="social-agenda"
      >
        <section
          :for={{dom_id, day} <- @streams.agenda_days}
          id={dom_id}
          class="rounded-lg border border-base-300 bg-base-100"
          data-role="social-agenda-day"
          data-date={day.id}
        >
          <h3 class="border-b border-base-300 bg-base-200 px-3 py-2 text-sm font-semibold">
            {Cal.day_label(day.date)}
          </h3>
          <ul class="space-y-1 p-2">
            <li :for={item <- day.items}>
              <Cal.item_chip item={item} show_brand?={@all?} />
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  # A side panel at lg, a bottom sheet below (daisy modal).
  @impl true
  def overlay(assigns) do
    ~H"""
    <div
      :if={@detail}
      class="modal modal-open modal-bottom lg:modal-end"
      data-role="social-post-detail"
    >
      <div class="modal-box border border-base-300 bg-base-100 lg:h-full lg:max-h-none lg:rounded-none">
        <div class="flex items-start justify-between gap-2">
          <div class="min-w-0">
            <p class="font-mono text-xs uppercase">{@detail.account.platform}</p>
            <p class="truncate text-sm text-base-content">{@detail.account.handle}</p>
          </div>
          <button
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="close_post"
            aria-label="Close"
            data-role="social-post-detail-close"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <div class="mt-3 flex flex-wrap items-center gap-2">
          <span class="font-mono text-xs">
            {Calendar.strftime(@detail.at, "%a %-d %b, %H:%M")} {@detail.zone}
          </span>
          <Cal.state_mark
            state={@detail.state}
            label={if @detail.state == :waiting, do: "needs approval", else: @detail.post.status}
          />
          <Cal.result_chip :if={@detail.state == :published} post={@detail.post} />
        </div>
        <p :if={@detail.show_body?} class="mt-3 text-sm" data-role="social-post-detail-body">
          <span class="whitespace-pre-wrap">{@detail.post.body}</span>
        </p>
        <p
          :if={Cal.reason(@detail.post)}
          class="mt-3 text-sm"
          data-role="social-post-detail-reason"
        >
          <.icon name="hero-exclamation-triangle-micro" class="size-4 text-error" />
          {Cal.reason(@detail.post)}
        </p>
        <button
          :if={@detail.can_approve?}
          type="button"
          class="btn btn-primary btn-sm mt-3"
          phx-click="calendar_approve"
          phx-value-id={@detail.post.id}
          phx-value-fingerprint={@detail.fingerprint}
          data-role="social-calendar-approve"
        >
          <.icon name="hero-check-micro" class="size-4" /> Approve
        </button>
        <a
          :if={@detail.post.status == "published" and @detail.post.external_url}
          href={@detail.post.external_url}
          target="_blank"
          rel="noopener noreferrer"
          class="link mt-3 inline-block text-sm"
          data-role="social-post-detail-link"
        >
          View published post
        </a>
      </div>
      <button type="button" class="modal-backdrop" phx-click="close_post" aria-label="Close"></button>
    </div>
    """
  end
end
