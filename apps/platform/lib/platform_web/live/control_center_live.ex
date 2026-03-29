defmodule PlatformWeb.ControlCenterLive do
  use PlatformWeb, :live_view

  alias Ecto.Adapters.SQL.Sandbox

  alias Platform.Agents.{
    Agent,
    AgentServer,
    MemoryContext,
    Router
  }

  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  alias PlatformWeb.ControlCenter.AgentCard
  alias PlatformWeb.ControlCenter.AgentCrudEvents
  alias PlatformWeb.ControlCenter.AgentData
  alias PlatformWeb.ControlCenter.AgentDetail
  alias PlatformWeb.ControlCenter.MemoryEvents
  alias PlatformWeb.ControlCenter.Onboarding
  alias PlatformWeb.ControlCenter.OnboardingEvents
  alias PlatformWeb.ControlCenter.RuntimeEvents
  alias PlatformWeb.ControlCenter.WorkspaceEvents

  import PlatformWeb.ControlCenter.Helpers

  @impl true
  def mount(_params, session, socket) do
    current_user_id = session["current_user_id"]

    {:ok,
     socket
     |> assign(:page_title, "Agent Resources")
     |> assign(:current_user_id, current_user_id)
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
     |> assign(:regenerated_token, nil)
     |> assign(:show_add_space_modal, false)
     |> assign(:available_spaces, [])}
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

    {:noreply,
     if selected_agent do
       assign_agent_panel(socket, selected_agent,
         selected_file_key: params["file"] || socket.assigns[:selected_file_key],
         reset_forms?: agent_changed?(socket, selected_agent)
       )
     else
       assign_empty_panel(socket)
     end}
  end

  # ── Runtime events (kept here — tightly coupled to socket) ────────

  @impl true
  def handle_event(
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

  def handle_event("start_runtime", _params, socket), do: {:noreply, socket}

  def handle_event(
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

  def handle_event("stop_runtime", _params, socket), do: {:noreply, socket}

  def handle_event(
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

  def handle_event("refresh_runtime", _params, socket), do: {:noreply, socket}

  # ── Config save ───────────────────────────────────────────────────

  def handle_event(
        "save_config",
        %{"config" => params},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    attrs = AgentData.config_attrs_from_params(agent, params)

    case agent |> Agent.changeset(attrs) |> Repo.update() do
      {:ok, updated_agent} ->
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
        {:noreply,
         socket
         |> assign(:config_form, AgentData.build_config_form(agent, params))
         |> put_flash(:error, changeset_error_summary(changeset))}
    end
  end

  def handle_event("save_config", _params, socket), do: {:noreply, socket}

  # ── Agent CRUD events (delegated) ────────────────────────────────

  def handle_event("create_agent", params, socket),
    do: AgentCrudEvents.handle("create_agent", params, socket)

  def handle_event("toggle_create_agent", params, socket),
    do: AgentCrudEvents.handle("toggle_create_agent", params, socket)

  def handle_event("request_delete_agent", params, socket),
    do: AgentCrudEvents.handle("request_delete_agent", params, socket)

  def handle_event("cancel_delete_agent", params, socket),
    do: AgentCrudEvents.handle("cancel_delete_agent", params, socket)

  def handle_event("delete_agent", params, socket),
    do: AgentCrudEvents.handle("delete_agent", params, socket)

  # ── Workspace events (delegated) ─────────────────────────────────

  def handle_event("select_workspace_file", params, socket),
    do: WorkspaceEvents.handle("select_workspace_file", params, socket)

  def handle_event("new_workspace_file", params, socket),
    do: WorkspaceEvents.handle("new_workspace_file", params, socket)

  def handle_event("save_workspace_file", params, socket),
    do: WorkspaceEvents.handle("save_workspace_file", params, socket)

  # ── Memory events (delegated) ────────────────────────────────────

  def handle_event("filter_memories", params, socket),
    do: MemoryEvents.handle("filter_memories", params, socket)

  def handle_event("append_memory", params, socket),
    do: MemoryEvents.handle("append_memory", params, socket)

  # ── Onboarding flow events (delegated) ────────────────────────────

  def handle_event("open_onboarding_chooser", params, socket),
    do: OnboardingEvents.handle("open_onboarding_chooser", params, socket)

  def handle_event("close_onboarding", params, socket),
    do: OnboardingEvents.handle("close_onboarding", params, socket)

  def handle_event("choose_onboarding", params, socket),
    do: OnboardingEvents.handle("choose_onboarding", params, socket)

  def handle_event("select_template", params, socket),
    do: OnboardingEvents.handle("select_template", params, socket)

  def handle_event("back_to_templates", params, socket),
    do: OnboardingEvents.handle("back_to_templates", params, socket)

  def handle_event("create_from_template", params, socket),
    do: OnboardingEvents.handle("create_from_template", params, socket)

  def handle_event("submit_federate", params, socket),
    do: OnboardingEvents.handle("submit_federate", params, socket)

  def handle_event("federate_done", params, socket),
    do: OnboardingEvents.handle("federate_done", params, socket)

  def handle_event("toggle_import_agent", params, socket),
    do: OnboardingEvents.handle("toggle_import_agent", params, socket)

  def handle_event("submit_import", params, socket),
    do: OnboardingEvents.handle("submit_import", params, socket)

  # ── Runtime management events (delegated) ─────────────────────────

  def handle_event("suspend_federated_runtime", params, socket),
    do: RuntimeEvents.handle("suspend_federated_runtime", params, socket)

  def handle_event("revoke_federated_runtime", params, socket),
    do: RuntimeEvents.handle("revoke_federated_runtime", params, socket)

  def handle_event("regenerate_federated_token", params, socket),
    do: RuntimeEvents.handle("regenerate_federated_token", params, socket)

  def handle_event("dismiss_regenerated_token", params, socket),
    do: RuntimeEvents.handle("dismiss_regenerated_token", params, socket)

  # ── Add agent to space ─────────────────────────────────────────────

  def handle_event("show_add_space_modal", _params, socket) do
    spaces = Platform.Chat.list_spaces() |> Enum.filter(&(&1.kind != "dm"))

    {:noreply,
     socket
     |> assign(:show_add_space_modal, true)
     |> assign(:available_spaces, spaces)}
  end

  def handle_event("hide_add_space_modal", _params, socket) do
    {:noreply, assign(socket, :show_add_space_modal, false)}
  end

  def handle_event(
        "add_agent_to_space",
        %{"space_id" => space_id, "role" => role},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    case Platform.Chat.add_space_agent(space_id, agent.id, role: role) do
      {:ok, _} ->
        spaces = Federation.agent_spaces(agent)

        {:noreply,
         socket
         |> assign(:federation_spaces, spaces)
         |> assign(:show_add_space_modal, false)
         |> put_flash(:info, "Agent added to space.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not add agent to space.")}
    end
  end

  def handle_event("add_agent_to_space", _params, socket), do: {:noreply, socket}

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
        role_templates={@role_templates}
      />

      <%!-- ── Main content ───────────────────────────────────────────── --%>
      <div class="flex min-h-0 flex-1 flex-col overflow-hidden lg:flex-row">
        <%!-- ── Sidebar / agent list (hidden when agent selected on mobile) --%>
        <aside
          id="agent-directory"
          class={[
            "flex min-h-0 w-full flex-col overflow-hidden border-base-300 bg-base-200/60 lg:w-80 lg:flex-shrink-0 lg:border-r",
            @selected_agent && "hidden lg:flex"
          ]}
        >
          <div class="border-b border-base-300 px-4 py-4 sm:px-5">
            <div class="flex items-start justify-between gap-3">
              <div>
                <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                  Agent Resources
                </p>
                <p class="mt-1 text-sm text-base-content/70">
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
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-3 py-3 sm:px-4"
          >
            <AgentCard.card
              :for={agent <- @agents}
              agent={agent}
              selected_slug={@selected_agent && @selected_agent.slug}
            />

            <%!-- ── Empty state ─────────────────────────────────── --%>
            <div
              :if={@agents == []}
              class="flex flex-col items-center gap-6 px-4 py-10 text-center"
            >
              <div>
                <span class="hero-rectangle-stack mx-auto h-12 w-12 text-base-content/25" />
                <p class="mt-3 text-lg font-semibold text-base-content">Add your first agent</p>
                <p class="mt-1 text-sm text-base-content/55">
                  Choose a template, federate from OpenClaw, import from a workspace, or build from scratch.
                </p>
              </div>

              <div class="grid w-full max-w-sm grid-cols-2 gap-3">
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="template"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-base-300 bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-briefcase h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Template</span>
                </button>
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="federate"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-base-300 bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-globe-alt h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Federate</span>
                </button>
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="import"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-base-300 bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
                >
                  <span class="hero-arrow-down-tray h-6 w-6 text-primary" />
                  <span class="text-xs font-semibold">Import</span>
                </button>
                <button
                  type="button"
                  phx-click="choose_onboarding"
                  phx-value-flow="create"
                  class="flex flex-col items-center gap-2 rounded-2xl border border-base-300 bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
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
              runtime={@runtime}
              federation_online?={@federation_online?}
              selected_agent_directory_entry={@selected_agent_directory_entry}
              pending_delete_slug={@pending_delete_slug}
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
              <AgentDetail.federation_panels
                agent={@selected_agent}
                config_form={@config_form}
                regenerated_token={@regenerated_token}
                federation_online?={@federation_online?}
                federation_spaces={@federation_spaces}
                show_add_space_modal={@show_add_space_modal}
                available_spaces={@available_spaces}
              />
            </div>

            <%!-- Config + model routing (built-in agents only) --%>
            <div
              :if={@selected_agent.runtime_type != "external"}
              class="grid gap-6 xl:grid-cols-[minmax(0,1.6fr)_minmax(320px,0.9fr)]"
            >
              <div class="flex min-w-0 flex-col gap-6">
                <AgentDetail.config_form
                  agent={@selected_agent}
                  config_form={@config_form}
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
                />
              </div>
            </div>
          </div>

          <%!-- No agent selected (desktop placeholder) --%>
          <div
            :if={is_nil(@selected_agent)}
            class="mx-auto flex h-full max-w-3xl items-center justify-center px-6 py-12"
          >
            <div class="flex flex-col items-center gap-4 text-center">
              <span class="hero-rectangle-stack h-12 w-12 text-base-content/20" />
              <p class="text-xl font-semibold text-base-content">Agent Resources</p>
              <p class="text-sm text-base-content/60">
                Select an agent from the sidebar, or add a new one to get started.
              </p>
              <button
                type="button"
                phx-click="open_onboarding_chooser"
                class="btn btn-primary btn-sm gap-1"
              >
                <span class="hero-plus h-4 w-4" /> Add Agent
              </button>
            </div>
          </div>
        </main>
      </div>

      <%!-- Floating add button (mobile, when agents exist and no agent selected) --%>
      <button
        :if={@agents != [] && is_nil(@selected_agent) && !@show_onboarding_chooser}
        type="button"
        phx-click="open_onboarding_chooser"
        class="fixed bottom-6 right-6 z-40 btn btn-primary btn-circle shadow-lg lg:hidden"
      >
        <span class="hero-plus h-6 w-6" />
      </button>
    </div>
    """
  end

  # ── Private: panel assignment ─────────────────────────────────────

  defp assign_empty_panel(socket) do
    socket
    |> assign(:page_title, "Agent Resources")
    |> assign(:selected_agent, nil)
    |> assign(:runtime, %{status: :unknown, running?: false, pid: nil, active_session_ids: []})
    |> assign(:overview_counts, %{workspace_files: 0, memories: 0, sessions: 0, vault: 0})
    |> assign(:model_chain_result, {:error, :no_agent_selected})
    |> assign(:workspace_files, [])
    |> assign(:selected_workspace_file, nil)
    |> assign(:selected_file_key, nil)
    |> assign(:workspace_form, to_form(%{"file_key" => "", "content" => ""}, as: :workspace_file))
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
    runtime = AgentData.runtime_snapshot(agent)

    socket
    |> assign(:page_title, "Control Center · #{agent.name}")
    |> assign(:selected_agent, agent)
    |> assign(:runtime, runtime)
    |> assign(:overview_counts, %{
      workspace_files: length(workspace_files),
      memories: AgentData.count_memories(agent.id),
      sessions: AgentData.count_sessions(agent.id),
      vault: length(agent_credentials) + length(platform_credentials)
    })
    |> assign(:model_chain_result, Router.model_chain(agent))
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
  end

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
end
