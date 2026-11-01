defmodule PlatformWeb.PageController do
  use PlatformWeb, :controller

  @doc """
  ROOT LANDING for the app host and the chat host.

  A first-run member (`Platform.Onboarding.FirstRunGoal.pending?/1` on the
  user `PlatformWeb.Plugs.RequireAuth` assigns as `:current_user`) on the APP
  host goes to `/start`, the "What do you want to do?" box (task
  01a19554-fd07 stage 3). Everyone else goes to `/chat`, as before.

  Only on the app host: `/start` lives in the default scope, which the
  host fence (`PlatformWeb.Plugs.HostSurface`) closes to the `chat.` host,
  so the chat host's root keeps sending everyone to `/chat`.

  The bound, stated rather than hidden: a pending member who opens `/chat`
  directly (the PWA `start_url`, a bookmark) gets the normal chat, and
  gets the box at their next `/`. ChatLive is deliberately not gated.
  """
  def home(conn, _params) do
    if PlatformWeb.ExternalSurface.router_surface(conn) == :app and
         Platform.Onboarding.FirstRunGoal.pending?(conn.assigns[:current_user]) do
      redirect(conn, to: ~p"/start")
    else
      redirect(conn, to: ~p"/chat")
    end
  end

  @doc """
  ROOT LANDING for the `meet.` host (task 019ffe8a stage 2).

  A SECOND root action rather than a reworked `home/2`, and the rejected
  alternatives are the reason:

    * Reusing `home/2` is impossible. It is hardcoded
      `redirect(to: ~p"/chat")` — which is exactly why the `chat.` host
      could reuse it unchanged — and on the meet host it would land a
      member on a surface `ExternalUserScope` then bounces.
    * Host-aware dispatch INSIDE `home/2` was rejected: it duplicates in a
      controller the dispatch the router already performs structurally via
      `host:`, and it puts the app-host and chat-host roots at risk from
      every future meet change.

  Two small named actions, one per surface, keep each root's blast radius
  to itself. Paired with the `{:meet, []} -> conn` admission clause in
  `PlatformWeb.Plugs.ExternalUserScope`: without that clause the plug
  denies the root before this action is ever reached.
  """
  def meet_home(conn, _params) do
    redirect(conn, to: ~p"/meetings")
  end

  @doc """
  301 Moved Permanently redirect from the retired `/org-context` surface
  to `/org_memory` (T7 stage 2, task 019e41da-3610-7972-8573-54121ea1f3f5).
  Preserves the optional `:file_key` path segment so deep links keep
  working.
  """
  def org_context_redirect(conn, %{"file_key" => file_key}) do
    # Glob route — `file_key` arrives as a list of path segments.
    file_key = if is_list(file_key), do: Enum.join(file_key, "/"), else: file_key

    conn
    |> put_status(:moved_permanently)
    |> redirect(to: "/org_memory/#{file_key}")
  end

  def org_context_redirect(conn, _params) do
    conn
    |> put_status(:moved_permanently)
    |> redirect(to: ~p"/org_memory")
  end
end
