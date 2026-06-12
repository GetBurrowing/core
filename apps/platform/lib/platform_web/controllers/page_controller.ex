defmodule PlatformWeb.PageController do
  use PlatformWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
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
