defmodule PlatformWeb.Tasks.EpicLoaders do
  @moduledoc """
  Loading and enrichment of the `:epics` assign for the Tasks surface,
  lifted out of `PlatformWeb.TasksLive` so the shell stays inside its
  surface line budget (`scripts/surface-budgets.txt`).

  Same shape as `PlatformWeb.Tasks.ReviewLoaders`: socket in, socket out,
  no rendered markup. Behaviour is identical to the shell-private
  `reload_epics/1` + `enrich_epics/1` it replaces.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Platform.Tasks
  alias PlatformWeb.Tasks.MaskHooks

  @doc """
  Re-query and re-enrich `:epics` for the socket's currently selected
  project.

  `assign_mask_labels/1` re-runs here because `:epics` is a MASKED ENTITY
  SET (task 01a00cf1): the breadcrumb letters an epic out of the same map
  the rail letters orgs and projects from, and this is the only writer of
  `:epics`. Without it a project switch would leave every epic falling
  through `rail_label/2`'s fail-closed branch and the breadcrumb would read
  a bare `Epic` for the rest of the session.
  """
  def reload_epics(socket) do
    socket
    |> assign(:epics, load_epics(socket.assigns.selected_project_id))
    |> MaskHooks.assign_mask_labels()
  end

  @doc """
  List the project's epics as display maps carrying task/done counts.
  Used directly at mount, before the socket has a selection to read.
  """
  def load_epics(project_id) do
    epics = Tasks.list_epics_for_project(project_id)
    counts = Tasks.epic_task_counts(Enum.map(epics, & &1.id))

    Enum.map(epics, fn epic ->
      c = Map.get(counts, epic.id, %{total: 0, done: 0})

      %{
        id: epic.id,
        name: epic.name,
        description: epic.description,
        status: epic.status,
        task_count: c.total,
        done_count: c.done
      }
    end)
  end
end
