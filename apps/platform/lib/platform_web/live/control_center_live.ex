defmodule PlatformWeb.ControlCenterLive do
  use PlatformWeb, :live_view

  alias Ecto.Adapters.SQL.Sandbox

  alias Platform.Agents.{
    Agent,
    AgentServer,
    Config,
    MemoryContext
  }

  alias Platform.AgentHost
  alias Platform.Agents.NativeAgents
  alias Platform.Agents.NativeLogin
  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  alias PlatformWeb.ControlCenter.AgentAvatarUpload
  alias PlatformWeb.ControlCenter.AgentCard
  alias PlatformWeb.ControlCenter.AgentCrudEvents
  alias PlatformWeb.ControlCenter.AgentData
  alias PlatformWeb.ControlCenter.AgentDetail
  alias PlatformWeb.ControlCenter.MemoryEvents
  alias PlatformWeb.ControlCenter.NativeAgentEvents
  alias PlatformWeb.ControlCenter.NativeLogin, as: NativeLoginPanel
  alias PlatformWeb.ControlCenter.NativeFiles
  alias PlatformWeb.AgentConfig.{Session, SessionStrip}
  alias PlatformWeb.ControlCenter.NativeStatus
  alias PlatformWeb.ControlCenter.Onboarding
  alias PlatformWeb.ControlCenter.OnboardingEvents
  alias PlatformWeb.ControlCenter.RolesPanel
  alias PlatformWeb.ControlCenter.RuntimeEvents
  alias PlatformWeb.ControlCenter.VaultEvents
  alias PlatformWeb.ControlCenter.WorkspaceEvents

  import PlatformWeb.ControlCenter.Helpers

  @impl true
  def mount(_params, session, socket) do
    current_user_id = session["current_user_id"]

    # Live rows and header for native agents (task 01a10322 stage 4): every
    # observed-state change the agent host reports re-renders them.
    if connected?(socket), do: AgentHost.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:current_user_id, current_user_id)
     |> assign(:agent_host_connected?, AgentHost.connected?())
     |> assign(:restarting_agent_id, nil)
     |> assign(:manageable_agent_ids, MapSet.new())
     |> assign(:native_header, nil)
     |> assign(:agents, [])
     |> assign(:selected_agent, nil)
     |> assign(:runtime, %{status: :unknown, running?: false, pid: nil, active_session_ids: []})
     |> assign(:overview_counts, %{workspace_files: 0, memories: 0, sessions: 0, vault: 0})
     |> assign(:model_chain_result, {:error, :no_agent_selected})
     |> assign(:workspace_files, [])
     |> assign(:selected_workspace_file, nil)
     |> assign(:selected_file_key, nil)
     |> assign(
       :workspace_form,
       to_form(%{"file_key" => "", "content" => ""}, as: :workspace_file)
     )
     |> NativeAgentEvents.reset()
     |> assign(:session, nil)
     |> assign(:config_entry?, false)
     |> assign(:memory_filters, AgentData.default_memory_filters())
     |> assign(
       :memory_filter_form,
       to_form(AgentData.default_memory_filters(), as: :memory_filters)
     )
     |> assign(:recent_memories, [])
     |> assign(:recent_sessions, [])
     |> assign(:agent_credentials, [])
     |> assign(:platform_credentials, [])
     |> assign(:all_platform_credentials, [])
     |> assign(:show_credential_form, false)
     |> assign(:credential_form, VaultEvents.blank_form())
     |> assign(:config_form, to_form(%{}, as: :config))
     |> assign(
       :create_agent_form,
       to_form(AgentData.default_create_agent_params(), as: :create_agent)
     )
     |> assign(:show_create_agent, false)
     |> assign(:pending_delete_slug, nil)
     |> assign(:memory_form, to_form(AgentData.default_memory_entry(), as: :memory_entry))
     |> assign(:agent_status, :unknown)
     |> assign(:selected_agent_directory_entry, nil)
     # Onboarding flow assigns
     |> assign(:show_onboarding_chooser, false)
     |> assign(:onboarding_flow, nil)
     |> assign(:selected_template, nil)
     |> assign(:template_form, to_form(%{"name" => ""}, as: :template))
     |> assign(
       :federate_form,
       to_form(%{"runtime_id" => "", "display_name" => "", "agent_name" => ""}, as: :federate)
     )
     |> assign(:federate_result, nil)
     |> assign(:import_agents, [])
     |> assign(:import_selected, MapSet.new())
     |> assign(:external_agent_form, AgentData.build_external_agent_form())
     |> assign(:probe_result, nil)
     |> assign(:regenerated_token, nil)
     |> assign(:show_add_space_modal, false)
     |> assign(:available_spaces, [])
     |> assign(:available_meeting_spaces, [])
     # Roles panel assigns (M7 stage 5)
     |> assign(:active_tab, :roles)
     |> assign(:show_role_advanced, false)
     |> assign_roles_panel()
     # Avatar upload (task 01a00122 stage 2). `max_entries: 1` also buys the
     # replace semantics for free: `UploadConfig.maybe_replace_sole_entry/2`
     # cancels the previous entry when a second file is picked, so the form
     # never holds two candidate avatars. See `AgentAvatarUpload` for why
     # `accept` is not the type control.
     |> allow_upload(AgentAvatarUpload.upload_name(),
       accept: AgentAvatarUpload.accept(),
       max_entries: 1,
       max_file_size: AgentAvatarUpload.max_file_size()
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    agents = AgentData.list_agents()
    selected_slug = AgentData.resolve_selected_agent_slug(params["agent_slug"], agents)
    selected_agent = selected_slug && AgentData.ensure_selected_agent(selected_slug, agents)
    # Re-fetch after ensure_agent may have created/upserted the agent record
    agents = if selected_agent, do: AgentData.list_agents(), else: agents
    selected_agent = selected_agent && Repo.get(Agent, selected_agent.id)

    selected_entry =
      selected_agent && AgentData.find_agent_directory_entry(agents, selected_agent.slug)

    socket =
      socket
      |> assign(:agents, agents)
      |> assign(:selected_agent, selected_agent)
      |> assign(:selected_agent_directory_entry, selected_entry)

    socket =
      if selected_agent do
        assign_agent_panel(socket, selected_agent,
          selected_file_key: params["file"] || socket.assigns[:selected_file_key],
          reset_forms?: agent_changed?(socket, selected_agent)
        )
      else
        assign_empty_panel(socket)
      end

    {:noreply, socket}
  end

  # ── Agent host (native agents, task 01a10322 stage 4) ─────────────

  @impl true
  def handle_info({:agent_host_status, _event}, socket) do
    {:noreply, refresh_native(socket)}
  end

  def handle_info(msg, socket) do
    case Session.handle_info(msg, socket) do
      :unhandled -> {:noreply, socket}
      reply -> reply
    end
  end

  @impl true
  def handle_async(:session_restart, result, socket), do: Session.handle_async(result, socket)

  @doc """
  Re-read the directory and every native-agent view (rows, the managed
  header, who may manage what) after an agent-host event or a control.
  """
  def refresh_native(socket) do
    agents = AgentData.list_agents()
    selected = socket.assigns[:selected_agent]

    socket
    |> assign(:agents, agents)
    |> assign(
      :selected_agent_directory_entry,
      selected && AgentData.find_agent_directory_entry(agents, selected.slug)
    )
    |> assign_native()
  end

  defp assign_native(socket) do
    agents = socket.assigns.agents
    user_id = socket.assigns.current_user_id

    manageable =
      for %{managed?: true, agent: %Agent{} = agent} <- agents,
          NativeAgents.can_manage?(user_id, agent),
          into: MapSet.new(),
          do: agent.id

    socket
    |> assign(:agent_host_connected?, AgentHost.connected?())
    |> assign(:manageable_agent_ids, manageable)
    |> clear_finished_restart()
    |> then(&assign(&1, :native_header, native_header(&1)))
  end

  # "Restarting" holds from the click until the host reports the agent in any
  # state other than starting.
  defp clear_finished_restart(%{assigns: %{restarting_agent_id: nil}} = socket), do: socket

  defp clear_finished_restart(%{assigns: %{restarting_agent_id: id}} = socket) do
    case AgentHost.status(id) do
      %{state: :starting} -> socket
      nil -> socket
      _settled -> assign(socket, :restarting_agent_id, nil)
    end
  end

  defp native_header(
         %{assigns: %{selected_agent_directory_entry: %{managed?: true} = entry}} = socket
       ) do
    view = NativeStatus.row(entry)
    restarting? = socket.assigns.restarting_agent_id == entry.agent.id
    connected? = socket.assigns.agent_host_connected?
    key_set? = NativeLogin.api_key_set?(entry.agent)
    login_mode = NativeLogin.login_mode()

    %{
      view: view,
      harness: entry.harness,
      host: AgentHost.host(),
      observed_at: entry.observed && entry.observed.observed_at,
      restarting?: restarting?,
      can_manage?: MapSet.member?(socket.assigns.manageable_agent_ids, entry.agent.id),
      # Agent files (stage 5): is the process up, which saved files has it
      # not picked up, and has the host said what it applied at all.
      live?: NativeAgents.live?(entry.observed),
      pending_keys:
        NativeAgents.pending_file_keys(socket.assigns[:workspace_files] || [], entry.observed),
      applied_known?: is_map(entry.observed && entry.observed.files_applied),
      buttons: NativeStatus.header_buttons(view, connected?, restarting?),
      # Login (stage 6): is an API key saved, and which step to show.
      key_set?: key_set?,
      login_mode: login_mode,
      login_step: NativeLogin.step(entry.observed, key_set?, login_mode)
    }
  end

  defp native_header(_socket), do: nil

  # "Recent output" is kept with the agent it was read for, so switching
  # agents never shows another agent's pane.
  defp recent_output_for({agent_id, output}, %Agent{id: agent_id}), do: output
  defp recent_output_for(_output, _agent), do: nil

  # ── Roles panel events (M7 stage 5) ───────────────────────────────
  # Source-level guard tests compare every handle_control_event name with this map.
  # Unknown events fail closed before any delegated handler runs.
  @event_policy %{
    "switch_control_tab" => :ui,
    "toggle_role_advanced" => :ui,
    "assign_role" => :responsibility,
    "clear_role_assignment" => :responsibility,
    "set_responsibility_override" => :responsibility,
    "clear_responsibility_override" => :responsibility,
    "start_runtime" => :manage_selected,
    "stop_runtime" => :manage_selected,
    "refresh_runtime" => :manage_selected,
    "validate_config" => :manage_selected,
    "save_config" => :manage_selected,
    "remove_avatar" => :manage_selected,
    "cancel_avatar_upload" => :manage_selected,
    "toggle_credential_form" => :vault,
    "create_credential" => :vault,
    "create_agent" => :create_ownerless,
    "toggle_create_agent" => :create_ownerless,
    "request_delete_agent" => :manage_selected,
    "cancel_delete_agent" => :manage_selected,
    "delete_agent" => :manage_selected,
    "select_workspace_file" => :ui,
    "new_workspace_file" => :manage_selected,
    "save_workspace_file" => :manage_selected,
    "filter_memories" => :ui,
    "append_memory" => :manage_selected,
    "open_onboarding_chooser" => :ui,
    "close_onboarding" => :ui,
    "choose_onboarding" => :ui,
    "select_template" => :ui,
    "back_to_templates" => :ui,
    "create_from_template" => :create_ownerless,
    "submit_federate" => :federate,
    "federate_done" => :ui,
    "toggle_import_agent" => :create_ownerless,
    "submit_import" => :create_ownerless,
    "external_agent_change" => :create_ownerless,
    "submit_external" => :create_ownerless,
    "set_vault_mode" => :vault,
    "suspend_federated_runtime" => :manage_selected,
    "unsuspend_federated_runtime" => :manage_selected,
    "revoke_federated_runtime" => :manage_selected,
    "regenerate_federated_token" => :manage_selected,
    "dismiss_regenerated_token" => :ui,
    "save_tool_profile" => :manage_selected,
    "save_agent_restrictions" => :manage_selected,
    "show_add_space_modal" => :manage_selected,
    "hide_add_space_modal" => :ui,
    "add_agent_to_space" => :manage_selected,
    "native_start" => :ui,
    "native_stop" => :ui,
    "native_restart" => :ui,
    "submit_native" => :federate,
    "native_api_key_save" => :ui,
    "native_api_key_remove" => :ui,
    "native_recent_output" => :ui,
    "session_restart" => :ui,
    "session_restart_confirm" => :ui,
    "session_restart_cancel" => :ui
  }

  @impl true
  def handle_event(name, params, socket) do
    scope = Platform.Access.Scope.for_user(%{id: socket.assigns.current_user_id})
    socket = assign(socket, :access_scope, scope)

    permitted? =
      case Map.get(@event_policy, name) do
        :ui ->
          true

        :vault ->
          true

        :manage_selected ->
          agent = socket.assigns[:selected_agent]

          Platform.Access.Agents.manage?(scope, agent) and
            (not NativeAgents.managed?(agent) or
               NativeAgents.can_manage?(socket.assigns.current_user_id, agent))

        :federate ->
          Platform.Access.Agents.may_federate?(scope)

        :create_ownerless ->
          Platform.Access.Agents.may_create_ownerless?(scope)

        :responsibility ->
          Platform.Access.Agents.may_federate?(scope)

        nil ->
          require Logger
          Logger.warning("[ControlCenterLive] refused unknown event #{inspect(name)}")
          false
      end

    if permitted? do
      handle_control_event(name, params, socket)
    else
      message =
        if NativeAgents.managed?(socket.assigns[:selected_agent]),
          do: NativeAgentEvents.refused_message(),
          else: "You can only manage your own agents."

      {:noreply, put_flash(socket, :error, message)}
    end
  end

  # ── Roles panel events (M7 stage 5) ───────────────────────────────

  defp handle_control_event("switch_control_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :active_tab, normalize_tab(tab))}
  end

  defp handle_control_event("toggle_role_advanced", _params, socket) do
    {:noreply, assign(socket, :show_role_advanced, !socket.assigns.show_role_advanced)}
  end

  # Escape-hatch clause: the inline picker's sentinel value opens the
  # External Agent onboarding flow with the role_key pre-bound so the
  # form's role <select> renders that role pre-selected and the submit
  # handler picks it up (stage 6 wiring, reused here).
  defp handle_control_event(
         "assign_role",
         %{"role_key" => role_key, "agent_id" => "__new_external__"},
         socket
       ) do
    overrides = %{"role_key" => role_key}

    {:noreply,
     socket
     |> assign(:show_onboarding_chooser, true)
     |> assign(:onboarding_flow, :external)
     |> assign(:external_agent_form, AgentData.build_external_agent_form(overrides))
     |> assign(:probe_result, nil)}
  end

  # No-op: picker's "Choose an agent…" placeholder emits an empty
  # agent_id when the row first renders / on re-select of the default.
  defp handle_control_event("assign_role", %{"role_key" => _key, "agent_id" => ""}, socket) do
    {:noreply, socket}
  end

  # Normal clause: `agent_id` is a real UUID → pin the agent to the role.
  # `assign_role/2` is documented as no-replace (see roles.ex:142) — a
  # unique-constraint failure on `role_key` surfaces as a changeset
  # error and we translate it to a "clear first" flash.
  defp handle_control_event(
         "assign_role",
         %{"role_key" => role_key, "agent_id" => agent_id},
         socket
       )
       when is_binary(agent_id) and agent_id != "" do
    case Platform.Roles.assign_role(role_key, agent_id, actor: socket.assigns.access_scope) do
      {:ok, _assignment} ->
        {:noreply,
         socket
         |> assign_roles_panel()
         |> put_flash(:info, "Filled #{role_key}.")}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Role already filled — clear it before reassigning."
         )}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You can only manage your own agents.")}
    end
  end

  defp handle_control_event("clear_role_assignment", %{"role_key" => role_key}, socket) do
    case Platform.Roles.unassign_role(role_key, actor: socket.assigns.access_scope) do
      :ok ->
        {:noreply,
         socket
         |> assign_roles_panel()
         |> put_flash(:info, "Cleared assignment for #{role_key}.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You can only manage your own agents.")}
    end
  end

  defp handle_control_event(
         "set_responsibility_override",
         %{"responsibility_key" => key, "agent_id" => ""},
         socket
       ) do
    case Platform.Roles.clear_override(key, actor: socket.assigns.access_scope) do
      :ok ->
        {:noreply, assign_roles_panel(socket)}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You can only manage your own agents.")}
    end
  end

  defp handle_control_event(
         "set_responsibility_override",
         %{"responsibility_key" => key, "agent_id" => agent_id},
         socket
       )
       when is_binary(agent_id) and agent_id != "" do
    case Platform.Roles.set_override(key, agent_id, actor: socket.assigns.access_scope) do
      {:ok, _override} ->
        {:noreply,
         socket
         |> assign_roles_panel()
         |> put_flash(:info, "Override saved for #{key}.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You can only manage your own agents.")}

      {:error, changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not set override: #{changeset_error_summary(changeset)}"
         )}
    end
  end

  defp handle_control_event("clear_responsibility_override", %{"key" => key}, socket) do
    case Platform.Roles.clear_override(key, actor: socket.assigns.access_scope) do
      :ok ->
        {:noreply,
         socket
         |> assign_roles_panel()
         |> put_flash(:info, "Cleared override for #{key}.")}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "You can only manage your own agents.")}
    end
  end

  # ── Runtime events (kept here — tightly coupled to socket) ────────

  defp handle_control_event(
         "start_runtime",
         _params,
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    case AgentServer.start_agent(agent) do
      {:ok, pid} ->
        allow_runtime_sandbox(pid)

        {:noreply,
         socket
         |> put_flash(:info, "Started runtime for #{agent.name}.")
         |> reload_selected_agent()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start runtime: #{inspect(reason)}")}
    end
  end

  defp handle_control_event("start_runtime", _params, socket), do: {:noreply, socket}

  defp handle_control_event(
         "stop_runtime",
         _params,
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    case AgentServer.stop_agent(agent) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Stopped runtime for #{agent.name}.")
         |> reload_selected_agent()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not stop runtime: #{inspect(reason)}")}
    end
  end

  defp handle_control_event("stop_runtime", _params, socket), do: {:noreply, socket}

  defp handle_control_event(
         "refresh_runtime",
         _params,
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    case AgentServer.whereis(agent.id) do
      pid when is_pid(pid) ->
        allow_runtime_sandbox(pid)

        case AgentServer.refresh(agent.id) do
          {:ok, _agent} ->
            {:noreply,
             socket
             |> put_flash(:info, "Refreshed runtime for #{agent.name}.")
             |> reload_selected_agent()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not refresh runtime: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Runtime is not running.")}
    end
  end

  defp handle_control_event("refresh_runtime", _params, socket), do: {:noreply, socket}

  # ── Config save ───────────────────────────────────────────────────

  # `phx-change` on the config form is not decoration — `live_file_input`
  # only reports picked files through the enclosing form's change event, so
  # without this the avatar upload never registers an entry. Rebuilding the
  # form from the submitted params is what keeps the OTHER inputs from being
  # reverted to their assigned values on that re-render.
  defp handle_control_event(
         "validate_config",
         %{"config" => params},
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    {:noreply, assign(socket, :config_form, AgentData.build_config_form(agent, params))}
  end

  defp handle_control_event("validate_config", _params, socket), do: {:noreply, socket}

  defp handle_control_event(
         "save_config",
         %{"config" => params},
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    with_native_manager(socket, agent, fn -> save_config(socket, agent, params) end)
  end

  defp handle_control_event("save_config", _params, socket), do: {:noreply, socket}

  # Clears both columns and takes the blob with them, returning the agent to
  # the color-plus-initials fallback. Without this the fallback is
  # unreachable once an avatar is set, because an upload-only control has no
  # way to express "none".
  defp handle_control_event(
         "remove_avatar",
         params,
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    with_native_manager(socket, agent, fn -> remove_avatar(socket, agent, params) end)
  end

  defp handle_control_event("remove_avatar", _params, socket), do: {:noreply, socket}

  defp handle_control_event("cancel_avatar_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, AgentAvatarUpload.upload_name(), ref)}
  end

  defp handle_control_event("cancel_avatar_upload", _params, socket), do: {:noreply, socket}

  # ── Vault write events. Both re-check `@root_admin?` inside VaultEvents ──
  #
  # Delegated rather than inlined for the same reason every other panel's
  # events are: the gate, the scope decision and the reason the secret never
  # enters assigns are one argument, and they belong in one file.

  defp handle_control_event("toggle_credential_form", params, socket),
    do: VaultEvents.handle("toggle_credential_form", params, socket)

  defp handle_control_event("create_credential", params, socket),
    do: VaultEvents.handle("create_credential", params, socket)

  # ── Agent CRUD events (delegated) ────────────────────────────────

  defp handle_control_event("create_agent", params, socket),
    do: AgentCrudEvents.handle("create_agent", params, socket)

  defp handle_control_event("toggle_create_agent", params, socket),
    do: AgentCrudEvents.handle("toggle_create_agent", params, socket)

  defp handle_control_event("request_delete_agent", params, socket),
    do: AgentCrudEvents.handle("request_delete_agent", params, socket)

  defp handle_control_event("cancel_delete_agent", params, socket),
    do: AgentCrudEvents.handle("cancel_delete_agent", params, socket)

  defp handle_control_event("delete_agent", params, socket),
    do: AgentCrudEvents.handle("delete_agent", params, socket)

  # ── Workspace events (delegated) ─────────────────────────────────

  defp handle_control_event("select_workspace_file", params, socket),
    do: WorkspaceEvents.handle("select_workspace_file", params, socket)

  defp handle_control_event("new_workspace_file", params, socket),
    do: WorkspaceEvents.handle("new_workspace_file", params, socket)

  defp handle_control_event("save_workspace_file", params, socket),
    do: WorkspaceEvents.handle("save_workspace_file", params, socket)

  # ── Memory events (delegated) ────────────────────────────────────

  defp handle_control_event("filter_memories", params, socket),
    do: MemoryEvents.handle("filter_memories", params, socket)

  defp handle_control_event("append_memory", params, socket),
    do: MemoryEvents.handle("append_memory", params, socket)

  # ── Onboarding flow events (delegated) ────────────────────────────

  defp handle_control_event("open_onboarding_chooser", params, socket),
    do: OnboardingEvents.handle("open_onboarding_chooser", params, socket)

  defp handle_control_event("close_onboarding", params, socket),
    do: OnboardingEvents.handle("close_onboarding", params, socket)

  defp handle_control_event("choose_onboarding", params, socket),
    do: OnboardingEvents.handle("choose_onboarding", params, socket)

  defp handle_control_event("select_template", params, socket),
    do: OnboardingEvents.handle("select_template", params, socket)

  defp handle_control_event("back_to_templates", params, socket),
    do: OnboardingEvents.handle("back_to_templates", params, socket)

  defp handle_control_event("create_from_template", params, socket),
    do: OnboardingEvents.handle("create_from_template", params, socket)

  defp handle_control_event("submit_federate", params, socket),
    do: OnboardingEvents.handle("submit_federate", params, socket)

  defp handle_control_event("federate_done", params, socket),
    do: OnboardingEvents.handle("federate_done", params, socket)

  defp handle_control_event("toggle_import_agent", params, socket),
    do: OnboardingEvents.handle("toggle_import_agent", params, socket)

  defp handle_control_event("submit_import", params, socket),
    do: OnboardingEvents.handle("submit_import", params, socket)

  defp handle_control_event("external_agent_change", params, socket),
    do: OnboardingEvents.handle("external_agent_change", params, socket)

  defp handle_control_event("submit_external", params, socket),
    do: OnboardingEvents.handle("submit_external", params, socket)

  defp handle_control_event("set_vault_mode", params, socket),
    do: OnboardingEvents.handle("set_vault_mode", params, socket)

  # ── Native agents (delegated, task 01a10322 stage 4) ──────────────

  defp handle_control_event("native_start", params, socket),
    do: NativeAgentEvents.handle("native_start", params, socket)

  defp handle_control_event("native_stop", params, socket),
    do: NativeAgentEvents.handle("native_stop", params, socket)

  defp handle_control_event("native_restart", params, socket),
    do: NativeAgentEvents.handle("native_restart", params, socket)

  defp handle_control_event("submit_native", params, socket),
    do: NativeAgentEvents.handle("submit_native", params, socket)

  defp handle_control_event("native_api_key_save", params, socket),
    do: NativeAgentEvents.handle("native_api_key_save", params, socket)

  defp handle_control_event("native_api_key_remove", params, socket),
    do: NativeAgentEvents.handle("native_api_key_remove", params, socket)

  defp handle_control_event("native_recent_output", params, socket),
    do: NativeAgentEvents.handle("native_recent_output", params, socket)

  # Restart session (task 01a17b1c stage 5). `:ui` in the policy because
  # ConfigFiles.restart/3 is the gate, and audits a refusal.
  defp handle_control_event("session_restart", params, socket),
    do: Session.handle_event("session_restart", params, socket)

  defp handle_control_event("session_restart_confirm", params, socket),
    do: Session.handle_event("session_restart_confirm", params, socket)

  defp handle_control_event("session_restart_cancel", params, socket),
    do: Session.handle_event("session_restart_cancel", params, socket)

  # ── Runtime management events (delegated) ─────────────────────────

  defp handle_control_event("suspend_federated_runtime", params, socket),
    do: RuntimeEvents.handle("suspend_federated_runtime", params, socket)

  defp handle_control_event("unsuspend_federated_runtime", params, socket),
    do: RuntimeEvents.handle("unsuspend_federated_runtime", params, socket)

  defp handle_control_event("revoke_federated_runtime", params, socket),
    do: RuntimeEvents.handle("revoke_federated_runtime", params, socket)

  defp handle_control_event("regenerate_federated_token", params, socket),
    do: RuntimeEvents.handle("regenerate_federated_token", params, socket)

  defp handle_control_event("dismiss_regenerated_token", params, socket),
    do: RuntimeEvents.handle("dismiss_regenerated_token", params, socket)

  defp handle_control_event("save_tool_profile", params, socket),
    do: RuntimeEvents.handle("save_tool_profile", params, socket)

  defp handle_control_event("save_agent_restrictions", params, socket),
    do: RuntimeEvents.handle("save_agent_restrictions", params, socket)

  # ── Add agent to space ─────────────────────────────────────────────

  defp handle_control_event("show_add_space_modal", _params, socket) do
    spaces = Platform.Chat.list_spaces() |> Enum.filter(&(&1.kind != "dm"))
    {others, meetings} = Platform.Chat.MeetingSpaces.partition_for_picker(spaces)

    {:noreply,
     socket
     |> assign(:show_add_space_modal, true)
     |> assign(:available_spaces, others)
     |> assign(:available_meeting_spaces, meetings)}
  end

  defp handle_control_event("hide_add_space_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_space_modal, false)}
  end

  defp handle_control_event(
         "add_agent_to_space",
         %{"space_id" => space_id, "role" => role},
         %{assigns: %{selected_agent: %Agent{} = agent}} = socket
       ) do
    attention_mode = if role == "principal", do: "all", else: "mention"

    case Platform.Chat.add_agent_participant(space_id, agent, attention_mode: attention_mode) do
      {:ok, _participant} ->
        case Platform.Chat.ensure_space_agent(space_id, agent.id, role: role) do
          {:ok, _space_agent} ->
            spaces = Federation.agent_spaces(agent)

            {:noreply,
             socket
             |> assign(:federation_spaces, spaces)
             |> assign(:show_add_space_modal, false)
             |> put_flash(:info, "Agent added to space.")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not add agent to space roster: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not add agent to space: #{inspect(reason)}")}
    end
  end

  defp handle_control_event("add_agent_to_space", params, socket) do
    require Logger

    Logger.warning(
      "add_agent_to_space: unmatched — params=#{inspect(params)}, selected_agent=#{inspect(socket.assigns[:selected_agent])}"
    )

    {:noreply,
     put_flash(socket, :error, "Could not add agent to space: agent not selected or invalid.")}
  end

  # Any event this page does not handle is refused here, and only its NAME is
  # logged (task 01a10322 stage 6). Without this clause an unknown event
  # crashed the view, and the crash report printed the event's params
  # verbatim, `:filter_parameters` notwithstanding: a Claude login code sent
  # to a made-up "paste" event would have landed in the log. No event on this
  # page accepts a login code.
  defp handle_control_event(event, _params, socket) do
    require Logger
    Logger.warning("[ControlCenterLive] refused unknown event #{inspect(event)}")
    {:noreply, socket}
  end

  defp normalize_tab("roles"), do: :roles
  defp normalize_tab(_), do: :roles

  # ── Render ────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :role_templates, OnboardingEvents.role_templates())

    ~H"""
    <div class="flex h-full min-h-full flex-col overflow-hidden bg-base-100">
      <Onboarding.overlay
        show={@show_onboarding_chooser}
        onboarding_flow={@onboarding_flow}
        selected_template={@selected_template}
        template_form={@template_form}
        federate_form={@federate_form}
        federate_result={@federate_result}
        import_agents={@import_agents}
        import_selected={@import_selected}
        create_agent_form={@create_agent_form}
        external_agent_form={@external_agent_form}
        probe_result={@probe_result}
        role_templates={@role_templates}
        roles={@roles}
        role_assignments_by_key={@role_assignments_by_key}
        agent_host_connected?={@agent_host_connected?}
      />

      <%!-- ── Main content ───────────────────────────────────────────── --%>
      <div class="flex min-h-0 flex-1 flex-col overflow-hidden lg:flex-row">
        <%!-- ── Sidebar / agent list (hidden when agent selected on mobile) --%>
        <aside
          id="agent-directory"
          class={[
            "flex min-h-0 w-full flex-col overflow-hidden border-edge bg-base-200/60 lg:w-80 lg:flex-shrink-0 lg:border-r",
            @selected_agent && "hidden lg:flex"
          ]}
        >
          <div class="border-b border-edge px-4 py-4 sm:px-5">
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-widest text-base-content">
                  Agents
                </p>
                <p class="mt-1 text-sm text-base-content">
                  Manage, federate, and monitor your agents.
                </p>
              </div>
              <button
                id="add-agent-btn-sidebar"
                type="button"
                phx-click="open_onboarding_chooser"
                class="btn btn-primary btn-sm gap-1"
              >
                <span class="hero-plus h-4 w-4" /> Add
              </button>
            </div>
          </div>

          <nav
            id="agent-list"
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-3 sm:px-4 clears-tab-bar"
          >
            <AgentCard.card
              :for={agent <- @agents}
              agent={agent}
              selected_slug={@selected_agent && @selected_agent.slug}
              can_manage?={
                agent[:managed?] == true and
                  MapSet.member?(@manageable_agent_ids, agent.agent.id)
              }
            />

            <%!-- ── Empty state ─────────────────────────────────── --%>
            <div
              :if={@agents == []}
              class="flex flex-col items-center gap-6 px-4 py-10 text-center"
            >
              <div>
                <span class="hero-rectangle-stack mx-auto h-12 w-12 text-subtle" />
                <p class="mt-3 text-lg font-semibold text-base-content">Add your first agent</p>
                <p class="mt-1 text-sm text-subtle">
                  Choose a template, federate from OpenClaw, import from a workspace, or build from scratch.
                </p>
              </div>

              <div class="grid w-full max-w-sm grid-cols-2 gap-3">
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="template"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-edge bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-briefcase h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Template</span>
                </button>
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="federate"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-edge bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-globe-alt h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Federate</span>
                </button>
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="import"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-edge bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-arrow-down-tray h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Import</span>
                </button>
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="create"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-edge bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-wrench-screwdriver h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Custom</span>
                </button>
              </div>
            </div>
          </nav>
        </aside>

        <%!-- ── Main panel ─────────────────────────────────────────── --%>
        <main class={[
          "min-h-0 flex-1 overflow-y-auto",
          is_nil(@selected_agent) && "hidden lg:block"
        ]}>
          <%!-- Agent detail view --%>
          <div
            :if={@selected_agent}
            class="mx-auto flex max-w-7xl flex-col gap-6 px-4 py-4 sm:px-6 sm:py-6"
          >
            <AgentDetail.header
              agent={@selected_agent}
              can_manage?={Platform.Access.Agents.manage?(@access_scope, @selected_agent)}
              runtime={@runtime}
              federation_online?={@federation_online?}
              selected_agent_directory_entry={@selected_agent_directory_entry}
              pending_delete_slug={@pending_delete_slug}
              native={@native_header}
            />

            <AgentDetail.stats
              agent={@selected_agent}
              runtime={@runtime}
              federation_online?={@federation_online?}
              federation_runtime={@federation_runtime}
              federation_spaces={@federation_spaces}
              overview_counts={@overview_counts}
            />

            <div :if={@selected_agent.runtime_type == "external"} class="flex flex-col gap-6">
              <section
                :if={@config_entry?}
                id="agent-session"
                class="overflow-hidden rounded-3xl border border-edge bg-base-100"
              >
                <SessionStrip.strip :if={@session} id="agent-session-strip" session={@session} />
                <div class="flex flex-wrap items-center justify-between gap-3 px-4 py-3">
                  <span class="text-sm text-base-content">
                    Instructions, skills, settings and MCP servers
                  </span>
                  <.link
                    id="open-agent-config"
                    navigate={~p"/control/#{@selected_agent.slug}/config"}
                    class="btn btn-sm btn-ghost border border-subtle"
                  >
                    Configuration
                  </.link>
                </div>
              </section>

              <AgentDetail.federation_panels
                agent={@selected_agent}
                config_form={@config_form}
                uploads={@uploads}
                regenerated_token={@regenerated_token}
                federation_online?={@federation_online?}
                federation_spaces={@federation_spaces}
                show_add_space_modal={@show_add_space_modal}
                available_spaces={@available_spaces}
                available_meeting_spaces={@available_meeting_spaces}
                current_user_id={@current_user_id}
                managed?={not is_nil(@native_header)}
                can_manage?={
                  Platform.Access.Agents.manage?(@access_scope, @selected_agent) and
                    (is_nil(@native_header) or @native_header.can_manage?)
                }
              />

              <%!-- Login steps (stage 6) replace the files area while the agent
                   waits for a login. --%>
              <NativeLoginPanel.panel
                :if={@native_header && @native_header.view.state == :needs_login}
                agent={@selected_agent}
                can_manage?={@native_header.can_manage?}
                key_set?={@native_header.key_set?}
                step={@native_header.login_step}
                mode={@native_header.login_mode}
              />

              <NativeFiles.summary
                :if={@native_header && @native_header.view.state != :needs_login}
                agent={@selected_agent}
                can_manage?={@native_header.can_manage?}
                workspace_files={@workspace_files}
              />

              <NativeLoginPanel.summary
                :if={
                  @native_header && @native_header.view.state != :needs_login &&
                    @native_header.harness == "claude_code"
                }
                agent={@selected_agent}
                can_manage?={@native_header.can_manage?}
                key_set?={@native_header.key_set?}
                step={@native_header.login_step}
                mode={@native_header.login_mode}
              />

              <NativeLoginPanel.logs
                :if={@native_header && @native_header.can_manage?}
                agent={@selected_agent}
                output={recent_output_for(@native_recent_output, @selected_agent)}
              />
            </div>

            <%!-- Config + model routing (built-in agents only) --%>
            <div
              :if={
                @selected_agent.runtime_type != "external" and
                  Platform.Access.Agents.manage?(@access_scope, @selected_agent)
              }
              class="grid gap-6 xl:grid-cols-[minmax(0,1.6fr)_minmax(320px,0.9fr)]"
            >
              <div class="flex min-w-0 flex-col gap-6">
                <AgentDetail.config_form
                  agent={@selected_agent}
                  config_form={@config_form}
                  uploads={@uploads}
                  model_chain_result={@model_chain_result}
                  selected_agent_directory_entry={@selected_agent_directory_entry}
                />

                <AgentDetail.workspace_editor
                  workspace_files={@workspace_files}
                  selected_file_key={@selected_file_key}
                  selected_workspace_file={@selected_workspace_file}
                  workspace_form={@workspace_form}
                />

                <AgentDetail.memory_browser
                  memory_filter_form={@memory_filter_form}
                  recent_memories={@recent_memories}
                  memory_form={@memory_form}
                />
              </div>

              <div class="flex min-w-0 flex-col gap-6">
                <AgentDetail.runtime_monitor
                  runtime={@runtime}
                  recent_sessions={@recent_sessions}
                />

                <AgentDetail.vault_panel
                  agent_credentials={@agent_credentials}
                  platform_credentials={@platform_credentials}
                  all_platform_credentials={@all_platform_credentials}
                  root_admin?={@root_admin?}
                  show_credential_form={@show_credential_form}
                  credential_form={@credential_form}
                />
              </div>
            </div>
          </div>

          <%!-- No agent selected → Roles panel (M7 stage 5 + 6 advanced) --%>
          <RolesPanel.panel
            :if={is_nil(@selected_agent) and @active_tab == :roles}
            roles={@roles}
            role_bundles={@role_bundles}
            role_assignments_by_key={@role_assignments_by_key}
            show_role_advanced={@show_role_advanced}
            responsibility_rows={@responsibility_rows}
            selectable_agents={@selectable_agents}
            access_scope={@access_scope}
          />
        </main>
      </div>

      <%!-- Floating add button (mobile, when agents exist and no agent selected) --%>
      <button
        :if={@agents != [] && is_nil(@selected_agent) && !@show_onboarding_chooser}
        type="button"
        phx-click="open_onboarding_chooser"
        class="fixed bottom-[calc(env(safe-area-inset-bottom)+1.5rem+var(--bottom-nav-height,0px))] right-6 z-40 btn btn-primary btn-circle shadow-lg lg:hidden"
      >
        <span class="hero-plus h-6 w-6" />
      </button>
    </div>
    """
  end

  # ── Private: panel assignment ─────────────────────────────────────

  defp assign_roles_panel(socket) do
    socket
    |> assign(:roles, AgentData.list_roles())
    |> assign(:role_bundles, AgentData.role_bundles())
    |> assign(:role_assignments_by_key, AgentData.role_assignments_by_key())
    |> assign(:responsibility_rows, AgentData.responsibility_rows())
    |> assign(
      :selectable_agents,
      Enum.filter(
        AgentData.list_selectable_agents(),
        &Platform.Access.Agents.may_assign?(socket.assigns[:access_scope], &1)
      )
    )
  end

  defp assign_empty_panel(socket) do
    socket
    |> assign(:page_title, "Agents")
    |> assign(:selected_agent, nil)
    |> assign(:runtime, %{status: :unknown, running?: false, pid: nil, active_session_ids: []})
    |> assign(:overview_counts, %{workspace_files: 0, memories: 0, sessions: 0, vault: 0})
    |> assign(:model_chain_result, {:error, :no_agent_selected})
    |> assign(:workspace_files, [])
    |> assign(:selected_workspace_file, nil)
    |> assign(:selected_file_key, nil)
    |> assign(:workspace_form, to_form(%{"file_key" => "", "content" => ""}, as: :workspace_file))
    |> NativeAgentEvents.reset()
    |> Session.init(nil, nil, :none)
    |> assign(:config_entry?, false)
    |> assign(:memory_filters, AgentData.default_memory_filters())
    |> assign(
      :memory_filter_form,
      to_form(AgentData.default_memory_filters(), as: :memory_filters)
    )
    |> assign(:recent_memories, [])
    |> assign(:recent_sessions, [])
    |> assign(:agent_credentials, [])
    |> assign(:platform_credentials, [])
    |> assign(:config_form, to_form(%{}, as: :config))
    |> assign(
      :create_agent_form,
      to_form(AgentData.default_create_agent_params(), as: :create_agent)
    )
    |> assign(:show_create_agent, socket.assigns[:show_create_agent] || false)
    |> assign(:pending_delete_slug, nil)
    |> assign(:memory_form, to_form(AgentData.default_memory_entry(), as: :memory_entry))
    |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
    |> assign(:selected_agent_directory_entry, nil)
    |> assign(:regenerated_token, nil)
    |> assign(:federation_runtime, nil)
    |> assign(:federation_online?, false)
    |> assign(:federation_spaces, [])
    |> assign(:show_add_space_modal, false)
    |> assign(:available_spaces, [])
    |> assign(:available_meeting_spaces, [])
    |> assign_roles_panel()
    |> assign_native()
  end

  defp assign_agent_panel(socket, %Agent{} = agent, opts) do
    memory_filters =
      AgentData.normalize_memory_filters(
        Keyword.get(
          opts,
          :memory_filters,
          socket.assigns[:memory_filters] || AgentData.default_memory_filters()
        )
      )

    workspace_files = MemoryContext.list_workspace_files(agent.id)

    selected_workspace_file =
      AgentData.select_workspace_file(
        workspace_files,
        Keyword.get(opts, :selected_file_key) || socket.assigns[:selected_file_key]
      )

    agent_credentials = Platform.Vault.list(scope: {:agent, agent.id})
    platform_credentials = AgentData.relevant_platform_credentials(agent)
    # Unfiltered, unlike `platform_credentials` above, which drops anything
    # whose provider is outside this agent's model chain. The admin write
    # surface needs to show what actually exists in the vault, or a credential
    # created for a provider this agent does not use reads as a failed write.
    all_platform_credentials = Platform.Vault.list(scope: {:platform, nil})
    runtime = AgentData.runtime_snapshot(agent)

    socket
    |> assign(:page_title, "Agents · #{agent.name}")
    |> assign(:selected_agent, agent)
    |> assign(:runtime, runtime)
    |> assign(:overview_counts, %{
      workspace_files: length(workspace_files),
      memories: AgentData.count_memories(agent.id),
      sessions: AgentData.count_sessions(agent.id),
      vault: length(agent_credentials) + length(platform_credentials)
    })
    |> assign(:model_chain_result, Config.model_chain(agent))
    |> assign(:workspace_files, workspace_files)
    |> assign(:selected_workspace_file, selected_workspace_file)
    |> assign(:selected_file_key, selected_workspace_file && selected_workspace_file.file_key)
    |> assign(
      :workspace_form,
      AgentData.build_workspace_form(
        workspace_files,
        selected_workspace_file,
        Keyword.get(opts, :workspace_params, %{})
      )
    )
    |> assign(:memory_filters, memory_filters)
    |> assign(:memory_filter_form, to_form(memory_filters, as: :memory_filters))
    |> assign(:recent_memories, AgentData.list_filtered_memories(agent.id, memory_filters))
    |> assign(:recent_sessions, AgentData.list_recent_sessions(agent.id))
    |> assign(:agent_credentials, agent_credentials)
    |> assign(:platform_credentials, platform_credentials)
    |> assign(:all_platform_credentials, all_platform_credentials)
    |> assign(
      :config_form,
      AgentData.build_config_form(agent, Keyword.get(opts, :config_params, %{}))
    )
    |> assign(
      :selected_agent_directory_entry,
      AgentData.find_agent_directory_entry(socket.assigns.agents, agent.slug)
    )
    |> assign(:pending_delete_slug, pending_delete_slug(socket, agent.slug))
    |> assign(:memory_form, AgentData.build_memory_form(Keyword.get(opts, :memory_params)))
    |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
    |> assign_federation_data(agent)
    |> assign_native()
    |> assign_session_strip(agent)
  end

  # The standalone Restart session strip and the Configuration entry (task
  # 01a17b1c stage 5), behind ConfigFiles' own gate. An owner whose agent
  # cannot be configured right now (opt-in off, CLI too old, offline) still
  # gets the entry: the screen says why in one line.
  defp assign_session_strip(socket, %Agent{runtime_type: "external"} = agent) do
    actor = %{id: socket.assigns.current_user_id}
    described = Platform.Agents.ConfigFiles.describe(actor, agent)

    socket
    |> Session.init(actor, agent, described)
    |> assign(:config_entry?, described != {:error, :forbidden})
  end

  defp assign_session_strip(socket, _agent),
    do: socket |> Session.init(nil, nil, :none) |> assign(:config_entry?, false)

  defp assign_federation_data(socket, %Agent{runtime_type: "external"} = agent) do
    runtime = Federation.get_runtime_for_agent(agent)
    online? = runtime != nil && RuntimePresence.online?(runtime.runtime_id)
    spaces = Federation.agent_spaces(agent)

    socket
    |> assign(:federation_runtime, runtime)
    |> assign(:federation_online?, online?)
    |> assign(:federation_spaces, spaces)
  end

  defp assign_federation_data(socket, _agent) do
    socket
    |> assign(:federation_runtime, nil)
    |> assign(:federation_online?, false)
    |> assign(:federation_spaces, [])
  end

  def reload_selected_agent(socket, opts \\ [])

  def reload_selected_agent(%{assigns: %{selected_agent: %Agent{} = agent}} = socket, opts) do
    refreshed_agent = Repo.get!(Agent, agent.id)
    agents = AgentData.list_agents()

    socket
    |> assign(:agents, agents)
    |> assign(:selected_agent, refreshed_agent)
    |> assign(
      :selected_agent_directory_entry,
      AgentData.find_agent_directory_entry(agents, refreshed_agent.slug)
    )
    |> assign_agent_panel(refreshed_agent, opts)
  end

  def reload_selected_agent(socket, _opts), do: socket

  # ── Private: small helpers ────────────────────────────────────────

  defp pending_delete_slug(socket, selected_slug) do
    case socket.assigns[:pending_delete_slug] do
      ^selected_slug -> selected_slug
      _ -> nil
    end
  end

  defp save_config_with_avatar(socket, %Agent{} = agent, params, avatar_attrs) do
    previous_key = agent.avatar_storage_key

    attrs =
      agent
      |> AgentData.config_attrs_from_params(params)
      |> Map.merge(avatar_attrs)

    case agent |> Agent.changeset(attrs) |> Repo.update() do
      {:ok, updated_agent} ->
        # The row now points at the new key, so the old blob is
        # unreachable — delete it rather than leak it. This is the whole
        # reason stage 1 added `avatar_storage_key`.
        maybe_delete_superseded_avatar(previous_key, avatar_attrs)
        refresh_runtime_if_running(updated_agent)

        {:noreply,
         socket
         |> put_flash(:info, "Updated #{updated_agent.name}.")
         |> assign(:agents, AgentData.list_agents())
         |> assign(:selected_agent, updated_agent)
         |> assign_agent_panel(updated_agent,
           selected_file_key: socket.assigns.selected_file_key,
           memory_filters: socket.assigns.memory_filters,
           config_params: params
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Nothing committed, so the blob we just wrote is the orphan now.
        AgentAvatarUpload.delete_blob(avatar_attrs[:avatar_storage_key])

        {:noreply, reject_config_save(socket, agent, params, changeset_error_summary(changeset))}
    end
  end

  defp reject_config_save(socket, %Agent{} = agent, params, message) do
    socket
    |> assign(:config_form, AgentData.build_config_form(agent, params))
    |> put_flash(:error, message)
  end

  defp maybe_delete_superseded_avatar(previous_key, %{avatar_storage_key: new_key})
       when previous_key != new_key do
    AgentAvatarUpload.delete_blob(previous_key)
  end

  defp maybe_delete_superseded_avatar(_previous_key, _avatar_attrs), do: :ok

  defp refresh_runtime_if_running(%Agent{} = agent) do
    case AgentServer.whereis(agent.id) do
      pid when is_pid(pid) ->
        allow_runtime_sandbox(pid)
        _ = AgentServer.refresh(agent.id)
        :ok

      nil ->
        :ok
    end
  end

  defp allow_runtime_sandbox(pid) when is_pid(pid) do
    if sandbox_pool?() do
      case Sandbox.allow(Repo, self(), pid) do
        :ok -> :ok
        {:already, :owner} -> :ok
        {:already, :allowed} -> :ok
        _other -> :ok
      end
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  defp sandbox_pool? do
    case Repo.config()[:pool] do
      Sandbox -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp agent_changed?(
         %{assigns: %{selected_agent: %Agent{} = current}},
         %Agent{} = selected_agent
       ),
       do: current.id != selected_agent.id

  defp agent_changed?(_socket, _selected_agent), do: true

  # ── Native-agent gates for the identity form (stage 6) ────────────

  defp save_config(socket, agent, params) do
    case AgentAvatarUpload.consume(socket, agent) do
      {:ok, avatar_attrs} -> save_config_with_avatar(socket, agent, params, avatar_attrs)
      {:error, message} -> {:noreply, reject_config_save(socket, agent, params, message)}
    end
  end

  # A native agent's identity, voice and runtime are the install's to change
  # (stage 6): only its owner or an admin may. The form is rendered read-only
  # for everyone else, but that is an affordance; this is the check.
  defp with_native_manager(socket, agent, fun) do
    if NativeAgents.managed?(agent) and
         not NativeAgents.can_manage?(socket.assigns.current_user_id, agent) do
      {:noreply, put_flash(socket, :error, NativeAgentEvents.refused_message())}
    else
      fun.()
    end
  end

  defp remove_avatar(socket, agent, _params) do
    previous_key = agent.avatar_storage_key

    case agent
         |> Agent.changeset(%{avatar_url: nil, avatar_storage_key: nil})
         |> Repo.update() do
      {:ok, updated_agent} ->
        # Only after the row no longer points at it. The reverse order can
        # delete the bytes and then fail to commit, leaving a live row
        # pointing at nothing.
        AgentAvatarUpload.delete_blob(previous_key)

        {:noreply,
         socket
         |> put_flash(:info, "Removed the avatar for #{updated_agent.name}.")
         |> assign(:agents, AgentData.list_agents())
         |> assign(:selected_agent, updated_agent)
         |> assign_agent_panel(updated_agent,
           selected_file_key: socket.assigns.selected_file_key,
           memory_filters: socket.assigns.memory_filters,
           # Remove is its own button, not a save. Carrying the current
           # params forward keeps any unsaved edit to name/model/etc. from
           # being silently reverted by the panel rebuild.
           config_params: socket.assigns.config_form.params
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error_summary(changeset))}
    end
  end
end
