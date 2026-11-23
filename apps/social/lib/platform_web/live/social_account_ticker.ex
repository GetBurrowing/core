defmodule PlatformWeb.SocialAccountTicker do
  @moduledoc "The scoped account strip: dated audience observations and measured Burrow post cohorts."
  use PlatformWeb, :html
  alias Platform.Social
  alias Platform.Social.AccountTicker
  alias PlatformWeb.{SocialHelpers, SocialPreview, SocialScope}

  @doc "Refresh the metric slice without touching tabs, streams or an open editor."
  def load(socket) do
    ids = scoped_ids(socket.assigns)

    socket
    |> assign(:ticker_rows, AccountTicker.rows(SocialHelpers.fresh_user(socket), ids))
    |> assign(:ticker_wikipedia, wikipedia_snapshot(socket.assigns))
  end

  def open_details(socket, account_id) do
    account_id = if Platform.UUID.valid?(account_id), do: account_id
    socket = load(socket)

    row =
      Enum.find(
        visible_rows(socket.assigns),
        &(&1.account.id == account_id and not is_nil(&1.latest_video))
      )

    selected = if row, do: row.account.id

    socket
    |> assign(:ticker_details_account_id, selected)
    |> Phoenix.LiveView.push_event("social:ticker_details", %{
      open: not is_nil(selected),
      account_id: account_id
    })
  end

  def close_details(socket) do
    account_id = Map.get(socket.assigns, :ticker_details_account_id)

    socket
    |> load()
    |> assign(:ticker_details_account_id, nil)
    |> Phoenix.LiveView.push_event("social:ticker_details", %{open: false, account_id: account_id})
  end

  defp wikipedia_allowed?(assigns) do
    config = Application.get_env(:social, :trends, [])
    user = SocialHelpers.fresh_user(%{assigns: assigns})

    Keyword.get(config, :enabled, false) == true and SocialHelpers.human?(user) and
      Enum.any?(SocialScope.visible_profiles(%{assigns: assigns}), fn profile ->
        profile.studio_enabled and Social.Studio.require_social_use(user.id, profile) == :ok
      end)
  end

  defp wikipedia_snapshot(assigns) do
    if wikipedia_allowed?(assigns), do: Social.Trends.latest("wikimedia_pageviews").current
  end

  def visible_wikipedia(assigns) do
    if wikipedia_allowed?(assigns), do: Map.get(assigns, :ticker_wikipedia)
  end

  # Render-time authorization only filters the cached metrics; it does not
  # run the snapshot/post queries for every keystroke in a post editor.
  def visible_rows(assigns) do
    user = SocialHelpers.fresh_user(%{assigns: assigns})

    accounts =
      if SocialHelpers.human?(user),
        do: Social.list_accounts_for_profiles(user, scoped_ids(assigns)),
        else: []

    by_id = Map.new(accounts, &{&1.id, &1})
    profiles = SocialScope.visible_profiles(%{assigns: assigns}) |> Map.new(&{&1.id, &1})

    for row <- Map.get(assigns, :ticker_rows, []),
        current = by_id[row.account.id],
        not is_nil(current),
        current.provider_account_ref == row.account.provider_account_ref do
      %{
        row
        | account: current,
          follower_target: if(current.platform != "linkedin", do: current.follower_target),
          latest_video:
            if(latest_video_allowed?(user, current, profiles[current.profile_id], row),
              do: Map.get(row, :latest_video)
            )
      }
      |> Map.put(:ticker_details_open, Map.get(assigns, :ticker_details_account_id) == current.id)
      |> Map.put(:publication_updates_enabled?, Platform.Social.PublicationSync.enabled?())
    end
  end

  defp latest_video_allowed?(user, account, profile, row) do
    SocialHelpers.human?(user) and account.platform == "youtube" and account.status == "connected" and
      Social.Analytics.AccountScope.zernio_account?(account) and
      not is_nil(profile) and profile.id == row.profile.id and
      profile.org_id == row.profile.org_id and
      profile.provider_profile_ref == row.profile.provider_profile_ref and
      Social.Studio.require_social_use(user.id, profile) == :ok
  end

  defp scoped_ids(assigns) do
    visible = SocialScope.visible_profiles(%{assigns: assigns})

    case assigns[:scope] do
      :all -> Enum.map(visible, & &1.id)
      {:profile, %{id: id}} -> for p <- visible, p.id == id, do: p.id
      _ -> []
    end
  end

  attr :rows, :list, required: true
  attr :scope, :any, required: true
  attr :wikipedia, :any, default: nil

  def strip(assigns) do
    assigns = assign(assigns, :updates_enabled?, Platform.Social.PublicationSync.enabled?())

    assigns =
      assign(
        assigns,
        :scope_key,
        case assigns.scope do
          :all -> "all"
          {:profile, %{id: id}} -> id
          _ -> "none"
        end
      )

    assigns =
      assign(
        assigns,
        :details_row,
        Enum.find(
          assigns.rows,
          &(Map.get(&1, :ticker_details_open, false) and not is_nil(Map.get(&1, :latest_video)))
        )
      )

    ~H"""
    <section
      :if={@rows != []}
      id="social-account-ticker"
      phx-hook="SocialTicker"
      data-role="social-account-ticker"
      data-scope-key={@scope_key}
      class="social-account-ticker mt-3 flex-col rounded-lg border border-base-content/25 bg-base-100 text-sm"
      aria-label={
        if @wikipedia && @wikipedia.items != [],
          do: "Account performance and Wikipedia trends",
          else: "Account performance"
      }
    >
      <div data-role="ticker-strip-row" class="flex min-w-0 items-stretch">
        <div class="min-w-0 flex-1">
          <div
            data-ticker-viewport
            tabindex="0"
            aria-label="Account performance, scroll horizontally"
            class="social-ticker-viewport overflow-x-auto overscroll-x-contain"
          >
            <div class="flex w-max" data-ticker-track>
              <div data-ticker-original class="flex shrink-0">
                <.entries
                  rows={@rows}
                  all?={@scope == :all}
                  copy?={false}
                  updates_enabled?={@updates_enabled?}
                />
              </div>
              <div data-ticker-copy aria-hidden="true" class="social-ticker-copy flex shrink-0">
                <.entries
                  rows={@rows}
                  all?={@scope == :all}
                  copy?={true}
                  updates_enabled?={@updates_enabled?}
                />
              </div>
            </div>
          </div>
          <div
            :if={@wikipedia && @wikipedia.items != []}
            data-role="ticker-wikipedia"
            class="flex min-w-0 flex-wrap items-center border-t border-base-content/25"
          >
            <span
              data-role="ticker-wiki-label"
              class="shrink-0 border-e border-base-content/25 px-3 text-sm font-semibold"
            >
              <span class="sr-only">
                Trending on Wikipedia<span :if={PlatformWeb.SocialTodayTab.stale_trends?(@wikipedia)}> · {Calendar.strftime(@wikipedia.reporting_date, "%d %b")}</span>
              </span>
              <span
                data-role="ticker-wiki-label-mobile"
                aria-hidden="true"
                class="whitespace-nowrap sm:hidden"
              >
                <span class="font-serif">W</span> · Wikipedia
              </span>
              <span
                data-role="ticker-wiki-label-desktop"
                aria-hidden="true"
                class="hidden whitespace-nowrap sm:inline"
              >
                <span class="font-serif">W</span>
                · Trending on Wikipedia<span :if={
                  PlatformWeb.SocialTodayTab.stale_trends?(@wikipedia)
                }> · {Calendar.strftime(@wikipedia.reporting_date, "%d %b")}</span>
              </span>
            </span>
            <div
              data-wiki-viewport
              tabindex="0"
              aria-label="Trending on Wikipedia, scroll horizontally"
              class="social-ticker-viewport social-wiki-viewport overflow-x-auto overscroll-x-contain"
            >
              <div class="flex w-max">
                <div data-wiki-original class="flex shrink-0">
                  <.wikipedia_entries snapshot={@wikipedia} copy?={false} />
                </div>
                <div data-wiki-copy aria-hidden="true" class="social-ticker-copy flex shrink-0">
                  <.wikipedia_entries snapshot={@wikipedia} copy?={true} />
                </div>
              </div>
            </div>
          </div>
        </div>
        <div class="social-ticker-controls">
          <span class="social-ticker-reduced text-xs text-subtle">
            Reduced motion: scroll manually
          </span>
          <button
            type="button"
            data-ticker-toggle
            aria-pressed="false"
            class="btn btn-ghost btn-sm min-h-11 min-w-11"
          >
            Pause
          </button>
        </div>
      </div>
      <.video_details
        :if={@details_row}
        row={@details_row}
        all?={@scope == :all}
        updates_enabled?={@updates_enabled?}
      />
    </section>
    """
  end

  attr :snapshot, :map, required: true
  attr :copy?, :boolean, required: true

  defp wikipedia_entries(assigns) do
    ~H"""
    <button
      :for={{item, position} <- @snapshot.items |> Enum.take(10) |> Enum.with_index(1)}
      type="button"
      phx-click="ticker_wikipedia"
      tabindex={if @copy?, do: "-1"}
      data-role="ticker-wiki-entry"
      class="social-ticker-entry"
    >
      {position} · {item.title}
    </button>
    """
  end

  attr :rows, :list, required: true
  attr :all?, :boolean, required: true
  attr :copy?, :boolean, required: true
  attr :updates_enabled?, :boolean, required: true

  defp entries(assigns) do
    ~H"""
    <%= for row <- @rows do %>
      <.latest_video
        :if={Map.get(row, :latest_video)}
        row={row}
        all?={@all?}
        copy?={@copy?}
        updates_enabled?={@updates_enabled?}
      />
      <a
        href={results_url(row)}
        phx-click="ticker_results"
        phx-value-account_id={row.account.id}
        tabindex={if @copy?, do: "-1"}
        data-metric="views"
        data-account-id={row.account.id}
        class="social-ticker-entry"
      >
        <.account_label row={row} all?={@all?} />
        <span>Lifetime views · Burrow posts published in last 7 days</span>
        <span :if={row.views.posts == 0} class="text-subtle">
          No posts published in the last 7 days
        </span>
        <span :if={row.views.posts > 0 and is_nil(row.views.value)} class="text-subtle">
          Views not available
        </span>
        <span :if={not is_nil(row.views.value)} class="font-mono font-semibold tabular-nums">
          {number(row.views.value)}
          <span :if={row.views.measured < row.views.posts} class="font-sans text-xs text-subtle">
            ({row.views.measured} of {row.views.posts} posts measured)
          </span>
        </span>
        <span data-role="ticker-views-scope" class="text-xs text-subtle">
          Burrow-published posts only
        </span>
        <span :if={row.views.synced_at} class="text-xs text-subtle">
          Synced
          <time datetime={DateTime.to_iso8601(row.views.synced_at)}>
            {Calendar.strftime(row.views.synced_at, "%d %b %H:%M UTC")}
          </time>
        </span>
        <span :if={row.views_failed?} class="text-xs">
          Last refresh failed{if not is_nil(row.views.value), do: " · stored data"}
        </span>
        <span :if={row.views_deferred? and not row.views_failed?} class="text-xs">
          Analytics refresh deferred{if not is_nil(row.views.value), do: " · stored data"}
        </span>
      </a>
      <a
        :if={row.followers}
        href={results_url(row)}
        phx-click="ticker_results"
        phx-value-account_id={row.account.id}
        tabindex={if @copy?, do: "-1"}
        data-metric="followers"
        data-account-id={row.account.id}
        class="social-ticker-entry"
      >
        <.account_label row={row} all?={@all?} />
        <span>
          Followers ·
          <span class="font-mono font-semibold tabular-nums">{number(row.followers.value)}</span>
        </span>
        <time
          :if={row.followers.date}
          datetime={Date.to_iso8601(row.followers.date)}
          class="text-xs text-subtle"
        >
          {Calendar.strftime(row.followers.date, "%d %b")}
        </time>
        <span :if={is_nil(row.followers.change)} class="text-xs text-subtle">
          Change not available
        </span>
        <span
          :if={not is_nil(row.followers.change)}
          class={[
            "text-xs",
            row.followers.change > 0 && "text-success",
            row.followers.change < 0 && "text-error"
          ]}
        >
          <span aria-hidden="true">
            {if row.followers.change > 0,
              do: "↑",
              else: if(row.followers.change < 0, do: "↓", else: "")}
          </span>
          {signed(row.followers.change)} vs 7 days ago
        </span>
        <span :if={row.follower_target} class="font-mono text-xs tabular-nums">
          <%= if is_nil(row.followers.value) do %>
            Target {number(row.follower_target)}
          <% else %>
            {number(row.followers.value)} of {number(row.follower_target)}
          <% end %>
        </span>
        <span :if={row.follower_state && row.follower_state.source_stale} class="text-xs">
          Source data stale
        </span>
        <span :if={row.follower_state && row.follower_state.last_error} class="text-xs">
          Last refresh failed{if not is_nil(row.followers.value), do: " · stored data"}
        </span>
      </a>
      <a
        :if={row.weekly_progress}
        href={results_url(row)}
        phx-click="ticker_results"
        phx-value-account_id={row.account.id}
        tabindex={if @copy?, do: "-1"}
        data-metric="weekly-goal"
        data-account-id={row.account.id}
        class="social-ticker-entry"
      >
        <.account_label row={row} all?={@all?} />
        <span>Posts this week</span>
        <span class="font-mono font-semibold tabular-nums">
          {row.weekly_progress.published} of {row.weekly_progress.goal}
        </span>
      </a>
    <% end %>
    """
  end

  attr :row, :map, required: true
  attr :all?, :boolean, required: true
  attr :copy?, :boolean, required: true
  attr :updates_enabled?, :boolean, required: true

  defp latest_video(assigns) do
    projection = assigns.row.latest_video

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:video, projection.video)
      |> assign(:search_incomplete, Map.get(projection, :search_incomplete, true))
      |> assign(:figures_stale, figures_stale?(projection))
      |> assign(:discovery, kind(projection, :discovery))

    ~H"""
    <div data-role="ticker-latest-video" data-account-id={@row.account.id} class="social-ticker-entry">
      <.account_label row={@row} all?={@all?} />
      <span :if={not @updates_enabled?} data-role="ticker-youtube-updates-off">
        YouTube updates are off
      </span>
      <%= if @video do %>
        <a
          href={youtube_url(@video)}
          target="_blank"
          rel="noopener noreferrer"
          tabindex={if @copy?, do: "-1"}
          class="link"
        >
          {video_label(@projection)}
        </a>
        <span>{lifetime_views(@video.metrics["views"])}</span>
        <span>
          published
          <time datetime={DateTime.to_iso8601(@video.published_at)}>
            {strip_date(@video.published_at)}
          </time>
        </span>
        <span :if={@search_incomplete}>search incomplete</span>
        <span :if={not @search_incomplete and @figures_stale}>figures may be out of date</span>
      <% else %>
        <span :if={failed_request?(@discovery)}>Couldn't check YouTube for videos</span>
        <span :if={not failed_request?(@discovery) and @search_incomplete}>
          No YouTube video found yet · search incomplete
        </span>
        <span :if={not failed_request?(@discovery) and not @search_incomplete}>
          No YouTube video found in the dates checked, {ranges_text(@discovery.checked_ranges, :short)}
        </span>
      <% end %>
      <button
        type="button"
        id={if not @copy?, do: details_button_id(@row.account.id)}
        phx-click="ticker_video_details"
        phx-value-account_id={@row.account.id}
        data-role="ticker-data-details"
        tabindex={if @copy?, do: "-1"}
        aria-label={"Data details for " <> video_label(@projection) <> " on " <> (@row.account.handle || "this account")}
        aria-controls="ticker-video-details"
        aria-expanded={to_string(Map.get(@row, :ticker_details_open, false))}
        class="btn btn-ghost btn-sm min-h-11 min-w-11"
      >
        Data details
      </button>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :all?, :boolean, required: true
  attr :updates_enabled?, :boolean, required: true

  defp video_details(assigns) do
    projection = assigns.row.latest_video

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:video, projection.video)
      |> assign(:discovery, kind(projection, :discovery))
      |> assign(:refresh, kind(projection, :refresh))
      |> assign(:search_incomplete, Map.get(projection, :search_incomplete, true))
      |> assign(:figures_stale, figures_stale?(projection))
      |> assign(
        :response_set_aside,
        Map.get(
          projection,
          :response_set_aside,
          projection.video && projection.video.ambiguous_count > 0
        )
      )

    ~H"""
    <section
      id="ticker-video-details"
      data-role="ticker-video-details"
      role="region"
      aria-labelledby="ticker-video-details-heading"
      phx-window-keydown="ticker_video_details_close"
      phx-key="Escape"
      class="max-h-[65dvh] w-full min-w-0 space-y-3 overflow-y-auto overscroll-contain border-t border-base-content/25 p-4 pb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+10rem)] scroll-mb-[calc(env(safe-area-inset-bottom)+var(--bottom-nav-height,0px)+10rem)] whitespace-normal break-words sm:max-h-[32rem] sm:pb-4"
    >
      <div class="sticky top-0 z-10 flex min-w-0 items-start justify-between gap-3 bg-base-100">
        <h3
          id="ticker-video-details-heading"
          data-role="ticker-details-heading"
          tabindex="-1"
          class="font-semibold"
        >
          {video_label(@projection)} · {@row.account.handle}<span :if={@all?}> · {@row.profile.name}</span>
        </h3>
        <button
          type="button"
          phx-click="ticker_video_details_close"
          data-role="ticker-details-close"
          class="btn btn-ghost btn-sm min-h-11 min-w-11"
        >
          Close<span class="sr-only"> data details</span>
        </button>
      </div>
      <p :if={not @updates_enabled?} data-role="ticker-youtube-updates-off">
        YouTube updates are off
      </p>
      <a
        :if={@video}
        href={youtube_url(@video)}
        target="_blank"
        rel="noopener noreferrer"
        class="link"
      >
        Open on YouTube
      </a>
      <dl class="grid min-w-0 gap-x-4 gap-y-2 text-sm sm:grid-cols-[max-content_minmax(0,1fr)]">
        <%= if @video do %>
          <dt class="font-medium">Published</dt>
          <dd><.utc_time value={@video.published_at} /></dd>
          <dt class="font-medium">Lifetime views</dt>
          <dd>
            {if not is_nil(@video.metrics["views"]),
              do: number(@video.metrics["views"]),
              else: "Not available"}
          </dd>
          <dt class="font-medium">
            Vendor last-sync time{if @response_set_aside, do: " (for the figures shown)"}
          </dt>
          <dd data-role="ticker-vendor-time">
            <.utc_time :if={@video.vendor_synced_at} value={@video.vendor_synced_at} />
            <span :if={is_nil(@video.vendor_synced_at)}>
              No vendor time is recorded
            </span>
          </dd>
          <dt class="font-medium">Last response received by Burrow</dt>
          <dd>
            <.utc_time value={@projection.fetched_at} />
            <p :if={@response_set_aside}>
              That response conflicted and was set aside. The figures shown were kept from an earlier one.
            </p>
            <p>Time the shown figures were received: not available</p>
          </dd>
        <% end %>
        <dt class="font-medium">
          {if @discovery.coverage_unavailable,
            do: "Looking for videos",
            else: "Dates checked · looking for videos"}
        </dt>
        <dd>
          <%= if @discovery.coverage_unavailable do %>
            Dates checked: not available
          <% else %>
            {ranges_text(@discovery.checked_ranges)} (UTC)
          <% end %>
        </dd>
        <dt
          :if={not @discovery.coverage_unavailable and @discovery.incomplete_ranges != []}
          class="font-medium"
        >
          Looking for videos · incomplete dates
        </dt>
        <dd :if={not @discovery.coverage_unavailable and @discovery.incomplete_ranges != []}>
          {ranges_text(@discovery.incomplete_ranges)} (UTC)
        </dd>
        <dt class="font-medium">Search</dt>
        <dd>
          <%= cond do %>
            <% @discovery.coverage_unavailable -> %>
              Search incomplete. The dates still to check are not available.
            <% failed_request?(@discovery) -> %>
              {discovery_error(@discovery)}
            <% @search_incomplete and @discovery.incomplete_ranges == [] -> %>
              Search incomplete. The dates still to check are not available.
            <% @search_incomplete -> %>
              Incomplete: {ranges_text(@discovery.incomplete_ranges)} not yet checked.
            <% true -> %>
              Complete for {ranges_text(@discovery.checked_ranges)}.
          <% end %>
          <p :if={repair_pending?(@discovery)}>
            {"Stored search history was invalid and has been reset." <>
              if(@updates_enabled?, do: " A fresh scan is pending or under way.", else: "")}
          </p>
          <p :if={@discovery.last_error == "incomplete_observation"}>
            The vendor's page was incomplete (the request itself succeeded).
          </p>
          <p :if={
            Map.get(@projection, :newer_possible, false) and not @discovery.coverage_unavailable and
              not @refresh.coverage_unavailable
          }>
            A newer video may exist.
          </p>
          <p :if={Map.get(@projection, :selection_uncertain, false)}>
            A newer stored observation was absent from a completed list scan; that does not establish deletion or privacy.
          </p>
        </dd>
        <%= if @video do %>
          <dt class="font-medium">
            {if @refresh.coverage_unavailable,
              do: "Updating figures",
              else: "Dates checked · updating figures"}
          </dt>
          <dd>
            <%= if @refresh.coverage_unavailable do %>
              Dates checked: not available
            <% else %>
              {ranges_text(@refresh.checked_ranges)} (UTC)
            <% end %>
          </dd>
          <dt :if={@refresh.coverage_unavailable} class="font-medium">
            Updating figures · dates remaining
          </dt>
          <dd :if={@refresh.coverage_unavailable}>The dates still to check are not available.</dd>
          <dt
            :if={not @refresh.coverage_unavailable and @refresh.incomplete_ranges != []}
            class="font-medium"
          >
            Updating figures · incomplete dates
          </dt>
          <dd :if={not @refresh.coverage_unavailable and @refresh.incomplete_ranges != []}>
            {ranges_text(@refresh.incomplete_ranges)} (UTC)
          </dd>
          <dt class="font-medium">Figures</dt>
          <dd>
            <p :if={
              not @figures_stale and is_nil(@refresh.last_error) and not repair_pending?(@refresh) and
                not @refresh.coverage_unavailable
            }>
              No refresh problem is recorded.
            </p>
            <p :if={repair_pending?(@refresh)}>
              {"Stored update history was invalid and has been reset." <>
                if(@updates_enabled?, do: " A fresh scan is pending or under way.", else: "")}
            </p>
            <p :if={@figures_stale}>These figures may be out of date.</p>
            <p :if={@video.ambiguous_count > 0}>
              A response conflicted with the stored reading or was older, so it was set aside. The figures shown are the last ones Burrow trusted.
            </p>
            <p :if={@video.ambiguous_count >= 3}>
              This has happened for at least three consecutive responses. It needs a person to look at it.
            </p>
            <p :if={@video.sync_status == "pending"}>
              The vendor reports this video's figures as pending. These are the stored figures.
            </p>
            <p :if={@video.sync_status == "unavailable"}>
              The vendor reports this video's figures as unavailable. These are the stored figures.
            </p>
            <p :if={
              @refresh.last_error == "incomplete_observation" and
                refresh_covers_video?(@refresh, @video)
            }>
              The vendor's page was incomplete (the request itself succeeded).
            </p>
            <p :if={refresh_failed_for_video?(@refresh, @video)}>
              Updating this video's figures last failed at {utc_or_unknown(@refresh.attempted_at)}: {reason(
                @refresh.last_error
              )}. These are the stored figures.
            </p>
          </dd>
        <% end %>
      </dl>
    </section>
    """
  end

  attr :value, :any, required: true

  defp utc_time(assigns) do
    ~H"""
    <time :if={@value} datetime={DateTime.to_iso8601(@value)}>{utc_or_unknown(@value)}</time><span :if={
      is_nil(@value)
    }>Not available</span>
    """
  end

  defp kind(projection, name) do
    defaults = %{
      checked_ranges: [],
      incomplete_ranges: [],
      coverage_unavailable: false,
      coverage_repaired_at: nil,
      last_error: nil,
      attempted_at: nil,
      from_date: nil,
      to_date: nil
    }

    Map.merge(defaults, Map.get(projection, name) || %{})
  end

  defp figures_stale?(projection) do
    video = projection.video

    Map.get(
      projection,
      :figures_stale,
      not is_nil(video) and
        (video.source_stale or video.ambiguous_count > 0 or
           video.sync_status in ["pending", "unavailable"])
    )
  end

  defp video_label(%{video: nil}), do: "YouTube video search"

  defp video_label(projection) do
    if Map.get(projection, :search_incomplete, true) or
         Map.get(projection, :selection_uncertain, false),
       do: "Most recent YouTube video found",
       else: "Latest YouTube video"
  end

  defp youtube_url(video), do: "https://www.youtube.com/watch?v=" <> video.native_id
  defp details_button_id(account_id), do: "ticker-video-details-button-" <> account_id
  defp lifetime_views(nil), do: "views not available"
  defp lifetime_views(1), do: "1 lifetime view"
  defp lifetime_views(value), do: number(value) <> " lifetime views"

  defp strip_date(at) do
    Calendar.strftime(at, if(at.year == Date.utc_today().year, do: "%-d %b", else: "%-d %b %Y"))
  end

  defp utc_or_unknown(nil), do: "Not available"
  defp utc_or_unknown(at), do: Calendar.strftime(at, "%-d %b %Y, %H:%M:%S UTC")
  defp ranges_text(ranges, format \\ :long)
  defp ranges_text([], _), do: "Not checked yet"

  defp ranges_text(ranges, format) do
    Enum.map_join(ranges, ", and ", fn %{"from" => from, "to" => to} ->
      with {:ok, from} <- Date.from_iso8601(from), {:ok, to} <- Date.from_iso8601(to) do
        pattern = if format == :short, do: "%-d %b", else: "%-d %b %Y"
        Calendar.strftime(from, pattern) <> " to " <> Calendar.strftime(to, pattern)
      else
        _ -> "Dates not available"
      end
    end)
  end

  defp reason("rate_limited"), do: "the vendor asked Burrow to slow down"
  defp reason("pending"), do: "the vendor was still preparing the data"
  defp reason("unavailable"), do: "the vendor could not provide the data"

  defp reason("cursor_rejected"),
    do: "the vendor rejected Burrow's place in the list, so that check starts again"

  defp reason("incomplete_observation"),
    do: "the vendor's page was incomplete (the request itself succeeded)"

  defp reason(_), do: "the request failed"

  defp discovery_error(state),
    do:
      "Looking for videos in " <>
        request_dates(state) <>
        " last failed at " <>
        utc_or_unknown(state.attempted_at) <> ": " <> reason(state.last_error) <> "."

  defp request_dates(%{from_date: %Date{} = from, to_date: %Date{} = to}),
    do: ranges_text([%{"from" => Date.to_iso8601(from), "to" => Date.to_iso8601(to)}])

  defp request_dates(_), do: "dates not available"

  defp repair_pending?(state),
    do: state.last_error == "coverage_repaired" or not is_nil(state.coverage_repaired_at)

  defp failed_request?(%{last_error: error}),
    do: error not in [nil, "incomplete_observation", "coverage_repaired"]

  defp refresh_failed_for_video?(refresh, video),
    do: failed_request?(refresh) and refresh_covers_video?(refresh, video)

  defp refresh_covers_video?(
         %{from_date: %Date{} = from, to_date: %Date{} = to},
         %{published_at: %DateTime{} = at}
       ) do
    day = DateTime.to_date(at)
    Date.compare(day, from) != :lt and Date.compare(day, to) != :gt
  end

  defp refresh_covers_video?(_, _), do: false

  attr :row, :map, required: true
  attr :all?, :boolean, required: true

  defp account_label(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1.5 font-semibold">
      <span
        :if={@row.account.platform in ~w(x linkedin instagram youtube tiktok)}
        data-role="ticker-platform"
        title={SocialHelpers.platform_label(@row.account.platform)}
        class="inline-flex items-center"
      >
        <SocialPreview.glyph platform={@row.account.platform} class="size-4 shrink-0" />
        <span class="sr-only">{SocialHelpers.platform_label(@row.account.platform)}</span>
      </span>
      <span :if={@row.account.platform not in ~w(x linkedin instagram youtube tiktok)}>
        {SocialHelpers.platform_label(@row.account.platform)}
      </span>
      <span class="font-normal">{@row.account.handle}</span>
    </span>
    <span :if={@all?} class="text-xs text-subtle">{@row.profile.name}</span>
    """
  end

  defp results_url(row),
    do:
      "/m/social?" <>
        URI.encode_query(%{
          tab: "results",
          profile: row.profile.id,
          account: row.account.id,
          period: 7
        })

  defp number(nil), do: "not available"

  defp number(value) when is_integer(value),
    do: Regex.replace(~r/(\d)(?=(\d{3})+$)/, Integer.to_string(value), "\\1,")

  defp number(value), do: to_string(value)
  defp signed(value) when value > 0, do: "+" <> number(value)
  defp signed(value), do: number(value)
end
