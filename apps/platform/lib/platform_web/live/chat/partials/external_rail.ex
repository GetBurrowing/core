defmodule PlatformWeb.ChatLive.Partials.ExternalRail do
  @moduledoc """
  The external-user chat chrome below lg: the mobile switcher.

  Same split as `ChatLive.Partials` (ADR 0035) — function components, no
  state, each taking a declared set of attrs. These two regions render ONLY
  on the `:external` layout, which is why they were the first slice of
  `chat_live.html.heex` to move: a mistake here cannot reach internal chat.

  Extracted here (task 01a0312e stage 2, markup unchanged):

    * `external_mobile_switcher/1` — the full-screen phone space switcher

  The desktop external rail (`external_rail/1`) was deleted in Burrow
  redesign 22 stage 2: at lg an external user gets the Chat list pane
  (`Partials.ChatList`), scoped to their own channels and conversations,
  with their identity and Log out at its foot.

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

  alias PlatformWeb.ChatLive

  @mask_keys [:sidebar_sections, :mask_names?, :revealed_section_ids]

  attr(:external?, :boolean, required: true)
  attr(:embedded, :boolean, required: true)
  attr(:external_user, :any, required: true)
  attr(:channels, :list, required: true)
  attr(:dm_conversations, :list, required: true)
  attr(:active_space, :any, required: true)
  attr(:unread_counts, :map, required: true)
  attr(:user_id, :any, required: true)
  attr(:drawer_query, :string, required: true)
  attr(:sidebar_sections, :list, default: [])
  attr(:mask_names?, :boolean, default: false)
  attr(:revealed_section_ids, :any, default: nil)

  @doc """
  External mobile channel switcher (task 019f9257-a83e).

  The internal phone Chat list (`ChatList.chat_list/1`) is `!@external?`-gated
  because its sectioned layout, new-channel affordance and options are
  internal-discovery chrome. External users get this FLAT parallel: a
  `fixed inset-0 z-40 lg:hidden` shell + `drawer_search` + `SearchFocus`
  hook, a single flat `@channels ++ @dm_conversations` list (the exact set
  `external_rail/1` renders), plus the app brand / identity / logout that the
  chrome-less `:external` layout (layouts.ex) has nowhere else to hang on
  mobile.

  It renders exactly when no space is open: the list IS the landing
  (iOS-Messages model, Saru direction). /chat clears the active space, and a
  space's back chevron patches to /chat, so that is how an external phone
  user returns here (task 01a1557a-8562 stage 5; the pills-strip search
  button that used to open it on top of a space was deleted with the drawer,
  and so was the close × that only that opening needed). Semantic tokens
  only.
  """
  def external_mobile_switcher(assigns) do
    assigns =
      assigns
      |> assign(:external_switcher_spaces, assigns.channels ++ assigns.dm_conversations)
      |> assign(:mask_assigns, Map.take(assigns, @mask_keys))
      |> assign_brand_name()

    ~H"""
    <%= if @external? and !@embedded and is_nil(@active_space) do %>
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
              phx-hook="SearchFocus"
              data-blur-on-scroll="external-switcher-list"
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
        <nav
          id="external-switcher-list"
          class="flex-1 overflow-y-auto py-2"
          aria-label="Your conversations"
        >
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
                class="channel-row"
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
             (filtered to allowlisted humans server-side). `footer-safe-bottom` adds
             the home-indicator inset ON TOP of the normal padding. --%>
        <button
          type="button"
          phx-click="new_conversation_open"
          aria-label="New conversation"
          data-role="external-new-conversation"
          class="flex-shrink-0 flex items-center gap-2 w-full border-t border-edge px-4 pt-3 text-sm text-base-content hover:text-primary hover:bg-base-200 transition-colors footer-safe-bottom"
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
