defmodule PlatformWeb.UserAccessLive do
  @moduledoc """
  User Access — admin surface for managing user permissions, roles, and
  membership across orgs.

  Stub placeholder per Marlowe 2026-05-20. Real implementation lands in a
  follow-up task once the user-management UX is scoped. Fabrikam-only gate is
  inherited from the `:admin` live_session.
  """
  use PlatformWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "User Access")}
  end
end
