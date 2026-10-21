defmodule PlatformWeb.ChatLive.Partials.ExternalRail do
  @moduledoc """
  The external-user chat chrome: the desktop rail and its mobile switcher.

  Same split as `ChatLive.Partials` (ADR 0035) — function components, no
  state, each taking a declared set of attrs. These two regions render ONLY
  on the `:external` layout, which is why they were the first slice of
  `chat_live.html.heex` to move: a mistake here cannot reach internal chat.

  Extracted here (task 01a0312e stage 2, markup unchanged):

    * `external_rail/1` — the chrome-less desktop space rail (`hidden lg:flex`)
    * `external_mobile_switcher/1` — its full-screen mobile counterpart

  `masked_space_name/2` stays in `PlatformWeb.ChatLive` — stage 1 left it
  there because it reads LiveView assigns by key — so it is called
  fully-qualified and fed a `@mask_assigns` map built from this component's
  own attrs. That is why `sidebar_sections`, `mask_names?` and
  `revealed_section_ids` are declared attrs: the masking rule reads exactly
  those three keys, and a component that did not declare them would silently
  mask nothing.
  """

  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.AvatarComponents, only: [human_avatar: 1]

  import PlatformWeb.ChatLive.RenderHelpers,
    only: [drawer_filter_external_spaces: 3, sidebar_display_name: 2, unread_label: 1]

  alias Phoenix.LiveView.JS
  alias PlatformWeb.ChatLive

  @mask_keys [:sidebar_sections, :mask_names?, :revealed_section_ids]

  attr(:external?, :boolean, required: true)
  attr(:external_user, :any, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  attr(:sidebar_sections, :list, default: [])
  attr(:mask_names?, :boolean, default: false)
  attr(:revealed_section_ids, :any, default: nil)

  @doc """
  rbac-external-users M5: the chrome-less external space rail.

  When `@external?` (M4 merges `chat_mode: "external"` into the connect session
  on the `chat.` host), ChatLive renders THIS branch INSTEAD of the internal
  discovery rail — a single flat allowlisted-space list with NO sub-org section
  headers, NO pinned-task / archived sections, and NO new-channel / scope-pill
  / edit-layout / admin chrome (each of which leaks the internal workspace org
  tree). M4's `:external` app layout is chrome-less, so the brand +
  identity chip + logout that the icon-rail normally carries are rendered here
  at the rail head. Two paths, one ChatLive — mirrors the shipped `meet.` guest
  branch. Semantic DaisyUI tokens only (brand cyan primary is themed in
  app.css); mobile-first single column with env(safe-area-inset-*) padding.

  `hidden lg:flex` (task 019f9257-a83e): the external rail is desktop-only,
  mirroring the internal `#chat-sidebar` gate. On mobile it collapses entirely
  so the conversation pane spans the full viewport; the mobile substitute is
  the pills strip + `external_mobile_switcher/1` (both `lg:hidden`).
  """
  def external_rail(assigns) do
    assigns =
      assigns
      |> assign(:external_spaces, assigns.channels ++ assigns.dm_conversations)
      |> assign(:mask_assigns, Map.take(assigns, @mask_keys))
      |> assign_brand_name()

    ~H"""
    <aside
      :if={@external?}
      id="chat-external-rail"
      data-role="external-rail"
      class="hidden lg:flex w-72 max-w-[80vw] flex-shrink-0 flex-col border-r border-edge bg-base-200 lg:w-64"
    >
      <header
        class="flex-shrink-0 border-b border-edge"
        style="padding-top: env(safe-area-inset-top); padding-left: env(safe-area-inset-left);"
        data-role="external-rail-header"
      >
        <div class="flex items-center justify-between px-3 py-2.5">
          <div class="flex items-center gap-2 min-w-0" data-role="brand-chip">
            <img src={~p"/images/burrow-mark.svg"} alt={@brand_name} class="size-6 flex-shrink-0" />
            <span class="truncate text-sm font-semibold tracking-tight text-base-content">
              {@brand_name}
            </span>
          </div>
          <a
            href={~p"/auth/logout"}
            class="btn btn-ghost btn-sm btn-square"
            aria-label="Log out"
            data-role="external-logout"
          >
            <span class="hero-arrow-right-start-on-rectangle size-5"></span>
          </a>
        </div>
        <%!-- Identity chip: who the external user is signed in as. Avatar + name
             only — NO org label (that would leak internal structure per canvas
             §7). --%>
        <div
          :if={@external_user}
          class="flex items-center gap-2 border-t border-edge px-3 py-2"
          data-role="external-identity"
        >
          <.human_avatar
            name={@external_user.name || @external_user.email || "You"}
            avatar_url={@external_user.avatar_url}
            seed={@external_user.oidc_sub || @external_user.email || @external_user.id}
            size="sm"
            class="flex-shrink-0"
          />
          <span class="truncate text-sm text-base-content">
            {@external_user.name || @external_user.email}
          </span>
        </div>
      </header>

      <nav
        class="flex-1 overflow-y-auto py-2"
        aria-label="Your spaces"
        data-role="external-space-list"
      >
        <%= if @external_spaces == [] do %>
          <%!-- Calm zero-allowlist empty state (Saru direction). NEVER the internal
               "browse other channels" new-user hint — that would advertise a
               discovery surface that does not exist for this user. --%>
          <div
            class="flex h-full flex-col items-center justify-center gap-2 px-6 text-center"
            data-role="external-empty"
          >
            <span class="hero-chat-bubble-left-right size-8 text-subtle"></span>
            <p class="text-sm font-medium text-base-content">Nothing here yet</p>
            <p class="text-xs text-subtle">
              Your conversations will appear here.
            </p>
          </div>
        <% else %>
          <.link
            :for={space <- @external_spaces}
            patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
            class={[
              "channel-row",
              @active_space && @active_space.id == space.id && "channel-row--active"
            ]}
          >
            <span :if={space.kind == "channel"} class="text-subtle">#</span>
            <span class="truncate flex-1">
              {if space.kind == "channel",
                do: ChatLive.masked_space_name(@mask_assigns, space.name),
                else: sidebar_display_name(space, @user_id)}
            </span>
            <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
              <span class="channel-row-unread-pill">
                {unread_label(Map.get(@unread_counts, space.id, 0))}
              </span>
            <% end %>
          </.link>
        <% end %>
      </nav>

      <%!-- External users MAY start DMs to allowlisted humans (the picker is
           filtered to exactly that set in stage 3), so this one affordance stays —
           it is NOT internal-discovery chrome. --%>
      <button
        type="button"
        phx-click="new_conversation_open"
        aria-label="New conversation"
        data-role="external-new-conversation"
        class="flex-shrink-0 flex items-center gap-2 w-full border-t border-edge px-3 py-2 text-sm text-base-content hover:text-primary hover:bg-base-300 transition-colors"
        style="padding-bottom: calc(0.5rem + env(safe-area-inset-bottom));"
      >
        <span class="hero-plus size-4"></span>
        <span>New conversation</span>
      </button>
    </aside>
    """
  end

  attr(:external?, :boolean, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:mobile_browser_open, :boolean, required: true)
  attr(:external_user, :any, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  attr(:drawer_query, :string, required: true)
  attr(:drawer_search_intent, :any, required: true)
  attr(:sidebar_sections, :list, default: [])
  attr(:mask_names?, :boolean, default: false)
  attr(:revealed_section_ids, :any, default: nil)

  @doc """
  External mobile channel switcher (task 019f9257-a83e).

  The internal `#mobile-channel-browser` is `!@external?`-gated because its
  sectioned org-tree browser, new-channel affordance and scope-pills are all
  internal-discovery chrome. External users get this FLAT parallel: the same
  `fixed inset-0 z-40 lg:hidden` shell + `drawer_search` + `DrawerSearchFocus`
  hook, but a single flat `@channels ++ @dm_conversations` list (the exact set
  `external_rail/1` renders), plus the app brand / identity / logout that the
  chrome-less `:external` layout (layouts.ex) has nowhere else to hang on
  mobile. Opened by the pills-strip search button (`toggle_mobile_browser`); on
  the no-space landing it is shown by default — the list IS the landing
  (iOS-Messages model, Saru direction). Semantic tokens only; safe-area
  utilities reused from the internal overlay.
  """
  def external_mobile_switcher(assigns) do
    assigns =
      assigns
      |> assign(:external_switcher_spaces, assigns.channels ++ assigns.dm_conversations)
      |> assign(:mask_assigns, Map.take(assigns, @mask_keys))
      |> assign_brand_name()

    ~H"""
    <%= if @external? and !@embedded and (@mobile_browser_open or is_nil(@active_space)) do %>
      <div
        id="external-mobile-switcher"
        data-role="external-mobile-switcher"
        class="fixed inset-0 z-40 flex flex-col bg-base-100 lg:hidden safe-area-x"
      >
        <header class="flex-shrink-0 border-b border-edge safe-area-top">
          <div class="flex h-12 items-center justify-between px-4">
            <div class="flex items-center gap-2 min-w-0" data-role="brand-chip">
              <img src={~p"/images/burrow-mark.svg"} alt={@brand_name} class="size-6 flex-shrink-0" />
              <span class="truncate text-sm font-semibold tracking-tight text-base-content">
                {@brand_name}
              </span>
            </div>
            <div class="flex items-center gap-1">
              <a
                href={~p"/auth/logout"}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Log out"
                data-role="external-logout"
              >
                <span class="hero-arrow-right-start-on-rectangle size-5"></span>
              </a>
              <%!-- No close control on the landing (is_nil(@active_space)) — the
                   switcher IS the screen there, nothing to reveal behind it. --%>
              <button
                :if={@active_space}
                phx-click="close_mobile_browser"
                class="flex items-center justify-center size-10 rounded-lg text-subtle hover:bg-base-300 hover:text-base-content"
                aria-label="Close"
              >
                <span class="hero-x-mark size-5"></span>
              </button>
            </div>
          </div>
          <div
            :if={@external_user}
            class="flex items-center gap-2 border-t border-edge px-4 py-2"
            data-role="external-identity"
          >
            <.human_avatar
              name={@external_user.name || @external_user.email || "You"}
              avatar_url={@external_user.avatar_url}
              seed={@external_user.oidc_sub || @external_user.email || @external_user.id}
              size="sm"
              class="flex-shrink-0"
            />
            <span class="truncate text-sm text-base-content">
              {@external_user.name || @external_user.email}
            </span>
          </div>
        </header>

        <%!-- Pinned search row — reuses the internal drawer's events + hook so
             iOS focus/zoom behaviour is identical (h-11 >=44px target, text-base
             blocks auto-zoom). Stable `drawer-search-input` id is shared with the
             internal overlay, which is `!@external?`-gated so only one is ever in
             the DOM. --%>
        <div class="flex-shrink-0 px-4 py-2 border-b border-edge" role="search">
          <form class="relative" phx-change="drawer_search" phx-submit="drawer_search">
            <span
              class="hero-magnifying-glass absolute left-3 top-1/2 -translate-y-1/2 size-4 text-subtle"
              aria-hidden="true"
            >
            </span>
            <input
              id="drawer-search-input"
              type="search"
              name="value"
              value={@drawer_query}
              phx-hook="DrawerSearchFocus"
              data-search-intent={to_string(@drawer_search_intent)}
              phx-debounce="150"
              placeholder="Find a conversation"
              autocomplete="off"
              autocorrect="off"
              autocapitalize="none"
              spellcheck="false"
              enterkeyhint="go"
              aria-label="Find a conversation"
              class="w-full h-11 rounded-lg bg-base-200 border border-base-content/10 pl-9 pr-11 text-base placeholder:text-subtle focus:border-primary focus:outline-none"
            />
            <button
              :if={@drawer_query != ""}
              type="button"
              phx-click="drawer_search_clear"
              class="absolute right-0 top-1/2 -translate-y-1/2 flex items-center justify-center min-h-11 min-w-11 text-subtle hover:text-base-content"
              aria-label="Clear search"
            >
              <span class="hero-x-mark size-4"></span>
            </button>
          </form>
        </div>

        <% external_switcher_filtered =
          drawer_filter_external_spaces(@external_switcher_spaces, @drawer_query, @user_id) %>
        <nav class="flex-1 overflow-y-auto py-2" aria-label="Your conversations">
          <%= if @external_switcher_spaces == [] do %>
            <%!-- Calm zero-allowlist empty state — mirrors the external rail's
                 `external-empty`. NEVER an internal "browse channels" hint. --%>
            <div
              class="flex h-full flex-col items-center justify-center gap-2 px-6 text-center"
              data-role="external-empty"
            >
              <span class="hero-chat-bubble-left-right size-8 text-subtle"></span>
              <p class="text-sm font-medium text-base-content">Nothing here yet</p>
              <p class="text-xs text-subtle">
                Your conversations will appear here.
              </p>
            </div>
          <% else %>
            <%= if external_switcher_filtered == [] do %>
              <p class="px-4 py-6 text-center text-sm text-subtle">No matches</p>
            <% else %>
              <.link
                :for={space <- external_switcher_filtered}
                patch={~p"/chat/#{ChatLive.space_nav_target(space)}"}
                class={[
                  "channel-row",
                  @active_space && @active_space.id == space.id && "channel-row--active"
                ]}
              >
                <span :if={space.kind == "channel"} class="text-subtle">#</span>
                <span class="truncate flex-1">
                  {if space.kind == "channel",
                    do: ChatLive.masked_space_name(@mask_assigns, space.name),
                    else: sidebar_display_name(space, @user_id)}
                </span>
                <%= if unread_label(Map.get(@unread_counts, space.id, 0)) do %>
                  <span class="channel-row-unread-pill">
                    {unread_label(Map.get(@unread_counts, space.id, 0))}
                  </span>
                <% end %>
              </.link>
            <% end %>
          <% end %>
        </nav>

        <%!-- DM picker foot — the ONE discovery affordance external users keep
             (filtered to allowlisted humans server-side). Closes the switcher as
             the create flow opens. `mobile-drawer-footer-safe` adds the
             home-indicator inset ON TOP of the normal padding. --%>
        <button
          type="button"
          phx-click={JS.push("new_conversation_open") |> JS.push("close_mobile_browser")}
          aria-label="New conversation"
          data-role="external-new-conversation"
          class="flex-shrink-0 flex items-center gap-2 w-full border-t border-edge px-4 pt-3 text-sm text-base-content hover:text-primary hover:bg-base-200 transition-colors mobile-drawer-footer-safe"
        >
          <span class="hero-plus size-5"></span>
          <span>New conversation</span>
        </button>
      </div>
    <% end %>
    """
  end

  # The install's app name (`Platform.Branding.app_name/0`, the branding row
  # an admin edits) for the brand chip's alt text and visible name, instead of
  # a compiled product name (task 01a116de stage 3). Read only on the
  # external branch: `Branding.get/0` is a DB read and internal renders never
  # show this chip.
  defp assign_brand_name(assigns) do
    if assigns[:external?] do
      assign(assigns, :brand_name, Platform.Branding.app_name())
    else
      assign(assigns, :brand_name, nil)
    end
  end
end
