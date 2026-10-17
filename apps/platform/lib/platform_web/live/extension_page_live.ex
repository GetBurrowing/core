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
  `"ext-page-<prefix>"`, passing `%{"user_id" => id}` plus, only when the
  URL carried any, a bounded `"query"`: the URL's query parameters (never
  `prefix`) as UNTRUSTED strings. Only string keys with string values are
  kept, at most 16 keys, each key at most 64 bytes and each value at most
  512 bytes; anything else (lists, maps, oversized entries) is dropped. A
  nested LiveView gets no `handle_params/3`, so this is the only way a
  child sees, e.g., a vendor's OAuth return parameters. The child runs no
  live_session `on_mount` hook and inherits no assign: it re-reads the user,
  shape-checks anything it reads from `query`, and authorizes every read and
  write itself.
  """
  use PlatformWeb, :live_view

  alias Platform.Extensions
  alias Platform.Tenancy
  alias PlatformWeb.ExtensionPageLive.NotFoundError

  @impl true
  def mount(%{"prefix" => prefix} = params, _session, socket) do
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
     |> assign(:child_session, child_session(user, params))}
  end

  @max_query_keys 16
  @max_key_bytes 64
  @max_value_bytes 512

  defp child_session(user, params) do
    case forwarded_query(params) do
      query when map_size(query) == 0 -> %{"user_id" => user.id}
      query -> %{"user_id" => user.id, "query" => query}
    end
  end

  # The URL's query as untrusted data: string key => string value only,
  # bounded in count and size. `prefix` is the route's own segment.
  defp forwarded_query(params) do
    params
    |> Map.delete("prefix")
    |> Enum.filter(fn {key, value} ->
      is_binary(key) and is_binary(value) and byte_size(key) in 1..@max_key_bytes and
        byte_size(value) <= @max_value_bytes
    end)
    |> Enum.sort()
    |> Enum.take(@max_query_keys)
    |> Map.new()
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
