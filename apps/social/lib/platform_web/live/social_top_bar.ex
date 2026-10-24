defmodule PlatformWeb.SocialTopBar do
  @moduledoc """
  The Social top bar (Social authoring 1/11), the same on every tab:

    * The brand switcher: "All brands" above the profiles, each option with
      its needs-approval count (ONE grouped query,
      `Platform.Social.needs_approval_counts/1`). All brands is a valid view
      only on tabs whose module says `all_brands?/0`; on the others the body
      shows `pick_brand/1` ("Pick a brand to see <Tab>" and the profiles)
      instead of a half-scoped pane.
    * The waiting count: needs-approval posts across every visible profile.
      With one brand in scope it shows (when there is more than one brand)
      as a link into All brands; in All brands the needs-approval badge
      itself is the total.
    * The health dot (red, aria-label and tooltip listing the causes): any
      visible profile whose `Platform.Social.Health.profile/1` state is not
      `:ok` (Social authoring 9/11), the same computation the Connections
      rows show: an account not connected or disconnected, an Instagram
      personal account, or a post that failed or was refused before the
      vendor in the last 7 days. It opens Connections on the
      first affected profile (`health_open`).
    * The composer's "New idea" button (`PlatformWeb.SocialComposer`, off
      until authoring 6/11), "+ New profile", and the tab strip.

  `assign_status/1` reads everything the bar shows for the CURRENT
  `@profiles` (always a fresh `list_profiles_for_user/1`), through
  `Platform.Social.list_accounts_for_profiles/3` and
  `Platform.Social.Health.by_profile/2` (whose post reads are limited to
  those accounts).
  """

  use PlatformWeb, :html

  alias Platform.Social
  alias Platform.Social.Health
  alias PlatformWeb.{SocialComposer, SocialCreateProfile, SocialHelpers, SocialScope}

  # Header actions, each with `enabled?/0` and `button/1`; shown only while
  # enabled. Read through the list (not a direct call) so a stub's constant
  # `false` is not a dead branch to the type checker.
  @header_actions [SocialComposer]

  @doc "Assigns `:waiting_total` and `:health` (a list of causes, first-affected first)."
  def assign_status(%{assigns: assigns} = socket) do
    socket
    |> assign(:waiting_total, SocialScope.waiting_total(assigns.counts))
    |> assign(:health, health(assigns[:user], assigns.profiles))
  end

  @doc """
  The health dot's causes, `[%{profile_id, text}]`, in switcher order
  (accounts before posts within a profile). Empty: no dot.
  """
  def health(_user, []), do: []
  def health(nil, _profiles), do: []

  def health(user, profiles) do
    healths =
      user
      |> Social.list_accounts_for_profiles(Enum.map(profiles, & &1.id))
      |> Health.by_profile()

    Enum.flat_map(profiles, fn profile ->
      case Map.get(healths, profile.id) do
        %{state: :ok} -> []
        nil -> []
        %{accounts: rows} -> causes(profile, rows)
      end
    end)
  end

  # The dot's causes for one profile, from `Platform.Social.Health.profile/1`:
  # each unhealthy account's own reasons first, then one line counting the
  # failed or refused posts.
  defp causes(profile, rows) do
    account_causes =
      for {account, health} <- rows,
          reason <- health.reasons,
          reason.code in [:not_connected, :disconnected, :personal_instagram] do
        %{profile_id: profile.id, text: account_cause(account, reason.code, profile)}
      end

    post_causes =
      case Enum.sum(Enum.map(rows, fn {_account, health} -> health.failure_count end)) do
        0 -> []
        n -> [%{profile_id: profile.id, text: posts_cause(n, profile)}]
      end

    account_causes ++ post_causes
  end

  defp account_cause(account, code, profile) do
    state =
      case code do
        :disconnected -> "needs reconnecting"
        :personal_instagram -> "is a personal account"
        _ -> "isn't connected"
      end

    "#{SocialHelpers.platform_label(account.platform)} on #{profile.name} #{state}"
  end

  defp posts_cause(1, profile),
    do: "1 post on #{profile.name} failed or was not published in the last 7 days"

  defp posts_cause(n, profile),
    do: "#{n} posts on #{profile.name} failed or were not published in the last 7 days"

  attr :profiles, :list, required: true
  attr :profile, :map, required: true
  attr :scope, :any, required: true
  attr :counts, :map, required: true
  attr :waiting_total, :integer, required: true
  attr :health, :list, required: true
  attr :can_create?, :boolean, required: true
  attr :create_open?, :boolean, required: true
  attr :create_form, :any, required: true
  attr :creatable_orgs, :list, required: true
  attr :tab, :string, required: true
  attr :tab_items, :list, required: true, doc: "[%{key, label, badge}] in strip order"

  def top_bar(assigns) do
    assigns =
      assigns
      |> assign(:actions, Enum.filter(@header_actions, & &1.enabled?()))
      |> assign(
        :scope_count,
        if(assigns.scope == :all,
          do: assigns.waiting_total,
          else: SocialScope.count(assigns.counts, assigns.profile)
        )
      )

    ~H"""
    <header class="border-b border-base-300 px-4 pt-4 sm:px-6" data-role="social-top-bar">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
        <form id="social-profile-switcher" phx-change="switch_profile" class="min-w-0">
          <label for="social-profile-select" class="sr-only">Profile</label>
          <select
            id="social-profile-select"
            name="profile_id"
            class="select select-ghost w-auto max-w-full bg-base-100 text-xl font-bold"
            data-role="social-profile-select"
          >
            <option
              value="all"
              selected={@scope == :all}
              data-role="social-profile-option-all"
              data-count={@waiting_total}
            >
              All brands {@waiting_total}
            </option>
            <option
              :for={profile <- @profiles}
              value={profile.id}
              selected={@scope != :all and profile.id == @profile.id}
              data-role="social-profile-option"
              data-count={SocialScope.count(@counts, profile)}
            >
              {profile.name} {SocialScope.count(@counts, profile)}
            </option>
          </select>
        </form>
        <span
          :if={@scope_count > 0}
          class="badge badge-warning whitespace-nowrap"
          data-role="social-needs-approval"
        >
          {@scope_count} need approval
        </span>
        <span
          :if={@scope_count == 0}
          class="whitespace-nowrap text-sm text-base-content"
          data-role="social-needs-approval"
        >
          0 need approval
        </span>
        <button
          :if={@scope != :all and length(@profiles) > 1}
          type="button"
          class="btn btn-ghost btn-xs whitespace-nowrap text-base-content"
          phx-click="switch_profile"
          phx-value-profile_id="all"
          data-role="social-waiting-count"
          data-count={@waiting_total}
        >
          {@waiting_total} waiting in all brands
        </button>
        <.health_dot :if={@health != []} health={@health} />
        <span class="ml-auto flex items-center gap-2">
          <%= for action <- @actions do %>
            {action.button(%{})}
          <% end %>
          <button
            :if={@can_create?}
            type="button"
            class="btn btn-ghost btn-sm whitespace-nowrap"
            phx-click={if @create_open?, do: "close_create", else: "open_create"}
            aria-expanded={to_string(@create_open?)}
            aria-controls="social-create-panel"
            data-role="social-new-profile"
          >
            + New profile
          </button>
        </span>
      </div>

      <SocialCreateProfile.panel
        :if={@can_create? and @create_open?}
        form={@create_form}
        orgs={@creatable_orgs}
      />

      <nav
        class="tabs tabs-border -mb-px mt-3 flex-nowrap overflow-x-auto whitespace-nowrap"
        role="tablist"
        aria-label="Social sections"
        data-role="social-tabs"
      >
        <button
          :for={item <- @tab_items}
          type="button"
          role="tab"
          class={[
            "tab shrink-0",
            @tab == item.key && "tab-active"
          ]}
          aria-selected={to_string(@tab == item.key)}
          phx-click="select_tab"
          phx-value-tab={item.key}
          data-role="social-tab-button"
          data-tab={item.key}
        >
          {item.label}
          {item.badge}
        </button>
      </nav>
    </header>
    """
  end

  attr :health, :list, required: true

  defp health_dot(assigns) do
    assigns = assign(assigns, :summary, Enum.map_join(assigns.health, "; ", & &1.text))

    ~H"""
    <span class="tooltip tooltip-bottom" data-tip={@summary}>
      <button
        type="button"
        class="btn btn-ghost btn-xs btn-circle"
        phx-click="health_open"
        phx-value-profile_id={hd(@health).profile_id}
        aria-label={"Needs attention: " <> @summary}
        data-role="social-health-dot"
        data-profile-id={hd(@health).profile_id}
      >
        <span class="block size-2.5 rounded-full bg-error" aria-hidden="true"></span>
      </button>
    </span>
    """
  end

  attr :label, :string, required: true
  attr :profiles, :list, required: true
  attr :counts, :map, required: true

  @doc "All brands on a per-brand tab: the prompt and the profiles to pick from."
  def pick_brand(assigns) do
    ~H"""
    <div class="max-w-md space-y-3" data-role="social-pick-brand">
      <p class="text-base-content">Pick a brand to see {@label}</p>
      <ul class="divide-y divide-base-300 rounded-lg border border-base-300 bg-base-100">
        <li :for={profile <- @profiles}>
          <button
            type="button"
            class="flex w-full items-center justify-between gap-3 px-3 py-2 text-left hover:bg-base-200"
            phx-click="switch_profile"
            phx-value-profile_id={profile.id}
            data-role="social-pick-brand-option"
            data-profile-id={profile.id}
          >
            <span class="min-w-0 truncate">{profile.name}</span>
            <span class="text-sm text-base-content">
              {SocialScope.count(@counts, profile)} need approval
            </span>
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
