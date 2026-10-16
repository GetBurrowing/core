defmodule PlatformWeb.ExtensionPageLive do
  @moduledoc """
  The reader for `Platform.Extension.live_pages/0`: ONE generic route,
  `/m/:prefix`, inside the `:authenticated` live_session, so an extension's
  page gets core's shell (rail, layout) and core's sign-in. Core's router
  compiles before any module, so it cannot mount a module's LiveView by
  name; this page looks the prefix up per request
  (`Platform.Extensions.live_page_for/1`) instead.

  Answers 404, the way `PlatformWeb.EmailLive` does, for:

    * a prefix no registered extension claims (a without-modules build has
      none, so every `/m/...` is a 404 there);
    * an external user: extension pages are internal surfaces.

  Otherwise nests the claiming LiveView with `live_render/3`, id
  `"ext-page-<prefix>"`, passing ONLY `%{"user_id" => id}`. The child runs
  no live_session `on_mount` hook and inherits no assign: it re-reads the
  user and authorizes every read and write itself.
  """
  use PlatformWeb, :live_view

  alias Platform.Extensions
  alias Platform.Tenancy
  alias PlatformWeb.ExtensionPageLive.NotFoundError

  @impl true
  def mount(%{"prefix" => prefix}, _session, socket) do
    user = socket.assigns[:current_user_record]
    page = Extensions.live_page_for(prefix)

    if is_nil(page) or not match?(%{id: id} when is_binary(id), user) or
         Tenancy.external_user?(user) do
      raise NotFoundError
    end

    title = Map.get(page, :title) || prefix

    # The shell's top bar names the surface from the LiveView module; this
    # one module serves every page, so it names the page instead.
    {:ok,
     socket
     |> assign(:page_title, title)
     |> assign(:active_module, title)
     |> assign(:current_path, "/m/" <> prefix)
     |> assign(:page_view, page.live_view)
     |> assign(:child_id, "ext-page-" <> prefix)
     |> assign(:child_session, %{"user_id" => user.id})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@child_id <> "-host"} class="flex h-full min-h-0 flex-col">
      {live_render(@socket, @page_view, id: @child_id, session: @child_session)}
    </div>
    """
  end
end
