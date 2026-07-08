defmodule PlatformWeb.RouteResume do
  @moduledoc """
  Server-side helper for the RouteResume JS hook (task 019f3e9a stage 2).

  Imported into every `use PlatformWeb, :live_view` via `platform_web.ex` so
  any LiveView can signal that a URL its socket is currently rendering has
  become stale (e.g. a task detail LV loads a `nil` task from the DB after
  a delete, a chat-space LV can't resolve its slug). The JS hook listens on
  `window` for `phx:route_resume_stale`, extracts the `module` string from
  `event.detail`, and calls `ClientState.remove("route_resume", module)` so
  a subsequent top-nav click falls back to the module root instead of
  re-routing into the missing URL.

  Only one function on the surface today; kept in its own module so future
  route-resume-related helpers (bulk clear, targeted patch, tests helpers)
  have a home without polluting `PlatformWeb`.
  """

  import Phoenix.LiveView, only: [push_event: 3]

  @doc """
  Push a `route_resume_stale` event to the connected client. Idempotent for
  disconnected mounts — Phoenix.LiveView's `push_event/3` no-ops when the
  socket is not yet connected, which matches our contract (nothing to
  clear on the client until it exists).

  `module_id` is the per-module namespace used by the RouteResume hook
  (`"chat"`, `"tasks"`, `"meetings"`, …). String rather than atom because
  the wire format is JSON — reserving the string surface keeps callers
  from accidentally depending on atom identity.
  """
  @spec handle_route_stale(Phoenix.LiveView.Socket.t(), binary()) ::
          Phoenix.LiveView.Socket.t()
  def handle_route_stale(socket, module_id) when is_binary(module_id) do
    push_event(socket, "route_resume_stale", %{module: module_id})
  end
end
