defmodule PlatformWeb.Components.GamingShell do
  @moduledoc "Console Glass navigation around published games; workspace flows remain intact."
  use PlatformWeb, :html
  import PlatformWeb.Components.InstallSwitch, only: [install_switch: 1, install_switch_menu: 1]
  import PlatformWeb.Components.IconRail, only: [bottom_rail: 1]

  alias PlatformWeb.Components.IconRail

  attr :enabled, :boolean, default: true
  attr :mode, :string, default: "play"
  attr :games, :list, default: []
  attr :user, :any, default: nil
  attr :creator, :boolean, default: false
  attr :details, :boolean, default: false
  attr :communities, :map, default: %{}
  attr :brand_name, :string, default: nil, doc: "this install's name; defaults to the branding"
  slot :inner_block, required: true

  def shell(assigns) do
    assigns =
      assigns
      |> assign_new(:install_name, fn -> assigns.brand_name || Platform.Branding.app_name() end)
      |> assign_workspace_nav()

    ~H"""
    <%= if @enabled do %>
      <div class={["cg-app", @details && "cg-with-details"]} id="console-glass-shell">
        <aside
          class="cg-side cg-glass"
          aria-label="Burrow Play navigation"
          data-install-switch-bar
        >
          <%!-- The brand opens the install switcher (the same component and
               hook as the workspace shell). It renders hidden and the hook
               reveals it; until then, or where nothing reveals it (an app
               build without the switcher bridge), the plain /play link that
               follows it shows instead (console_glass.css). Its dropdown
               container sits outside .cg-app, below. --%>
          <.install_switch
            id="gaming-install-switch"
            variant={:play}
            brand_name={@install_name}
            menu={false}
          />
          <a class="cg-brand cg-brand-fallback" href="/play">
            <img src="/images/burrow-mark.svg" alt="Burrow" /><span>PLAY</span>
          </a>
          <.modes mode={@mode} />
          <a
            :if={@creator}
            id="gaming-publish-mobile"
            class="cg-mobile-publish"
            href="/admin/games"
            aria-label="Publish a build"
          >
            <.icon name="hero-arrow-up-tray" />
          </a>
          <nav class="cg-subnav" aria-label="Game navigation">
            <a href="/play"><.icon name="hero-home" />Tonight</a>
            <a href="/play?mode=discover">
              <.icon name="hero-squares-2x2" />All games<span class="cg-count">{length(@games)}</span>
            </a>
            <a href="/play#rooms"><.icon name="hero-chat-bubble-left-right" />Player rooms</a>
          </nav>
          <div class="cg-side-label">YOUR GAME SPACES</div>
          <nav class="cg-rooms" aria-label="Player communities">
            <a :for={game <- @games} href={"/games/#{game["slug"]}?tab=community"}>
              <img :if={game["image_path"]} src={game["image_path"]} alt="" />
              <span>
                {game["title"]}<small>{if game["placeholder"] == true, do: "Placeholder game", else: "Players’ room"}</small>
              </span>
            </a>
            <p :if={@games == []} class="cg-muted">Your next crew starts here.</p>
          </nav>
          <div class="cg-side-footer">
            <a :if={@creator} id="gaming-create" href="/admin/games">
              <.icon name="hero-arrow-up-tray" />Publish a build
            </a>
            <a :if={@user} id="gaming-persona" href="/settings">
              <span class="cg-avatar"><.icon name="hero-user" /></span>{Platform.Games.player_display_name(
                @user
              )}
            </a>
            <a
              :if={!@user && @games != []}
              href={"/games/#{hd(@games)["slug"]}/sign-in"}
              class="cg-button cg-primary"
            >
              Sign in with Burrow
            </a>
          </div>
        </aside>
        <div class="cg-content">{render_slot(@inner_block)}</div>
        <aside :if={@details} class="cg-details cg-glass" aria-label="Your crew">
          <h2>Your crew starts here.</h2>
          <p>Pick a game, find its players, make a night of it.</p>
          <a
            :for={game <- @games}
            class="cg-detail-room"
            href={"/games/#{game["slug"]}?tab=community"}
          >
            <img :if={game["image_path"]} src={game["image_path"]} alt="" />
            <span>
              <b>{game["title"]}</b><small>{if @communities[game["slug"]], do: member_label(@communities[game["slug"]].member_count), else: "Open player room"}</small>
            </span>
            <.icon name="hero-arrow-up-right" />
          </a>
          <div class="cg-detail-note">
            <.icon name="hero-microphone" />
            <h3>Stay in the conversation.</h3>
            <p>
              Keep your Burrow call open while you play. Plan the next session in your game’s room.
            </p>
          </div>
        </aside>
      </div>
      <.install_switch_menu id="gaming-install-switch" />
      <%!-- The workspace's phone tab bar (Chat, Calendar, Meetings, Inbox,
           More): the same component the workspace shell renders, so its
           items follow it. Signed-in only, filtered by the viewer's Scope.
           Outside .cg-app and .cg-side: .cg-side's backdrop-filter would
           trap the fixed bar. Phone widths only on these pages
           (console_glass.css); .cg-app pads its end to clear it. These are
           dead views, so More is a link that opens the More sheet in the
           workspace, and app.js mounts the bar's hooks by hand. --%>
      <.bottom_rail
        :if={@workspace_nav}
        current_path="/play"
        access_scope={@workspace_nav.scope}
        more_href={@workspace_nav.more_href}
      />
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end

  # The phone tab bar for a signed-in viewer whose Scope admits at least one
  # of its link tabs; nil otherwise (a signed-out player sees no workspace
  # nav). More opens the sheet on the first tab's workspace page.
  defp assign_workspace_nav(%{enabled: true, user: %{id: _} = user} = assigns) do
    scope = Platform.Access.Scope.for_user(user)

    nav =
      case IconRail.tab_destinations(scope) do
        [first | _] -> %{scope: scope, more_href: first.path <> "?more=1"}
        [] -> nil
      end

    assign(assigns, :workspace_nav, nav)
  end

  defp assign_workspace_nav(assigns), do: assign(assigns, :workspace_nav, nil)

  @doc "A room card's member line: an invitation while empty, else the count."
  def member_label(0), do: "Be the first in"
  def member_label(count), do: member_count(count)

  @doc "A pluralised member count: `1 member`, `2 members`."
  def member_count(1), do: "1 member"
  def member_count(count), do: "#{count} members"

  attr :mode, :string, default: "create"

  def modes(assigns) do
    ~H"""
    <nav class="cg-modes" aria-label="Play, create or discover">
      <a href="/play" aria-current={if @mode == "play", do: "page"}><.icon name="hero-play" />Play</a>
      <a href="/play?mode=create" aria-current={if @mode == "create", do: "page"}>
        <.icon name="hero-wrench-screwdriver" />Create
      </a>
      <a href="/play?mode=discover" aria-current={if @mode == "discover", do: "page"}>
        <.icon name="hero-sparkles" />Discover
      </a>
    </nav>
    """
  end
end
