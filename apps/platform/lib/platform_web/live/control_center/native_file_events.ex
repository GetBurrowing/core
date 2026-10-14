defmodule PlatformWeb.ControlCenter.NativeFileEvents do
  @moduledoc """
  Handle_event clauses for a native agent's "Agent files" editor (task
  01a10322 stage 5): typing (the unsaved dot and the settings JSON check) and
  Save / Save and restart.

  ## Refused server-side

  Editing a native agent's files is root-equivalent on the install (hooks in
  `.claude/settings.json` run as the agent, which may have sudo). Every save
  goes through `Platform.Agents.NativeAgents.save_file/5`, which refuses
  anyone `can_manage?/2` refuses; this module checks it again before it
  touches the agent, so a `native_file_save` sent straight down the socket by
  a non-manager writes nothing. The old `save_workspace_file` event is routed
  here for a native agent too (`PlatformWeb.ControlCenter.WorkspaceEvents`),
  so it is not a way around the check.
  """
  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]
  import PlatformWeb.ControlCenter.Helpers, only: [changeset_error_summary: 1]

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, NativeAgents}
  alias PlatformWeb.ControlCenter.NativeFiles

  @doc "The editor's form for a selected file (or a new one when nil)."
  def build_form(selected, overrides \\ %{})

  def build_form(%{file_key: key, content: content}, overrides),
    do:
      to_form(Map.merge(%{"file_key" => key, "content" => content}, overrides), as: :native_file)

  def build_form(nil, overrides),
    do: to_form(Map.merge(%{"file_key" => "", "content" => ""}, overrides), as: :native_file)

  @doc "The editor's per-file assigns, reset (a new selection, or after a save)."
  def reset(socket, opts \\ []) do
    selected = socket.assigns[:selected_workspace_file]

    socket
    |> assign(:native_file_form, build_form(selected))
    |> assign(:native_file_dirty?, false)
    |> assign(:native_file_json_error, json_error(selected))
    |> assign(:native_saved_key, Keyword.get(opts, :saved_key))
  end

  def handle("native_file_change", %{"native_file" => params}, socket) do
    selected = socket.assigns.selected_workspace_file
    key = selected_key(selected, params)
    content = params["content"] || ""

    dirty? =
      case selected do
        %{content: ^content} -> false
        %{} -> true
        nil -> content != "" or key != ""
      end

    error =
      case NativeAgents.check_json(key, content) do
        :ok -> nil
        {:error, {:invalid_json, line}} -> line
      end

    {:noreply,
     socket
     |> assign(
       :native_file_form,
       build_form(selected, %{"file_key" => key, "content" => content})
     )
     |> assign(:native_file_dirty?, dirty?)
     |> assign(:native_file_json_error, error)}
  end

  def handle("native_file_change", _params, socket), do: {:noreply, socket}

  def handle(
        "native_file_save",
        %{"native_file" => params} = all,
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    # Re-read the selected agent's managed status and the actor's right to
    # manage it here, not from any assign the page rendered with.
    actor = socket.assigns.current_user_id

    cond do
      not NativeAgents.managed?(agent) ->
        {:noreply, put_flash(socket, :error, "That agent is not run by this server.")}

      not NativeAgents.can_manage?(actor, agent) ->
        {:noreply, put_flash(socket, :error, NativeFiles.locked_message())}

      true ->
        save(agent, actor, params, all["intent"] == "save_restart", socket)
    end
  end

  def handle("native_file_save", _params, socket), do: {:noreply, socket}

  defp save(agent, actor, params, restart?, socket) do
    selected = socket.assigns.selected_workspace_file
    key = selected_key(selected, params)
    content = params["content"] || ""
    expected = if selected && selected.file_key == key, do: selected.version, else: nil

    case NativeAgents.save_file(actor, agent, key, content, expected) do
      {:ok, file} ->
        socket =
          PlatformWeb.ControlCenterLive.reload_selected_agent(socket,
            selected_file_key: file.file_key,
            memory_filters: socket.assigns.memory_filters,
            native_saved_key: file.file_key
          )

        {:noreply, maybe_restart(socket, agent, restart?)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, NativeFiles.locked_message())}

      {:error, :invalid_key} ->
        {:noreply,
         socket
         |> keep_draft(selected, key, content)
         |> put_flash(
           :error,
           "File names are relative to the agent's folder, at most three levels deep, " <>
             "using letters, digits and . _ @ + -."
         )}

      {:error, {:invalid_json, line}} ->
        {:noreply,
         socket
         |> keep_draft(selected, key, content)
         |> assign(:native_file_json_error, line)}

      {:error, :file_exists} ->
        {:noreply,
         socket
         |> keep_draft(selected, key, content)
         |> put_flash(:error, "A file called #{key} already exists. Open it from the list.")}

      {:error, :stale_workspace_file} ->
        {:noreply,
         socket
         |> keep_draft(selected, key, content)
         |> put_flash(:error, "That file changed underneath you. Copy your edits, then reload.")}

      {:error, :not_managed} ->
        {:noreply, put_flash(socket, :error, "That agent is not run by this server.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> keep_draft(selected, key, content)
         |> put_flash(:error, changeset_error_summary(changeset))}
    end
  end

  # Save and restart: only when the agent's process is up. A stopped agent
  # picks the file up when it next starts; this never starts it.
  defp maybe_restart(socket, agent, true) do
    if NativeAgents.live?(AgentHost.status(agent)) do
      case AgentHost.restart_agent(agent) do
        :ok ->
          socket
          |> assign(:restarting_agent_id, agent.id)
          |> PlatformWeb.ControlCenterLive.refresh_native()

        {:error, :not_connected} ->
          put_flash(socket, :error, "Saved, but restart failed: #{AgentHost.describe()}.")

        {:error, reason} ->
          put_flash(socket, :error, "Saved, but restart failed: #{inspect(reason)}")
      end
    else
      socket
    end
  end

  defp maybe_restart(socket, _agent, false), do: socket

  defp keep_draft(socket, selected, key, content) do
    socket
    |> assign(:native_file_form, build_form(selected, %{"file_key" => key, "content" => content}))
    |> assign(:native_file_dirty?, true)
  end

  # An existing file's key is the one the page loaded, never the posted one.
  defp selected_key(%{file_key: key}, _params), do: key
  defp selected_key(nil, params), do: String.trim(params["file_key"] || "")

  defp json_error(%{file_key: key, content: content}) do
    case NativeAgents.check_json(key, content) do
      :ok -> nil
      {:error, {:invalid_json, line}} -> line
    end
  end

  defp json_error(_), do: nil
end
