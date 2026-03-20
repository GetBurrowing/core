defmodule PlatformWeb.ControlCenter.WorkspaceEvents do
  @moduledoc """
  Handle_event clauses for workspace file management: select, new, save.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]
  import PlatformWeb.ControlCenter.Helpers, only: [changeset_error_summary: 1]

  alias Platform.Agents.{Agent, AgentServer, MemoryContext}
  alias PlatformWeb.ControlCenter.AgentData

  def handle("select_workspace_file", %{"file_key" => file_key}, socket) do
    {:noreply,
     PlatformWeb.ControlCenterLive.reload_selected_agent(socket,
       selected_file_key: file_key,
       memory_filters: socket.assigns.memory_filters
     )}
  end

  def handle(
        "new_workspace_file",
        _params,
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    workspace_files = MemoryContext.list_workspace_files(agent.id)

    {:noreply,
     socket
     |> assign(:selected_workspace_file, nil)
     |> assign(:selected_file_key, nil)
     |> assign(:workspace_files, workspace_files)
     |> assign(
       :workspace_form,
       AgentData.build_workspace_form(workspace_files, nil, %{
         "file_key" => AgentData.next_workspace_file_key(workspace_files)
       })
     )}
  end

  def handle("new_workspace_file", _params, socket), do: {:noreply, socket}

  def handle(
        "save_workspace_file",
        %{"workspace_file" => params},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    file_key =
      params["file_key"] ||
        (socket.assigns.selected_workspace_file &&
           socket.assigns.selected_workspace_file.file_key) ||
        ""

    content = params["content"] || ""
    selected_workspace_file = socket.assigns.selected_workspace_file

    opts =
      if selected_workspace_file && selected_workspace_file.file_key == file_key do
        [expected_version: selected_workspace_file.version]
      else
        []
      end

    cond do
      String.trim(file_key) == "" ->
        {:noreply,
         socket
         |> assign(
           :workspace_form,
           AgentData.build_workspace_form(
             socket.assigns.workspace_files,
             selected_workspace_file,
             params
           )
         )
         |> put_flash(:error, "Choose a file key before saving.")}

      true ->
        case MemoryContext.upsert_workspace_file(agent.id, String.trim(file_key), content, opts) do
          {:ok, workspace_file} ->
            refresh_runtime_if_running(agent)

            {:noreply,
             socket
             |> put_flash(:info, "Saved #{workspace_file.file_key}.")
             |> PlatformWeb.ControlCenterLive.reload_selected_agent(
               selected_file_key: workspace_file.file_key,
               memory_filters: socket.assigns.memory_filters
             )}

          {:error, :stale_workspace_file} ->
            {:noreply,
             socket
             |> put_flash(:error, "That file changed underneath you. Refresh and try again.")
             |> PlatformWeb.ControlCenterLive.reload_selected_agent(
               selected_file_key: socket.assigns.selected_file_key,
               memory_filters: socket.assigns.memory_filters
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(
               :workspace_form,
               AgentData.build_workspace_form(
                 socket.assigns.workspace_files,
                 selected_workspace_file,
                 params
               )
             )
             |> put_flash(:error, changeset_error_summary(changeset))}
        end
    end
  end

  def handle("save_workspace_file", _params, socket), do: {:noreply, socket}

  defp refresh_runtime_if_running(%Agent{} = agent) do
    case AgentServer.whereis(agent.id) do
      pid when is_pid(pid) ->
        _ = AgentServer.refresh(agent.id)
        :ok

      nil ->
        :ok
    end
  end
end
