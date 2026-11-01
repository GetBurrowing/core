defmodule PlatformWeb.Plugs.FirstRunGate do
  @moduledoc """
  Sends a first-run member's bare `GET /chat` to `/start`, the "What do you
  want to do?" box (task 01a19943-c0b4 stage 1).

  WHY. The installed PWA opens its manifest `start_url`, which is `/chat`,
  not `/`. `PlatformWeb.PageController.home/2` already sends a pending member
  from `/` to `/start`, but a member who only ever opens the installed app
  never requests `/`, so before this plug they never saw the box.

  WHEN IT REDIRECTS. Only when ALL of these hold, checked cheapest first so
  every other request returns before any database read:

    1. the method is `GET`;
    2. `conn.path_info == ["chat"]`: bare `/chat` (also `/chat/` and
       `/chat?x=`). Deep links `/chat/<slug>` are never gated: push
       notifications, shared links and the first-run hand-off itself land
       there;
    3. `PlatformWeb.ExternalSurface.router_surface/1` is `:app`, the same
       rule `PageController.home/2` uses. The `chat.` host scope does not
       pipe through this plug at all; this check covers a `meet.` host that
       falls through to the default scope while `:host_surface_enforcement`
       is `:off`;
    4. `Platform.Onboarding.FirstRunGoal.pending?/1` on `:current_user`. It
       is false for external users, so they are never redirected.

  The query string is dropped on redirect.

  NO LOOP. This is an HTTP plug: it never runs on a websocket reconnect or a
  `push_navigate` inside the `:authenticated` live_session. `/start` sends a
  non-pending member to `/chat`, and `pending?/1` reads the stored
  preferences, so once the member submits or skips the gate lets them through.

  Must run after `PlatformWeb.Plugs.RequireAuth` (it reads `:current_user`),
  so it is the LAST pipeline of the default app scope.
  """

  import Plug.Conn

  alias Platform.Onboarding.FirstRunGoal
  alias PlatformWeb.ExternalSurface

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "GET", path_info: ["chat"]} = conn, _opts) do
    if ExternalSurface.router_surface(conn) == :app and
         FirstRunGoal.pending?(conn.assigns[:current_user]) do
      conn
      |> Phoenix.Controller.redirect(to: "/start")
      |> halt()
    else
      conn
    end
  end

  def call(%Plug.Conn{} = conn, _opts), do: conn
end
