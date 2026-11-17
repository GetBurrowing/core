defmodule PlatformWeb.GameStudioLive do
  use PlatformWeb, :live_view
  alias Platform.Gaming.{NewGame, Studio}
  alias Phoenix.LiveView.JS
  import PlatformWeb.Components.InstallSwitch, only: [install_switch: 1]

  @impl true
  def mount(_params, _session, socket) do
    if Platform.Gaming.enabled?() do
      {:ok,
       assign(socket,
         page_title: "Studio",
         entries: [],
         entry: nil,
         tasks: [],
         canvases: [],
         tab: "studio",
         playtest_notice: nil,
         playtesting: false,
         new_game: false,
         new_game_form: to_form(%{}, as: :game),
         game_orgs: NewGame.organizations(socket.assigns.current_user_record)
       )}
    else
      {:ok, redirect(socket, to: "/chat")}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    entries = Studio.list(socket.assigns.current_user_record)
    entry = Enum.find(entries, &(&1.project.id == params["project"])) || List.first(entries)

    if connected?(socket) and
         (socket.assigns.entry && socket.assigns.entry.project.id) != (entry && entry.project.id) do
      if socket.assigns.entry,
        do: Platform.Tasks.unsubscribe_board(project: socket.assigns.entry.project.id)

      if entry, do: Platform.Tasks.subscribe_board(project: entry.project.id)
    end

    tab = Atom.to_string(socket.assigns.live_action)

    {:noreply,
     assign(socket,
       entries: entries,
       entry: entry,
       tab: tab,
       studio_tools: PlatformWeb.Components.IconRail.gaming_more_sheet_rows(socket.assigns.access_scope, false),
       new_game: params["new"] == "1" or entries == [],
       gaming_nav_project_id: entry && entry.project.id,
       playtest_notice: Studio.playtest_notice(entry, socket.assigns.current_user_record),
       tasks: Studio.tasks(entry, socket.assigns.access_scope),
       canvases: Studio.canvases(entry, socket.assigns.access_scope)
     )}
  end

  @impl true
  def handle_event("create_game", %{"game" => params}, socket) do
    case NewGame.create(socket.assigns.current_user_record, params) do
      {:ok, project, state} ->
        socket =
          case state do
            :message_failed ->
              put_flash(
                socket,
                :error,
                "Project and room created. Send your setup brief in the team chat to continue."
              )

            :awaiting_agent ->
              put_flash(
                socket,
                :info,
                "Your project and room are ready, and the brief is saved. Open chat to invite an agent when you’re ready to build."
              )

            _ ->
              socket
          end

        {:noreply, push_patch(socket, to: "/studio?project=" <> project.id)}

      _ ->
        {:noreply,
         socket
         |> assign(:new_game_form, to_form(params, as: :game))
         |> put_flash(
           :error,
           "Could not start the game. Check your project and team-room permissions, then try again."
         )}
    end
  end

  def handle_event("playtest", _params, socket) do
    # All work runs outside the LiveView process; authorization is checked again
    # by the provider immediately before starting a host.
    entry = socket.assigns.entry
    user = socket.assigns.current_user_record

    {:noreply,
     start_async(assign(socket, :playtesting, true), :playtest, fn ->
       Studio.playtest(entry, user)
     end)}
  end

  @impl true
  def handle_async(:playtest, {:ok, {:ok, path}}, socket),
    do: {:noreply, push_navigate(assign(socket, :playtesting, false), to: path)}

  def handle_async(:playtest, _result, socket),
    do:
      {:noreply,
       put_flash(
         assign(socket, :playtesting, false),
         :error,
         "Playtest could not start. Check the project repository and available Play host, then try again."
       )}

  def on_access_changed(socket) do
    entries = Studio.list(socket.assigns.current_user_record)

    entry =
      (socket.assigns.entry &&
         Enum.find(entries, &(&1.project.id == socket.assigns.entry.project.id))) ||
        List.first(entries)

    socket
    |> assign(
      entries: entries,
      studio_tools: PlatformWeb.Components.IconRail.gaming_more_sheet_rows(socket.assigns.access_scope, false),
      entry: entry,
      gaming_nav_project_id: entry && entry.project.id,
      new_game: is_nil(entry),
      game_orgs: NewGame.organizations(socket.assigns.current_user_record),
      playtest_notice: Studio.playtest_notice(entry, socket.assigns.current_user_record),
      tasks: Studio.tasks(entry, socket.assigns.access_scope),
      canvases: Studio.canvases(entry, socket.assigns.access_scope)
    )
  end

  @impl true
  def handle_info({_event, _payload}, socket) do
    entry =
      socket.assigns.entry &&
        Enum.find(
          Studio.list(socket.assigns.current_user_record),
          &(&1.project.id == socket.assigns.entry.project.id)
        )

    {:noreply,
     assign(socket,
       entry: entry,
       tasks: Studio.tasks(entry, socket.assigns.access_scope),
       canvases: Studio.canvases(entry, socket.assigns.access_scope)
     )}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def studio_path(entry, tab \\ "studio") do
    if(tab == "studio", do: "/studio", else: "/studio/" <> tab) <>
      "?" <> URI.encode_query(%{"project" => entry.project.id})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} embedded>
      <div id="game-studio" class="game-studio" data-studio-tab={@tab}>
        <aside class="studio-projects" aria-label="Game projects">
          <.install_switch
            id="studio-install-switch"
            variant={:sidebar}
            brand_name={Platform.Branding.app_name()}
          />
          <p class="studio-eyebrow">YOUR STUDIO</p>
          <h1>Make something fun.</h1>
          <.link
            :for={entry <- @entries}
            patch={studio_path(entry)}
            class={["studio-project", @entry && @entry.project.id == entry.project.id && "is-current"]}
          >
            <img
              :if={entry.game && entry.game["image_path"]}
              src={entry.game["image_path"]}
              alt=""
              class="studio-game-cover"
            />
            <.icon :if={!entry.game || !entry.game["image_path"]} name="hero-cube" class="size-5" />
            <span>
              {entry.project.name}<small>{if entry.space, do: "Team + agents", else: "Project workspace"}</small>
            </span>
          </.link>
          <.link id="studio-start-game" navigate="/studio?new=1" class="studio-new">
            <.icon name="hero-plus" class="size-4" />Start a game
          </.link>
          <.link navigate="/chat" class="studio-new">All conversations</.link>
          <.link :for={dest <- Enum.filter(@studio_tools, &(&1.key in [:tasks, :agents]))} navigate={dest.path} class="studio-new">{dest.label}</.link>
          <details class="studio-more">
            <summary>More tools</summary>
            <.link :for={dest <- Enum.reject(@studio_tools, &(&1.key in [:tasks, :agents]))} navigate={dest.path}>{dest.label}</.link>
          </details>
          <.link navigate="/settings" class="studio-new">Settings</.link>
          <a href="/play?mode=discover" class="studio-new">
            <.icon name="hero-squares-2x2" class="size-4" />Discover games
          </a>
        </aside>
        <section :if={@new_game} class="studio-empty">
          <p class="studio-eyebrow">START A GAME</p>
          <h2>What are we making?</h2>
          <p>
            Pick an engine and give your agent an idea. Your project and team room open immediately; the repository and first build follow in the conversation.
          </p>
          <.form
            for={@new_game_form}
            id="studio-new-game"
            phx-submit="create_game"
            class="w-full text-left"
          >
            <.input field={@new_game_form[:name]} label="Game name" required maxlength="80" />
            <.input
              field={@new_game_form[:engine]}
              type="select"
              label="Starting point"
              options={NewGame.templates()}
            />
            <.input
              field={@new_game_form[:org_id]}
              type="select"
              label="Team"
              options={Enum.map(@game_orgs, &{&1.name, &1.id})}
            />
            <.input
              field={@new_game_form[:idea]}
              type="textarea"
              label="Your idea"
              maxlength="2000"
              placeholder="A tiny co-op game about…"
            />
            <button
              type="submit"
              disabled={@game_orgs == []}
              phx-disable-with="Starting…"
              class="studio-button"
            >
              Start my game
            </button>
          </.form>
          <p :if={@game_orgs == []}>
            You need permission to create projects and team rooms to start a game.
          </p>
        </section>
        <section :if={@entry && !@new_game} class="studio-workspace">
          <header class="studio-heading">
            <img
              :if={@entry.game && @entry.game["image_path"]}
              src={@entry.game["image_path"]}
              alt=""
              class="studio-hero-art"
            />
            <div class="studio-heading-copy">
              <p class="studio-eyebrow">
                {@entry.project.tech_stack["engine"] || "GAME STUDIO"} · {@entry.project.default_branch}
              </p>
              <h2>{@entry.project.name}</h2>
              <p>Build, talk, play. Together.</p>
            </div>
            <div class="studio-actions">
              <button
                :if={@entry.space}
                id="studio-playtest"
                disabled={@playtesting || not is_nil(@playtest_notice)}
                phx-click="playtest"
                phx-disable-with="Starting…"
                class="studio-button"
              >
                <.icon name="hero-play" class="size-4" />Playtest now
              </button>
              <a :if={@entry.game} href={"/games/#{@entry.game["slug"]}"} class="studio-button">
                Open build
              </a>
              <.link
                :if={@entry.space}
                patch={studio_path(@entry, "chat")}
                phx-click={JS.focus(to: "#studio-chat-#{@entry.space.id} [contenteditable=true]")}
                class="studio-button"
              >
                Ask an agent
              </.link>
            </div>
          </header>
          <div class="studio-columns">
            <section class="studio-conversation" aria-label="Project conversation">
              <header>
                <h3>{if @entry.space, do: "#" <> @entry.space.name, else: "Team conversation"}</h3>
                <.link :if={@entry.space} navigate={"/chat/#{@entry.space.slug}"}>Open chat</.link>
              </header>
              <%= if @entry.space do %>
                {live_render(@socket, PlatformWeb.ChatLive.Embedded,
                  id: "studio-chat-#{@entry.space.id}",
                  session: %{
                    "chat_space_slug" => @entry.space.slug,
                    "chat_embed_context" => "studio",
                    "current_user_id" => @current_user_record.id
                  }
                )}
              <% else %>
                <div class="studio-empty">
                  <.icon name="hero-chat-bubble-left-right" class="size-8" />
                  <h3>Connect your team room.</h3>
                  <p>This project has no accessible development room yet.</p>
                  <.link navigate={"/files/#{@entry.project.id}"} class="studio-button">
                    Open project files
                  </.link>
                </div>
              <% end %>
            </section>
            <aside class="studio-work" aria-label="Project work">
              <section class="studio-card">
                <h3>Build & playtest</h3>
                <p :if={@playtest_notice} role="status">{@playtest_notice}</p>
                <p>
                  {if @entry.game,
                    do: "Published build: " <> @entry.game["current_version"],
                    else: "Your first published build will appear here."}
                </p>
                <p class="studio-muted">
                  Playtest builds the project’s default branch. Review builds stay attached to their tasks.
                </p>
                <button
                  :if={@entry.space}
                  disabled={@playtesting || not is_nil(@playtest_notice)}
                  phx-click="playtest"
                  class="studio-button"
                >
                  Launch project playtest
                </button>
              </section>
              <section class="studio-card">
                <h3>Open tasks</h3>
                <p :if={@tasks == []} class="studio-muted">No tasks to show.</p>
                <.link :for={task <- @tasks} navigate={"/tasks/#{task.id}"} class="studio-row">
                  <span>{task.title}</span><small>{String.replace(task.status, "_", " ")}</small>
                </.link>
                <.link navigate="/tasks">Task board →</.link>
              </section>
              <section class="studio-card">
                <h3>Recent canvases</h3>
                <p :if={@canvases == []} class="studio-muted">
                  Playtests, clips and designs shared with your team appear here.
                </p>
                <.link
                  :for={canvas <- @canvases}
                  navigate={"/canvases/#{canvas.id}"}
                  class="studio-row"
                >
                  {canvas.title}
                </.link>
              </section>
            </aside>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
