defmodule PlatformWeb.SocialLive do
  @moduledoc """
  The Social tab (task 01a140a9-9e19, Social 7/7), nested by core's generic
  `/m/<prefix>` page (`Platform.Extension.live_pages/0`).

  ## A shell over a tab registry (Social authoring 1/11)

  This module owns only the shell: mount, the brand scope, routing, and the
  frame the panes sit in. Everything a tab does lives in that tab's own
  module, listed by `PlatformWeb.SocialTabs` (Queue, Ideas, Calendar,
  Clips, Results, Connections, Settings; see `PlatformWeb.SocialTab` for the
  callbacks). The strip, the panes, event routing (`events/0`), messages
  (`handle_info/2`), per-profile loads (`load/1`) and URL params
  (`from_query/2`) all come from the registry, so a new or changed tab
  never edits this file. A tab whose `enabled?/0` is false adds nothing:
  no button, no `data-tab`, no pane.

  The top bar is `PlatformWeb.SocialTopBar`; creating a profile is
  `PlatformWeb.SocialCreateProfile`; the invitee page is
  `PlatformWeb.SocialInviteLanding`.

  ## Nothing is inherited from the parent page

  Core hands this LiveView `%{"user_id" => id}` (plus the bounded, untrusted
  `"query"` described under the OAuth return in
  `PlatformWeb.SocialConnectionsTab`) and runs no live_session hook on it.
  `mount/3` re-reads the user (`Platform.Accounts.get_user/1`), lists the
  profiles that user may see (`Platform.Social.list_profiles_for_user/1`,
  built on the RBAC swap points) and every event re-checks against a fresh
  read, never against an id the client sent.

  ## One brand at a time, or All brands

  The header select is the brand switcher. Switching keeps the current tab
  and goes through ONE `PlatformWeb.SocialScope.load_profile/2`, which is
  where every per-profile stream is (re)loaded with `reset: true`, so
  nothing of the previous profile survives a switch. "All brands" sets the
  `:scope` assign to `:all` (`PlatformWeb.SocialScope`); a per-brand tab
  then shows "Pick a brand" instead of its pane.

  ## The landing pages

  `?invite=<token>` (and a failed invite connect) render the invitee page
  INSTEAD of the profile UI. The vendor's OAuth return is landed on the
  connected mount, for live humans only, by
  `PlatformWeb.SocialConnectionsTab.handle_return/3`.
  """
  use PlatformWeb, :live_view

  import PlatformWeb.SocialHelpers, only: [human?: 1]

  alias Platform.Social

  alias PlatformWeb.{
    SocialConnectionsTab,
    SocialCreateProfile,
    SocialInviteLanding,
    SocialScope,
    SocialTabs,
    SocialTopBar
  }

  @impl true
  def mount(_params, session, socket) do
    user = Platform.Accounts.get_user(session["user_id"])
    profiles = if user, do: Social.list_profiles_for_user(user), else: []
    tabs = SocialTabs.tabs()

    socket =
      socket
      |> assign(:user, user)
      |> assign(:tabs, tabs)
      |> assign(:tab, "queue")
      |> assign(:profile, nil)
      |> assign(:scope, {:profile, nil})
      |> assign(:can_edit?, false)
      |> assign(:detail, nil)
      |> assign(:notice, nil)
      |> assign(:notice_tone, :info)
      |> assign(:create_open?, false)
      |> SocialCreateProfile.assign_creatable(SocialCreateProfile.creatable_orgs(user))
      |> SocialScope.assign_profiles(profiles)
      |> assign(:landing, nil)
      |> assign(:invite_token, nil)
      |> assign(:invite_nonce, nil)

    socket = SocialTabs.reduce(tabs, socket, fn mod, acc -> mod.init(acc) end)
    socket = SocialScope.load_profile(socket, List.first(profiles))
    query = session["query"]

    socket =
      case SocialInviteLanding.landing_params(query) do
        # The invitee landing page (task 01a14ce1, stage 4): rendered
        # INSTEAD of the profile UI. Resolving the invite reads only, so it
        # runs on the static render too.
        {:invite, token} ->
          SocialInviteLanding.assign_invite_landing(socket, token, user)

        # A cancelled or failed vendor connect started from an invite.
        {:invite_failed, nonce} ->
          if connected?(socket),
            do: SocialInviteLanding.assign_failed_landing(socket, nonce, user),
            else: assign(socket, :landing, %{state: :checking})

        :none ->
          # The OAuth return: connected mount only (the static render sends
          # no vendor request, so the vendor is asked once), live humans only.
          cond do
            connected?(socket) and human?(user) ->
              socket
              |> SocialConnectionsTab.handle_return(
                profiles,
                SocialConnectionsTab.return_params(query)
              )
              |> select_from_query(profiles, query)

            is_map(query) and is_map_key(query, "invite_connect") and human?(user) ->
              assign(socket, :landing, %{state: :checking})

            true ->
              select_from_query(socket, profiles, query)
          end
      end

    {:ok, socket}
  end

  # A profile id, or "all" (All brands). Re-read what this user may see NOW;
  # an id outside it changes nothing.
  @impl true
  def handle_event("switch_profile", %{"profile_id" => id}, socket) do
    profiles = SocialScope.visible_profiles(socket)
    socket = SocialScope.assign_profiles(socket, profiles)

    cond do
      id == "all" and profiles != [] -> {:noreply, SocialScope.select_all(socket)}
      profile = Enum.find(profiles, &(&1.id == id)) -> {:noreply, open_profile(socket, profile)}
      true -> {:noreply, socket}
    end
  end

  def handle_event("select_tab", %{"tab" => tab}, socket),
    do: {:noreply, SocialScope.select_tab(socket, tab)}

  # The health dot: Connections on the first affected profile, which must
  # be among the profiles visible NOW.
  def handle_event("health_open", %{"profile_id" => id}, socket) do
    profiles = SocialScope.visible_profiles(socket)
    socket = SocialScope.assign_profiles(socket, profiles)

    case Enum.find(profiles, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      profile ->
        {:noreply, socket |> open_profile(profile) |> SocialScope.select_tab("connections")}
    end
  end

  def handle_event("dismiss_notice", _params, socket),
    do: {:noreply, assign(socket, :notice, nil)}

  def handle_event(event, params, socket) do
    cond do
      event in SocialCreateProfile.events() ->
        SocialCreateProfile.handle_event(event, params, socket)

      event in SocialInviteLanding.events() ->
        SocialInviteLanding.handle_event(event, params, socket)

      mod = SocialTabs.event_owner(socket.assigns.tabs, event) ->
        mod.handle_event(event, params, socket)

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info(message, socket),
    do: SocialTabs.handle_info(socket.assigns.tabs, message, socket)

  # Leaving All brands for one brand re-runs the current tab's selection
  # (Connections reconciles on open) once that brand has loaded.
  defp open_profile(socket, profile) do
    was_all? = SocialScope.all?(socket)
    socket = SocialScope.load_profile(socket, profile)
    if was_all?, do: SocialScope.select_tab(socket, socket.assigns.tab), else: socket
  end

  # ?tab=connections&profile=<id> (the landing page's link back to a used
  # invite's account): an enabled tab and a profile among the VISIBLE ones,
  # else ignored. Each tab then reads its own params (`from_query/2`).
  defp select_from_query(socket, profiles, %{} = query) do
    socket =
      case Enum.find(profiles, &(&1.id == query["profile"])) do
        nil -> socket
        profile -> SocialScope.load_profile(socket, profile)
      end

    socket
    |> then(
      &SocialTabs.reduce(&1.assigns.tabs, &1, fn mod, acc -> mod.from_query(acc, query) end)
    )
    |> SocialScope.select_tab(query["tab"])
  end

  defp select_from_query(socket, _profiles, _query), do: socket

  @impl true
  def render(assigns) do
    assigns = assign_views(assigns)

    ~H"""
    <div class="flex h-full min-h-0 flex-col" data-role="social-tab">
      <%= cond do %>
        <% @landing -> %>
          <SocialInviteLanding.page landing={@landing} />
        <% @profile -> %>
          <SocialTopBar.top_bar
            profiles={@profiles}
            profile={@profile}
            scope={@scope}
            counts={@counts}
            waiting_total={@waiting_total}
            health={@health}
            can_create?={@can_create?}
            create_open?={@create_open?}
            create_form={@create_form}
            creatable_orgs={@creatable_orgs}
            tab={@tab}
            tab_items={@tab_items}
          />
          <section
            class="min-h-0 flex-1 overflow-y-auto px-4 py-4 sm:px-6"
            data-role="social-tab-body"
            data-tab={@tab}
          >
            <SocialTopBar.pick_brand
              :if={@pick_brand}
              label={@pick_brand}
              profiles={@profiles}
              counts={@counts}
            />
            <%!-- Every enabled pane stays in the DOM (hidden when inactive,
               or when All brands is in scope on a per-brand tab) so its
               stream survives a tab change. --%>
            <div
              :for={pane <- @pane_views}
              class={[pane.hidden? && "hidden"]}
              data-pane={pane.key}
            >
              {pane.body}
            </div>
          </section>
          <%= for overlay <- @overlays do %>
            {overlay}
          <% end %>
        <% true -> %>
          <SocialCreateProfile.empty_state
            can_create?={@can_create?}
            form={@create_form}
            orgs={@creatable_orgs}
          />
      <% end %>
    </div>
    """
  end

  # The registry's tabs rendered for these assigns: each strip label and
  # badge, each pane, and the overlays. Built here, outside the template,
  # because each body comes from its tab module.
  defp assign_views(%{profile: nil} = assigns),
    do: assign(assigns, tab_items: [], pane_views: [], overlays: [], pick_brand: nil)

  defp assign_views(%{tabs: tabs, tab: current, scope: scope} = assigns) do
    blocked? = fn tab -> scope == :all and not tab.module.all_brands?() end

    assign(assigns,
      tab_items:
        Enum.map(tabs, fn tab ->
          %{
            key: tab.key,
            label: tab.module.tab_label(assigns) || tab.label,
            badge: tab.module.tab_badge(assigns)
          }
        end),
      pane_views:
        Enum.map(tabs, fn tab ->
          %{
            key: tab.key,
            hidden?: tab.key != current or blocked?.(tab),
            body: tab.module.pane(assigns)
          }
        end),
      overlays: Enum.map(tabs, & &1.module.overlay(assigns)),
      pick_brand:
        case SocialTabs.get(tabs, current) do
          %{label: label} = tab -> if blocked?.(tab), do: label
          nil -> nil
        end
    )
  end
end
