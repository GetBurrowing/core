defmodule PlatformWeb.InboxLive do
  @moduledoc """
  Placeholder Inbox surface (the "My Notifications" landing page).

  Today this just renders a friendly "Coming soon" state so the icon-rail
  Inbox tile lands somewhere instead of 404'ing. The real surface ships
  via the My Notifications stack (`019e389b-53b9-7281-a5a0-f70baae0775c`),
  which aggregates decisions awaiting the user across Tasks / Chat /
  Skills / etc.
  """

  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:current_path, "/inbox")
     |> assign(:page_title, "Inbox")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex min-h-[60vh] flex-col items-center justify-center px-6 text-center">
      <.icon name="hero-inbox" class="size-12 text-base-content/40" />
      <h1 class="mt-4 text-2xl font-semibold text-base-content">Inbox — coming soon</h1>
      <p class="mt-2 max-w-md text-base-content/60">
        This is where the things waiting on you across Suite will live —
        tasks with plans needing review, channel mentions, override
        requests. It's not built yet; check back as the redesign rolls out.
      </p>
    </div>
    """
  end
end
