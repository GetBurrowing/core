defmodule PlatformWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PlatformWeb, :html

  # Imported so the embedded shell.html.heex can call `<.icon_rail .../>` and
  # `<.bottom_rail .../>` directly. The icon-rail replaces the inline desktop
  # sidebar links + the previous `<.bottom_nav>` component (task 019e389b).
  import PlatformWeb.Components.IconRail
  import PlatformWeb.Components.MoreSheet

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates("layouts/*")

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")

  attr(:current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"
  )

  slot(:inner_block, required: true)

  def app(assigns) do
    ~H"""
    <header class="navbar px-4 sm:px-6 lg:px-8">
      <div class="flex-1">
        <a href="/" class="flex-1 flex w-fit items-center gap-2">
          <img src={~p"/images/logo.svg"} width="36" />
          <span class="text-sm font-semibold">v{Application.spec(:phoenix, :vsn)}</span>
        </a>
      </div>
      <div class="flex-none">
        <ul class="flex flex-column px-1 space-x-4 items-center">
          <li>
            <a href="https://phoenixframework.org/" class="btn btn-ghost">Website</a>
          </li>
          <li>
            <a href="https://github.com/phoenixframework/phoenix" class="btn btn-ghost">GitHub</a>
          </li>
          <li>
            <.theme_toggle />
          </li>
          <li>
            <a href="https://hexdocs.pm/phoenix/overview.html" class="btn btn-primary">
              Get Started <span aria-hidden="true">&rarr;</span>
            </a>
          </li>
        </ul>
      </div>
    </header>

    <main class="px-4 py-20 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-2xl space-y-4">
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Root layout for the guest meeting ingress (task 019f2483 stage 3).

  Purpose-built stripped-down `<html>` document for the `meet.` host
  scope. Compared with `root.html.heex` this omits the theme-debug
  script, the PWA manifest hook, the `webmcp-enabled` meta, and the VAPID
  key — none of which are meaningful to an unauthenticated guest.

  We DO keep:

    * the viewport meta with `viewport-fit=cover` + safe-area handling
      (guests hit this from mobile share sheets constantly);
    * the CSRF meta so the name-entry form's `phx-submit` works;
    * the same `app.css` / `app.js` bundle so hero-icons and LiveView
      hooks (notably `MeetingClient`) load unchanged.

  There is intentionally no sidebar / icon-rail / bottom-nav / auth
  affordance in this document — it is a single-purpose ingress page,
  not the app shell.
  """
  def guest_root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta
          name="viewport"
          content="width=device-width, initial-scale=1, maximum-scale=1, viewport-fit=cover, interactive-widget=resizes-content"
        />
        <meta name="csrf-token" content={get_csrf_token()} />
        <.live_title default="Guest meeting" suffix=" · Suite">
          {assigns[:page_title]}
        </.live_title>
        <link rel="icon" type="image/x-icon" href="/favicon.ico" />
        <link rel="icon" type="image/png" sizes="32x32" href="/images/favicon-32.png" />
        <link rel="icon" type="image/png" sizes="16x16" href="/images/favicon-16.png" />
        <link rel="apple-touch-icon" sizes="180x180" href="/images/apple-touch-icon.png" />
        <meta name="theme-color" content="#000000" />
        <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
        <script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}>
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  @doc """
  Application layout for the guest meeting ingress (task 019f2483 stage 3).

  Null-ish outer wrapper — deliberately does NOT render `<.shell_layout>`,
  `<.icon_rail>`, `<.bottom_rail>`, or any auth-side chrome.

  ## Definite viewport height

  Uses `h-dvh` (definite `height: 100dvh`), NOT `min-h-dvh`. The previous
  `min-h-dvh` looked equivalent for the name-entry / expired card states
  (which just center their content in whatever space they get), but broke
  the in-meeting Gallery layout hard: MeetingLive's outer wrapper is
  `flex h-full flex-col` and the gallery cell CSS uses
  `container-type: size` with an `@container gallery-cell` query to size
  each 16:9 video tile against its cell's aspect ratio.

  `h-full` on a `min-height`-only ancestor is indeterminate — the CSS
  spec resolves it to `auto`, which cascades down the flex chain so
  `[data-gallery-cell]` has no definite size. `container-type: size`
  needs a definite size to establish a size query context; without one,
  none of the `@container` rules match, and the tile falls back to just
  `aspect-ratio: 16/9; max-width: 100%; max-height: 100%` — with no
  explicit width/height, the browser renders it at its intrinsic
  ~300×150 size, floating as a thumbnail regardless of how large the
  cell tracks are. That's the "shockingly small camera views" bug Rowan
  hit on prod on 2026-07-10 after the guest-consolidation deploy.

  The auth shell (`shell.html.heex`) uses `h-[100dvh]` for the same
  reason — definite viewport height so percentages propagate cleanly to
  every leaf that cares (gallery cells, canvas surfaces, screen-share
  fits). Guest surface needs to match.

  The name-entry / expired / invalid card states already center their
  content in a `flex items-center justify-center` block, so they were
  unaffected by the wrong height and are still unaffected by the fix.
  """
  def guest(assigns) do
    ~H"""
    <main class="h-dvh bg-base-100 text-base-content">
      {@inner_content}
    </main>

    <.flash_group flash={assigns[:flash] || %{}} />
    """
  end

  @doc """
  INERT external-chat app layout (rbac-external-users M4 scaffold, task
  019f8837).

  Ships DARK: this layout is only selected by the `:external_chat`
  live_session on the `chat.` host scope wired in the router, and no
  environment declares a `chat.` host until the M14 subdomain go-live. So
  in every currently-reachable environment this function is never rendered
  — it exists so M5 has a shell-less wrapper to mount the external ChatLive
  branch (filtered rails / DM picker) into, and so M6/M7 have a surface to
  attach scope enforcement to.

  Structurally identical to the guest-meeting `guest/1` layout above (which
  the `meet.` guest scope pairs with `chrome_mode: "none"`): a null-ish
  outer wrapper that deliberately does NOT render `<.shell_layout>`,
  `<.icon_rail>`, `<.bottom_rail>`, or any auth-side chrome — that chrome
  lives in `shell.html.heex`, and omitting the `:shell` layout is exactly
  what makes the external surface chrome-less.

  Uses `h-dvh` (definite `height: 100dvh`), NOT `min-h-dvh`, matching the
  guest layout's documented gallery-sizing fix (see `guest/1`): a definite
  viewport height so `h-full` percentages propagate cleanly to every leaf
  that establishes a size-query / flex context.

  ## Why no `:external_root` root layout (a divergence from `meet.`)

  The `meet.` guest scope added a stripped `guest_root/1` (see above) that
  drops the PWA manifest + VAPID push key, because unauthenticated meeting
  guests get no push. External chat users are authenticated real OIDC
  accounts and DO get PWA push (design canvas §10-8), so the `chat.` scope
  reuses the existing full `:root` document head unchanged — only the APP
  layout is swapped to `:external`. Hence this module adds exactly one
  function and no root layout.
  """
  def external(assigns) do
    ~H"""
    <main class="h-dvh bg-base-100 text-base-content">
      {@inner_content}
    </main>

    <.flash_group flash={assigns[:flash] || %{}} />
    """
  end

  @doc "Returns a Tailwind color class for the agent status indicator."
  def agent_status_color(:online), do: "bg-success"
  def agent_status_color(:thinking), do: "bg-sky-400"
  def agent_status_color(:offline), do: "bg-warning"
  def agent_status_color(:idle), do: "bg-warning"
  def agent_status_color(:paused), do: "bg-warning"
  def agent_status_color(:error), do: "bg-error"
  def agent_status_color(_), do: "bg-base-content/30"

  @doc "Returns a compact text label for the shell agent indicator."
  def agent_status_label(:online), do: "Agent"
  def agent_status_label(:thinking), do: "Agent"
  def agent_status_label(:offline), do: "Agent"
  def agent_status_label(:idle), do: "Agent"
  def agent_status_label(:paused), do: "Agent"
  def agent_status_label(:error), do: "Agent"
  def agent_status_label(_), do: "Agent"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr(:flash, :map, required: true, doc: "the map of flash messages")
  attr(:id, :string, default: "flash-group", doc: "the optional id of flash container")

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
