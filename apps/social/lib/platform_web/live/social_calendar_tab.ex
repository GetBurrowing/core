defmodule PlatformWeb.SocialCalendarTab do
  @moduledoc """
  The Calendar tab (extracted from `PlatformWeb.SocialLive` by Social
  authoring 1/11, no behaviour change). The week's data comes from
  `PlatformWeb.SocialCalendar`: one row per non-archived account (desktop)
  and one block per day with items (mobile agenda). Both re-stream with
  `reset: true` on a profile switch or a week change.

  The read-only post detail (`open_post`) is this tab's overlay: a side
  panel at lg, a bottom sheet below. The post is re-read through the org
  scope and must sit on an account of the current profile (All brands: of a
  visible profile); its body is shown only to an approver of that profile
  or once the post is published.
  """

  use PlatformWeb.SocialTab

  alias Platform.Social
  alias PlatformWeb.SocialCalendar, as: Cal

  @impl true
  def enabled?, do: true

  @impl true
  def all_brands?, do: true

  @impl true
  def events, do: ~w(week_prev week_this week_next open_post close_post)

  @impl true
  def init(socket) do
    socket
    |> assign(:week_start, Cal.week_start(Date.utc_today()))
    |> assign(:detail, nil)
  end

  @impl true
  def load(%{assigns: %{scope: :all, user: user, week_start: monday}} = socket) do
    accounts = Social.list_accounts_for_profiles(user, :all)
    stream_week(socket, accounts, Cal.items_for_user(user, accounts, monday), monday)
  end

  def load(%{assigns: %{profile: nil}} = socket) do
    socket
    |> assign(:calendar_empty?, true)
    |> stream(:calendar_rows, [], reset: true)
    |> stream(:agenda_days, [], reset: true)
  end

  def load(%{assigns: %{profile: profile, week_start: monday}} = socket) do
    accounts = Social.list_accounts(profile.org_id, profile_id: profile.id)
    stream_week(socket, accounts, Cal.items(profile, accounts, monday), monday)
  end

  defp stream_week(socket, accounts, items, monday) do
    socket
    |> assign(:detail, nil)
    |> assign(:calendar_empty?, items == [])
    |> stream(:calendar_rows, Cal.rows(accounts, items, monday), reset: true)
    |> stream(:agenda_days, Cal.agenda(items, monday), reset: true)
  end

  @impl true
  def handle_event("week_" <> which, _params, socket) when which in ~w(prev this next) do
    week =
      case which do
        "prev" -> Date.add(socket.assigns.week_start, -7)
        "next" -> Date.add(socket.assigns.week_start, 7)
        "this" -> Cal.week_start(Date.utc_today())
      end

    {:noreply, socket |> assign(:week_start, week) |> load()}
  end

  def handle_event("open_post", %{"id" => id}, socket) do
    {:noreply, assign(socket, :detail, detail_for(socket, id))}
  end

  def handle_event("close_post", _params, socket), do: {:noreply, assign(socket, :detail, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp detail_for(%{assigns: %{scope: :all} = assigns} = socket, id) do
    with %{id: user_id} <- assigns.user do
      socket
      |> PlatformWeb.SocialScope.visible_profiles()
      |> Enum.find_value(&detail_in(&1, user_id, id))
    end
  end

  defp detail_for(%{assigns: %{profile: %{} = profile, user: %{id: user_id}}}, id),
    do: detail_in(profile, user_id, id)

  defp detail_for(_socket, _id), do: nil

  defp detail_in(profile, user_id, id) do
    with %Social.Post{} = post <- Social.get_post(profile.org_id, id),
         %Social.Account{profile_id: profile_id} = account when profile_id == profile.id <-
           Social.get_account(profile.org_id, post.account_id),
         true <- post.status in Cal.statuses() do
      show_body? =
        post.status == "published" or
          Social.post_approver_check(profile.org_id, profile, account, user_id) == :ok

      %{
        post: post,
        account: account,
        at: post.scheduled_at || post.approved_at,
        show_body?: show_body?
      }
    else
      _ -> nil
    end
  end

  @impl true
  def pane(assigns) do
    assigns = assign(assigns, :days, Cal.days(assigns.week_start))

    ~H"""
    <div class="space-y-4" data-role="social-calendar">
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
        <span class="text-sm text-base-content/70" data-role="social-week-label">
          Week of {Calendar.strftime(@week_start, "%-d %b %Y")} (UTC)
        </span>
      </div>

      <div class="flex flex-wrap items-center gap-2 text-xs" data-role="social-calendar-legend">
        <.status_mark status="scheduled" />
        <.status_mark status="published" />
        <.status_mark status="failed" />
      </div>

      <p :if={@calendar_empty?} class="text-base-content/70" data-role="social-empty">
        <%= if @scope == :all do %>
          Nothing scheduled in any brand this week.
        <% else %>
          Nothing scheduled for {@profile.name} this week.
        <% end %>
      </p>

      <%!-- Desktop: one row per account, seven day columns. --%>
      <div class="hidden overflow-x-auto lg:block">
        <div class="grid min-w-[56rem] grid-cols-[11rem_repeat(7,minmax(0,1fr))] gap-px rounded-lg border border-base-300 bg-base-300">
          <div class="bg-base-100 p-2"></div>
          <div
            :for={day <- @days}
            class="bg-base-100 p-2 text-xs font-semibold text-base-content/70"
            data-role="social-day-head"
          >
            {Cal.day_name(day)} {day.day}
          </div>
        </div>
        <div
          id="social-calendar-rows"
          phx-update="stream"
          class="grid min-w-[56rem] grid-cols-[11rem_repeat(7,minmax(0,1fr))] gap-px border-x border-b border-base-300 bg-base-300"
          data-role="social-calendar-rows"
        >
          <div
            :for={{dom_id, row} <- @streams.calendar_rows}
            id={dom_id}
            class="contents"
            data-role="social-calendar-row"
          >
            <div class="flex min-w-0 items-center gap-2 bg-base-100 p-2">
              <span class="shrink-0 whitespace-nowrap font-mono text-xs uppercase">
                {row.account.platform}
              </span>
              <span class="min-w-0 truncate text-sm text-base-content/70">{row.account.handle}</span>
            </div>
            <div
              :for={{day, items} <- row.days}
              class="min-h-16 space-y-1 bg-base-200 p-1"
              data-role="social-calendar-cell"
              data-date={Date.to_iso8601(day)}
            >
              <.calendar_item :for={item <- items} item={item} />
            </div>
          </div>
        </div>
      </div>

      <%!-- Mobile: a day-by-day agenda. --%>
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
          <ul class="divide-y divide-base-300">
            <li :for={item <- day.items}>
              <button
                type="button"
                class="flex w-full min-w-0 items-center gap-2 px-3 py-2 text-left"
                phx-click="open_post"
                phx-value-id={item.post.id}
                data-role="social-calendar-item"
                data-post-id={item.post.id}
              >
                <span class="shrink-0 whitespace-nowrap font-mono text-xs uppercase">
                  {item.account.platform}
                </span>
                <span class="shrink-0 whitespace-nowrap font-mono text-xs">{Cal.time(item.at)}</span>
                <span class="min-w-0 flex-1 truncate text-sm text-base-content/70">
                  {item.account.handle}
                </span>
                <.status_mark status={item.post.status} />
              </button>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  attr :item, :map, required: true

  defp calendar_item(assigns) do
    ~H"""
    <button
      type="button"
      class="flex w-full min-w-0 flex-wrap items-center gap-1 rounded bg-base-100 px-1.5 py-1 text-left"
      phx-click="open_post"
      phx-value-id={@item.post.id}
      data-role="social-calendar-item"
      data-post-id={@item.post.id}
    >
      <span class="shrink-0 whitespace-nowrap font-mono text-xs">{Cal.time(@item.at)}</span>
      <.status_mark status={@item.post.status} />
    </button>
    """
  end

  attr :status, :string, required: true

  defp status_mark(assigns) do
    {icon, badge} = Cal.mark(assigns.status)
    assigns = assign(assigns, icon: icon, badge: badge)

    ~H"""
    <span class={["badge badge-sm shrink-0 gap-1 whitespace-nowrap", @badge]} data-status={@status}>
      <.icon name={@icon} class="size-3" />{@status}
    </span>
    """
  end

  # Read-only: a side panel at lg, a bottom sheet below (daisy modal).
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
            <p class="truncate text-sm text-base-content/70">{@detail.account.handle}</p>
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
        <div class="mt-3 flex items-center gap-2">
          <span class="font-mono text-xs">
            {Calendar.strftime(@detail.at, "%a %-d %b, %H:%M")} UTC
          </span>
          <.status_mark status={@detail.post.status} />
        </div>
        <p :if={@detail.show_body?} class="mt-3 text-sm" data-role="social-post-detail-body">
          <span class="whitespace-pre-wrap">{@detail.post.body}</span>
        </p>
        <p
          :if={@detail.post.status == "failed" and @detail.post.error}
          class="mt-3 text-sm text-error"
        >
          {@detail.post.error}
        </p>
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
