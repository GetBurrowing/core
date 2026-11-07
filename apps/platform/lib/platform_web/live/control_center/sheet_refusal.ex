defmodule PlatformWeb.ControlCenter.SheetRefusal do
  @moduledoc """
  The refusal shown inside an open sheet or modal (task 01a1ae4b stage 2).

  The sheets on the Control Center page are full-screen overlays, so a page
  flash raised while one is open lands behind it, where nobody can read it.
  `ControlCenterLive.refuse/2` therefore puts a policy refusal in the
  `:sheet_refusal` assign while a sheet is open, and each sheet renders it at
  the top of its body with this component. The grant panel's in-panel error
  (`GrantEvents`, `%{panel | error: ...}`) is the precedent.

  The alert takes focus when it appears. The refused submit is usually at
  the bottom of a sheet that scrolls (the External Agent form is taller than
  a phone screen), so without this the alert would render above the fold,
  as unseen as the flash it replaces.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr(:message, :string, default: nil)

  def alert(assigns) do
    ~H"""
    <div
      :if={@message}
      id="sheet-refusal"
      role="alert"
      data-role="sheet-refusal"
      tabindex="-1"
      phx-mounted={JS.focus()}
      class="alert alert-error mb-4 text-sm focus:outline-none"
    >
      <span class="hero-exclamation-circle size-5 shrink-0" aria-hidden="true" />
      <span>{@message}</span>
    </div>
    """
  end
end
