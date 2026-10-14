defmodule PlatformWeb.LiveAuth do
  @moduledoc """
  LiveView `on_mount` hooks that surface MT/RBAC assigns to every
  authenticated surface (Plan 2 v3, stack member 2 — task
  019e3c4a-0307-7955-8b35-1e0acea88cf0).

  ## Hooks

    * `:default` — installed on every authenticated `live_session`. Reads
      `:current_user` (already assigned by the `ShellLive` mount) and
      pure-functionally derives `:current_user_org_membership` and
      `:root_admin?`. **No DB call**: relies on
      `Platform.Accounts.get_user/1` preloading `:org_memberships` so
      this hook is a free assign-shuffle. Falls back to `nil` /
      `false` for anonymous mounts (LV mounts that somehow reach here
      without an authenticated session).

    * `:ensure_admin` — gate for the `/admin/*` surfaces. Halts and
      redirects to `/` with a flash error when the user is not a root-org
      admin.

  Adding a new hook? Mirror the existing pattern: read assigns,
  never hit the DB, never reach into `socket.private`.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Platform.Tenancy

  @doc """
  `on_mount/4` dispatcher — required shape for LiveView `on_mount`
  hooks. Pattern-matches on the hook atom from the `live_session`
  `on_mount:` list (e.g. `{PlatformWeb.LiveAuth, :default}`).
  """
  def on_mount(:default, _params, _session, socket) do
    user = socket.assigns[:current_user_record] || socket.assigns[:current_user]
    membership = load_membership_safely(user)
    root_admin? = root_admin_safely(user)

    {:cont,
     socket
     |> assign(:current_user_org_membership, membership)
     |> assign(:root_admin?, root_admin?)}
  end

  def on_mount(:ensure_admin, _params, _session, socket) do
    if socket.assigns[:root_admin?] do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, "You don't have access to that page.")
       |> push_navigate(to: "/")}
    end
  end

  # ShellLive assigns the user struct under `:current_user_record`
  # (the display name lives under `:current_user`). When this hook
  # runs we tolerate the legacy shape (string in `:current_user`) by
  # returning nil/false rather than crashing.
  defp load_membership_safely(%_{} = user), do: Tenancy.load_membership(user)
  defp load_membership_safely(_), do: nil

  defp root_admin_safely(%_{} = user), do: Tenancy.root_admin_preloaded?(user)
  defp root_admin_safely(_), do: false
end
