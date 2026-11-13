defmodule PlatformWeb.Components.GamingShell do
  @moduledoc "Console Glass navigation around published games; workspace flows remain intact."
  use PlatformWeb, :html
  import PlatformWeb.Components.InstallSwitch, only: [install_switch: 1, install_switch_menu: 1]

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
      assign_new(assigns, :install_name, fn ->
        assigns.brand_name || Platform.Branding.app_name()
      end)

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
    <% else %>
      {render_slot(@inner_block)}
    <% end %>
    """
  end

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
