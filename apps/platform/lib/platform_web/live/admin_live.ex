defmodule PlatformWeb.AdminLive do
  @moduledoc """
  Admin landing surface — root-admin-only.

  Routed from the icon-rail's Admin tile. Surfaces section headers + links
  to the existing root-admin-only admin sub-surfaces (Agent Resources, Agent
  Federation, Usage/Cost Metering, Prompts) so power users can reach any of
  them without typing URLs.

  Lightweight first-pass per design review 2026-05-17 — fill out per sub-surface as
  they get scoped. The root-admin-only gate is inherited from the `:admin`
  live_session's `PlatformWeb.LiveAuth.ensure_admin` hook.
  """
  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Task 01a113ea stage 3: the sign-in users tile exists only while the
    # page does (`Platform.SignInAdmin.Config.enabled?/0`); with the switch
    # off, `/admin` names neither the route nor pocket-id.
    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:sign_in_admin?, Platform.SignInAdmin.Config.enabled?())
     # Task 01a10315 stage 5: "Connect your AI" until the Setup agent is
     # connected, for root admins (the only ones who can open it).
     |> assign(
       :connect_ai?,
       Platform.Tenancy.root_admin?(socket.assigns[:current_user_record]) and
         not Platform.Agents.SetupAgent.connected?()
     )}
  end

  # Burrow redesign 24 stage 4: the index subscribes to nothing, but a stray
  # message (a shell broadcast, a late reply) must not crash the page.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}
end
