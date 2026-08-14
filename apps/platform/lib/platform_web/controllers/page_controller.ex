defmodule PlatformWeb.PageController do
  use PlatformWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
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
