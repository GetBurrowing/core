defmodule PlatformWeb.Tasks.FilterPrefs do
  @moduledoc """
  The /tasks project and epic, remembered per USER (task 01a161fd stage 2)
  in `users.preferences`, through `Platform.Accounts.tasks_project_pref/1`
  and `put_tasks_project_pref/3`. The key itself lives in accounts.ex.

  ## Write: `sync/1`

  Called at the end of `BoardHooks.refresh_board/1`, the funnel every
  selection path reaches: `?project=` / `?epic=`, the old sidebar's
  `sidebar_select_project` / `sidebar_select_epic`, `filter_clear`, and the
  stale-id fallback (all through the shell's `select_project/2` or the epic
  toggle). It stores the RESOLVED `{selected_project_id, selected_epic_id}`,
  after the unreadable/archived fallback, and writes ONLY when that differs
  from the last value written or read (assign `:tasks_project_pref`). A
  PubSub refresh that leaves the selection alone writes nothing.

  It never writes:

    * for a nil `:current_user_id`;
    * on the dead render (only a connected LiveView persists);
    * before `apply_stored/2` has run once (the mount's first
      `refresh_board/1` sees the default All selection, which must not
      overwrite a stored project before it is read);
    * while a URL selection is settling. `BoardHooks` routes a URL project
      through `{:sidebar_project_selected, id}`, whose `select_project/2`
      resets the epic before `{:sidebar_epic_selected, id}` sets it again.
      `hold/1` sends `{:tasks_pref_settled}` after those messages (a
      process's messages to itself arrive in order), and `settled/1` syncs
      once they have all been handled, so the transient `{project, nil}` is
      never written.

  ## Read: `apply_stored/2`

  `BoardHooks.apply_url_filters/3` calls it first. On the LiveView's first
  call only, it reads the stored value from `:current_user_record` (no query)
  and, when the URL has no `project` key, puts the stored project and epic
  into the params, so the stored choice goes through the same selection path
  as a URL (readability and archive checks apply, and an archived project
  self-heals to All). `project=all` overrides it. It then assigns
  `:tasks_project_source` `"pref"`, which the template renders as
  `data-project-source` so `last_project.js` skips its per-device restore.
  With nothing stored on a connected bare URL it assigns `"default"`
  instead: the `project=all` that `pin_url/2` writes is the server's
  default, not a choice, so the hook may still replay a device's copy.

  ## Pin: `pin_url/2` (stage 5)

  A bare URL (no `project` key) means "the remembered project", and the
  remembered project changes with every pick. So a history entry left bare
  would show whatever was remembered when Back returned to it, not what it
  showed when it was made. `pin_url/2` rewrites the CURRENT entry, in place
  (`push_patch(replace: true)`), to the explicit selection it resolved:
  `?project=<id>` (plus `&epic=<id>`) or `?project=all`, keeping every other
  URL filter. It runs ONCE, on the first connected call (the entry the
  LiveView was opened on), and cannot loop: it disarms itself, and the
  replaced URL carries `project` anyway. User picks still push their own
  entry and are never rewritten.

  The per-device client-state (localStorage) copy stays as a dual write.
  """

  # parallel-ui: tasks.last_project_client_state

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [connected?: 1, push_patch: 2]

  alias Platform.Accounts
  alias PlatformWeb.Tasks.{BoardData, FilterBar}

  @doc """
  Read the stored selection on the first call and fold it into `params` when
  the URL names no project. Returns `{socket, params}`.
  """
  @spec apply_stored(Phoenix.LiveView.Socket.t(), map()) ::
          {Phoenix.LiveView.Socket.t(), map()}
  def apply_stored(socket, params) do
    if Map.has_key?(socket.assigns, :tasks_project_pref) do
      {socket, params}
    else
      stored = Accounts.tasks_project_pref(socket.assigns[:current_user_record])

      socket =
        socket
        |> assign(:tasks_project_pref, stored || {nil, nil})
        |> assign(:tasks_pin_url, connected?(socket) and not is_map_key(params, "project"))

      case stored do
        {project_id, epic_id} when not is_map_key(params, "project") ->
          params =
            params
            |> Map.put("project", project_id || "all")
            |> put_epic(epic_id)

          {assign(socket, :tasks_project_source, "pref"), params}

        nil when not is_map_key(params, "project") ->
          source = if connected?(socket), do: "default"
          {assign(socket, :tasks_project_source, source), params}

        _ ->
          {socket, params}
      end
    end
  end

  @doc """
  Replace the bare-of-project entry the LiveView was mounted on with the
  explicit selection the socket now holds. Call AFTER the selection has been
  applied. Only the first connected call on a bare URL arms it
  (`apply_stored/2`); every later call is a no-op.
  """
  @spec pin_url(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def pin_url(%{assigns: %{tasks_pin_url: true}} = socket) do
    url =
      socket.assigns
      |> FilterBar.url_state()
      |> Map.update(:selected_project_id, "all", &(&1 || "all"))
      |> BoardData.tasks_path()

    socket
    |> assign(:tasks_pin_url, false)
    |> push_patch(to: url, replace: true)
  end

  def pin_url(socket), do: socket

  defp put_epic(params, nil), do: params
  defp put_epic(params, epic_id), do: Map.put_new(params, "epic", epic_id)

  @doc """
  Persist the resolved selection when it differs from the last one written.
  """
  @spec sync(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def sync(socket) do
    assigns = socket.assigns
    current = {assigns[:selected_project_id], assigns[:selected_epic_id]}

    with user_id when is_binary(user_id) <- assigns[:current_user_id],
         {:ok, last} <- Map.fetch(assigns, :tasks_project_pref),
         0 <- Map.get(assigns, :tasks_pref_holds, 0),
         true <- connected?(socket),
         true <- current != last do
      {project_id, epic_id} = current
      _ = Accounts.put_tasks_project_pref(user_id, project_id, epic_id)
      assign(socket, :tasks_project_pref, current)
    else
      _ -> socket
    end
  end

  @doc """
  Defer `sync/1` until the selection messages just sent to self have been
  handled. Call AFTER the sends.
  """
  @spec hold(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def hold(socket) do
    send(self(), {:tasks_pref_settled})
    assign(socket, :tasks_pref_holds, Map.get(socket.assigns, :tasks_pref_holds, 0) + 1)
  end

  @doc "Handle `{:tasks_pref_settled}`: release one hold, then sync."
  @spec settled(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def settled(socket) do
    holds = max(Map.get(socket.assigns, :tasks_pref_holds, 0) - 1, 0)

    socket
    |> assign(:tasks_pref_holds, holds)
    |> sync()
  end
end
