defmodule PlatformWeb.Tasks.FilterHooks do
  @moduledoc """
  Sheet state for the phone Tasks header (task 01a161fd stage 3), the same
  shape as `PlatformWeb.Tasks.MaskHooks` (an `attach_hook` on
  `:handle_event`) and `PlatformWeb.ChatLive.ChatListHooks` (one assign
  drives every sheet, so two can never be open at once). Attached from
  `BoardHooks.attach/1`, so the 653-line shell gains nothing.

  Owns:

    * `@tasks_filter_sheet`: `nil | :project | {:epics, project_id} | :filter
      | {:filter, :project} | {:filter, {:epics, project_id}}`. The
      `{:filter, inner}` forms (task 01a168c2) are the project picker opened
      from the Filter surface's Project row: `inner` is the picker's own
      state, hosted inside the Filter sheet or popover, and Back from its
      root returns to `:filter`.
    * `@tasks_filter_epics`: the epics of the project drilled into from the
      project sheet, loaded with `EpicLoaders.load_epics/1`.
    * Events `tasks_filter_open` (`sheet`: "project" | "filter" |
      "filter_project"),
      `tasks_filter_close`, `tasks_filter_epics` (`id`) and
      `tasks_filter_back`, and (stage 5) `tasks_restore_device_project`
      (`id`).

  Nothing here changes a filter. Every option in the sheets is a plain
  `<.link patch>` with no `phx-click`, and `TasksLive.handle_params/3`
  decodes the URL through `BoardHooks.apply_url_filters/3`. That funnel calls
  `after_patch/1`, which closes the PROJECT sheet (a project or epic pick
  closes it, as in the prototype) and leaves the FILTER sheet open, so its
  options apply live and 'Show N tasks' closes it. A pick from the picker
  hosted in the Filter sheet returns to the Filter sheet, whose Project row
  then shows the new project.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, push_patch: 2]

  alias PlatformWeb.Tasks.{EpicLoaders, FilterBar}
  alias PlatformWeb.Tasks.Selection

  @sheets %{
    "project" => :project,
    "filter" => :filter,
    "filter_project" => {:filter, :project}
  }

  @doc "Default the sheet state and attach the event hook."
  @spec attach(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def attach(socket) do
    socket
    |> assign(:tasks_filter_sheet, nil)
    |> assign(:tasks_filter_epics, [])
    |> attach_hook(:tasks_filter_events, :handle_event, &handle_event/3)
  end

  @doc """
  Called by `BoardHooks.apply_url_filters/3` on every URL change: the project
  sheet closes, the filter sheet stays, and the picker hosted in the filter
  sheet returns to the filter sheet.
  """
  @spec after_patch(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def after_patch(socket) do
    case socket.assigns[:tasks_filter_sheet] do
      :filter -> socket
      {:filter, _picker} -> assign(socket, :tasks_filter_sheet, :filter)
      _other -> assign(socket, :tasks_filter_sheet, nil)
    end
  end

  defp handle_event("tasks_filter_open", %{"sheet" => sheet}, socket) do
    case Map.fetch(@sheets, sheet) do
      {:ok, value} -> {:halt, assign(socket, :tasks_filter_sheet, value)}
      :error -> {:halt, socket}
    end
  end

  defp handle_event("tasks_filter_close", _params, socket),
    do: {:halt, assign(socket, :tasks_filter_sheet, nil)}

  # The › button on a project row. Only a project the viewer can read opens
  # its epic level; anything else is ignored.
  defp handle_event("tasks_filter_epics", %{"id" => id}, socket) when is_binary(id) do
    with {:ok, uuid} <- Platform.UUID.cast(id),
         %{id: project_id} <- Selection.readable_project(socket, uuid) do
      {:halt,
       socket
       |> assign(:tasks_filter_epics, EpicLoaders.load_epics(project_id))
       |> assign(:tasks_filter_sheet, epics_state(socket, project_id))}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event("tasks_filter_back", _params, socket),
    do: {:halt, assign(socket, :tasks_filter_sheet, back(socket.assigns[:tasks_filter_sheet]))}

  # Stage 5: `last_project.js` replays a device's project over the server's
  # DEFAULT `?project=all` (nothing remembered for the user). It is a REPLACE
  # patch, so the entry names what it shows, sent from here rather than from
  # the hook: the join's own replace lands after the hook mounts and would
  # overwrite a client-side patch. Once only, and only over the default.
  defp handle_event("tasks_restore_device_project", %{"id" => id}, socket)
       when is_binary(id) do
    with "default" <- socket.assigns[:tasks_project_source],
         {:ok, uuid} <- Platform.UUID.cast(id) do
      url =
        socket.assigns
        |> FilterBar.url_state()
        |> Map.merge(%{selected_project_id: uuid, selected_epic_id: nil})
        |> FilterBar.href(%{})

      {:halt,
       socket
       |> assign(:tasks_project_source, nil)
       |> push_patch(to: url, replace: true)}
    else
      _ -> {:halt, socket}
    end
  end

  defp handle_event(_event, _params, socket), do: {:cont, socket}

  # The epic level stays in the surface the picker was opened from.
  defp epics_state(socket, project_id) do
    case socket.assigns[:tasks_filter_sheet] do
      {:filter, _picker} -> {:filter, {:epics, project_id}}
      _other -> {:epics, project_id}
    end
  end

  defp back({:filter, {:epics, _id}}), do: {:filter, :project}
  defp back({:filter, :project}), do: :filter
  defp back(_sheet), do: :project
end
