defmodule PlatformWeb.ControlCenterLive do
  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Control Center")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full items-center justify-center">
      <div class="text-center">
        <p class="text-2xl font-semibold">⚙️ Control Center</p>
        <p class="mt-2 text-base-content/60">Agent management, vault, and system health.</p>
        <p class="mt-1 text-sm text-base-content/40">Coming soon — agent runtime in progress.</p>
      </div>
    </div>
    """
  end
end
