defmodule PlatformWeb.ControlCenter.AgentCrudEvents do
  @moduledoc """
  Handle_event clauses for agent CRUD: create, toggle, request/cancel/confirm delete.
  """
  use PlatformWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]
  import PlatformWeb.ControlCenter.Helpers, only: [changeset_error_summary: 1]

  alias Platform.Agents.Agent
  alias Platform.Repo
  alias PlatformWeb.ControlCenter.AgentData

  def handle("create_agent", %{"create_agent" => params}, socket) do
    attrs = AgentData.create_agent_attrs_from_params(params)

    case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created #{agent.name}.")
         |> assign(:show_create_agent, false)
         |> assign(
           :create_agent_form,
           Phoenix.Component.to_form(AgentData.default_create_agent_params(), as: :create_agent)
         )
         |> push_patch(to: ~p"/control/#{agent.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:create_agent_form, AgentData.build_create_agent_form(params))
         |> put_flash(:error, changeset_error_summary(changeset))}
    end
  end

  def handle("create_agent", _params, socket), do: {:noreply, socket}

  def handle("toggle_create_agent", _params, socket) do
    {:noreply, assign(socket, :show_create_agent, !socket.assigns.show_create_agent)}
  end

  def handle("request_delete_agent", %{"slug" => slug}, socket) when is_binary(slug) do
    case AgentData.find_agent_directory_entry(socket.assigns.agents, slug) do
      %{agent: %Agent{}, workspace_managed?: false} ->
        {:noreply, assign(socket, :pending_delete_slug, slug)}

      %{workspace_managed?: true} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This agent is managed by the mounted workspace config. Remove it there to delete it permanently."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Agent not found.")}
    end
  end

  def handle(
        "request_delete_agent",
        _params,
        %{assigns: %{selected_agent: %Agent{} = agent, selected_agent_directory_entry: entry}} =
          socket
      ) do
    if entry && entry.workspace_managed? do
      {:noreply,
       put_flash(
         socket,
         :error,
         "This agent is managed by the mounted workspace config. Remove it there to delete it permanently."
       )}
    else
      {:noreply, assign(socket, :pending_delete_slug, agent.slug)}
    end
  end

  def handle("request_delete_agent", _params, socket), do: {:noreply, socket}

  def handle("cancel_delete_agent", _params, socket) do
    {:noreply, assign(socket, :pending_delete_slug, nil)}
  end

  def handle("delete_agent", %{"slug" => slug}, socket) when is_binary(slug) do
    case {socket.assigns.pending_delete_slug,
          AgentData.find_agent_directory_entry(socket.assigns.agents, slug)} do
      {pending_slug, _entry} when pending_slug != slug ->
        {:noreply, put_flash(socket, :error, "Confirm the delete action first.")}

      {_pending_slug, %{agent: %Agent{} = agent, workspace_managed?: false}} ->
        handle_delete_agent(socket, agent)

      {_pending_slug, %{workspace_managed?: true}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This agent is managed by the mounted workspace config. Remove it there to delete it permanently."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Agent not found.")}
    end
  end

  def handle(
        "delete_agent",
        _params,
        %{assigns: %{selected_agent: %Agent{} = agent, selected_agent_directory_entry: entry}} =
          socket
      ) do
    cond do
      socket.assigns.pending_delete_slug != agent.slug ->
        {:noreply, put_flash(socket, :error, "Confirm the delete action first.")}

      entry && entry.workspace_managed? ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This agent is managed by the mounted workspace config. Remove it there to delete it permanently."
         )}

      true ->
        handle_delete_agent(socket, agent)
    end
  end

  def handle("delete_agent", _params, socket), do: {:noreply, socket}

  defp handle_delete_agent(socket, %Agent{} = agent) do
    case AgentData.delete_agent(agent) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Deleted #{agent.name}.")
          |> assign(:agents, AgentData.list_agents())
          |> assign(:pending_delete_slug, nil)
          |> assign(:selected_agent, nil)
          |> assign(:selected_agent_directory_entry, nil)

        {:noreply, push_patch(socket, to: ~p"/control")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete agent: #{inspect(reason)}")}
    end
  end
end
