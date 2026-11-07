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

    * `:ensure_admin` — compatibility hook delegated to `ModuleGate`.

  Adding a new hook? Mirror the existing pattern: read assigns,
  never hit the DB, never reach into `socket.private`. The one exception is
  a vendor support user (`support_vendor: true`, ADR 0059), whose support
  session is re-read on every mount and event; no other user pays for it.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1, redirect: 2]

  alias Platform.Access.Scope
  alias Platform.Accounts.User
  alias Platform.SupportAccess
  alias Platform.Tenancy

  @doc """
  `on_mount/4` dispatcher — required shape for LiveView `on_mount`
  hooks. Pattern-matches on the hook atom from the `live_session`
  `on_mount:` list (e.g. `{PlatformWeb.LiveAuth, :default}`).
  """
  def on_mount(:default, _params, session, socket) do
    user = socket.assigns[:current_user_record] || socket.assigns[:current_user]

    case support_gate(user, session, socket) do
      {:cont, socket} -> assign_defaults(socket, user)
      {:halt, socket} -> {:halt, socket}
    end
  end

  def on_mount(:ensure_admin, params, session, socket),
    do: PlatformWeb.ModuleGate.on_mount(:default, params, session, socket)

  # Vendor support user (task 01a1b362 stage 1, ADR 0059). Signed out unless
  # its support session is active, checked on EVERY mount (dead and
  # connected), on every `handle_event`, and by a timer at `not_after`, so a
  # LiveView that stays connected cannot outlive the session. The sweeper
  # also broadcasts a disconnect on the session's live_socket_id when it ends
  # it. Each `handle_event` writes `support.action` (event name, view, params
  # hash; never values).
  defp support_gate(%User{support_vendor: true} = user, session, socket) do
    session_id = session["support_session_id"]

    if SupportAccess.session_allows?(user, session_id) do
      {:cont, attach_support_hooks(socket, user, session_id)}
    else
      {:halt, redirect(socket, to: "/auth/login")}
    end
  end

  defp support_gate(_user, _session, socket), do: {:cont, socket}

  defp attach_support_hooks(socket, user, session_id) do
    view = inspect(socket.view)

    if connected?(socket), do: schedule_support_check(session_id)

    socket
    |> attach_hook(:support_session_event, :handle_event, fn event, params, socket ->
      if SupportAccess.session_allows?(user, session_id) do
        SupportAccess.record_action(user, session_id, %{
          kind: "live_event",
          view: view,
          event: event,
          params: params
        })

        {:cont, socket}
      else
        {:halt, redirect(socket, to: "/auth/login")}
      end
    end)
    |> attach_hook(:support_session_check, :handle_info, fn
      :support_session_check, socket ->
        if SupportAccess.session_allows?(user, session_id) do
          schedule_support_check(session_id)
          {:halt, socket}
        else
          {:halt, redirect(socket, to: "/auth/login")}
        end

      _msg, socket ->
        {:cont, socket}
    end)
  end

  defp schedule_support_check(session_id) do
    ms =
      case SupportAccess.get_session(session_id) do
        %{not_after: not_after} ->
          DateTime.diff(not_after, DateTime.utc_now(), :millisecond) |> max(0) |> Kernel.+(500)

        _ ->
          0
      end

    Process.send_after(self(), :support_session_check, min(ms, 60_000))
  end

  defp assign_defaults(socket, user) do
    membership = load_membership_safely(user)
    root_admin? = root_admin_safely(user)

    {:cont,
     socket
     |> assign(:current_user_org_membership, membership)
     |> assign(:root_admin?, root_admin?)
     # RBAC v2 shadow scope (task 01a1386d-cb5c stage 2): built and assigned
     # only. Nothing reads it for a decision yet, and `:root_admin?` above is
     # unchanged. `for_user/1` fails closed for nil and the legacy string shape.
     |> assign(:access_scope, Scope.for_user(user))}
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
