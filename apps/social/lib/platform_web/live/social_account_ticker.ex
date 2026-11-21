defmodule PlatformWeb.SocialAccountTicker do
  @moduledoc "The scoped account strip: dated audience observations and measured Burrow post cohorts."
  use PlatformWeb, :html
  alias Platform.Social
  alias Platform.Social.AccountTicker
  alias PlatformWeb.{SocialHelpers, SocialPreview, SocialScope}

  @doc "Refresh the metric slice without touching tabs, streams or an open editor."
  def load(socket) do
    ids = scoped_ids(socket.assigns)
    assign(socket, :ticker_rows, AccountTicker.rows(SocialHelpers.fresh_user(socket), ids))
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

    for row <- Map.get(assigns, :ticker_rows, []),
        current = by_id[row.account.id],
        not is_nil(current),
        current.provider_account_ref == row.account.provider_account_ref do
      %{
        row
        | account: current,
          follower_target: if(current.platform != "linkedin", do: current.follower_target)
      }
    end
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

  def strip(assigns) do
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

    ~H"""
    <section
      :if={@rows != []}
      id="social-account-ticker"
      phx-hook="SocialTicker"
      data-role="social-account-ticker"
      data-scope-key={@scope_key}
      class="social-account-ticker mt-3 rounded-lg border border-base-content/25 bg-base-100 text-sm"
      aria-label="Account performance"
    >
      <div
        data-ticker-viewport
        tabindex="0"
        aria-label="Account performance, scroll horizontally"
        class="social-ticker-viewport overflow-x-auto overscroll-x-contain"
      >
        <div class="flex w-max" data-ticker-track>
          <div data-ticker-original class="flex shrink-0">
            <.entries rows={@rows} all?={@scope == :all} copy?={false} />
          </div>
          <div data-ticker-copy aria-hidden="true" class="social-ticker-copy flex shrink-0">
            <.entries rows={@rows} all?={@scope == :all} copy?={true} />
          </div>
        </div>
      </div>
      <div class="social-ticker-controls">
        <span class="social-ticker-reduced text-xs text-subtle">Reduced motion: scroll manually</span>
        <button
          type="button"
          data-ticker-toggle
          aria-pressed="false"
          class="btn btn-ghost btn-sm min-h-11 min-w-11"
        >
          Pause
        </button>
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :all?, :boolean, required: true
  attr :copy?, :boolean, required: true

  defp entries(assigns) do
    ~H"""
    <%= for row <- @rows do %>
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
        <span>Views · posts published in the last 7 days</span>
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
