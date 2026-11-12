defmodule PlatformWeb.SwitcherConnectedLive do
  @moduledoc """
  `/switcher/connected` on install A (task 01a1ccd4 stage 3): where install
  B's consent hop (stage 2) returns the browser, with
  `#key=...&name=...&host=...` in the FRAGMENT (no `key` after Cancel).

  The server never sees the fragment and renders only a working card. The
  `SwitcherConnected` hook (`assets/js/hooks/switcher_connected.js`) reads
  it, checks it against the hop this browser started, saves the install to
  `burrow.installs.v1`, strips the fragment with `history.replaceState` and
  returns to the page the person started from. A link nobody's switcher
  started shows "This link doesn't work".

  No module gates it (see `PlatformWeb.ModuleGate`): it reads and writes
  nothing on the server, only this browser's own list.
  """
  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Adding an install")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-full items-center justify-center bg-base-100 px-4 py-12">
      <div
        id="switcher-connected"
        phx-hook="SwitcherConnected"
        phx-update="ignore"
        data-state="working"
        class="w-full max-w-sm rounded-2xl border border-edge bg-base-100 p-6 shadow-sm"
      >
        <div data-role="connected-working" class="flex items-center gap-3">
          <span
            class="inline-block size-5 animate-spin rounded-full border-2 border-primary border-t-transparent"
            aria-hidden="true"
          >
          </span>
          <p class="text-sm font-medium text-base-content">Adding the install</p>
        </div>
        <div data-role="connected-invalid" class="hidden">
          <h1 class="text-base font-semibold text-base-content">This link doesn't work</h1>
          <p class="mt-2 text-sm text-subtle">
            Start again from Add an install in the switcher.
          </p>
          <.link
            navigate={~p"/"}
            class="mt-4 inline-flex rounded-lg border border-edge px-4 py-2 text-sm font-medium text-base-content focus-visible-ring"
          >
            Back to {Platform.Branding.app_name()}
          </.link>
        </div>
      </div>
    </div>
    """
  end
end
