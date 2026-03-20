defmodule PlatformWeb.ControlCenter.MemoryEvents do
  @moduledoc """
  Handle_event clauses for memory management: filter and append.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  import PlatformWeb.ControlCenter.Helpers,
    only: [humanize_memory_type: 1, changeset_error_summary: 1]

  alias Platform.Agents.{Agent, MemoryContext}
  alias PlatformWeb.ControlCenter.AgentData

  def handle("filter_memories", %{"memory_filters" => params}, socket) do
    filters = AgentData.normalize_memory_filters(params)

    {:noreply,
     PlatformWeb.ControlCenterLive.reload_selected_agent(socket,
       selected_file_key: socket.assigns.selected_file_key,
       memory_filters: filters
     )}
  end

  def handle(
        "append_memory",
        %{"memory_entry" => params},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    memory_type = AgentData.normalize_memory_type(params["memory_type"])
    content = String.trim(params["content"] || "")

    cond do
      content == "" ->
        {:noreply,
         socket
         |> assign(:memory_form, AgentData.build_memory_form(params))
         |> put_flash(:error, "Memory content cannot be blank.")}

      true ->
        case MemoryContext.append_memory(agent.id, memory_type, content,
               date: AgentData.parse_memory_date(memory_type, params["date"]),
               metadata: %{"source" => "control_center"}
             ) do
          {:ok, _memory} ->
            {:noreply,
             socket
             |> put_flash(:info, "Added #{humanize_memory_type(memory_type)} memory.")
             |> assign(:memory_form, AgentData.build_memory_form())
             |> PlatformWeb.ControlCenterLive.reload_selected_agent(
               selected_file_key: socket.assigns.selected_file_key,
               memory_filters: socket.assigns.memory_filters
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:memory_form, AgentData.build_memory_form(params))
             |> put_flash(:error, changeset_error_summary(changeset))}
        end
    end
  end

  def handle("append_memory", _params, socket), do: {:noreply, socket}
end
