defmodule PlatformWeb.AdminLive do
  @moduledoc """
  Admin landing surface — Fabrikam-only.

  Routed from the icon-rail's Admin tile. Surfaces section headers + links
  to the existing Fabrikam-only admin sub-surfaces (Agent Resources, Agent
  Federation, Usage/Cost Metering, Prompts) so power users can reach any of
  them without typing URLs.

  Lightweight first-pass per Marlowe 2026-05-17 — fill out per sub-surface as
  they get scoped. The Fabrikam-only gate is inherited from the `:admin`
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
     |> assign(:sign_in_admin?, Platform.SignInAdmin.Config.enabled?())}
  end
end
