defmodule PlatformWeb.ControlCenterLive do
  use PlatformWeb, :live_view

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Multi

  alias Platform.Agents.{
    Agent,
    AgentServer,
    ContextShare,
    Memory,
    MemoryContext,
    Router,
    Session,
    WorkspaceBootstrap,
    WorkspaceFile
  }

  alias Platform.Federation
  alias Platform.Federation.RuntimePresence
  alias Platform.Repo

  alias PlatformWeb.ControlCenter.AgentCard
  alias PlatformWeb.ControlCenter.Onboarding
  alias PlatformWeb.ControlCenter.OnboardingEvents
  alias PlatformWeb.ControlCenter.RuntimeEvents
  alias PlatformWeb.ControlCenter.RuntimePanel

  import PlatformWeb.ControlCenter.Helpers

  @session_limit 8
  @memory_limit 12
  @workspace_defaults [
    "SOUL.md",
    "IDENTITY.md",
    "USER.md",
    "AGENTS.md",
    "MEMORY.md",
    "TOOLS.md",
    "HEARTBEAT.md"
  ]

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
     |> assign(:memory_filters, default_memory_filters())
     |> assign(:memory_filter_form, to_form(default_memory_filters(), as: :memory_filters))
     |> assign(:recent_memories, [])
     |> assign(:recent_sessions, [])
     |> assign(:agent_credentials, [])
     |> assign(:platform_credentials, [])
     |> assign(:config_form, to_form(%{}, as: :config))
     |> assign(:create_agent_form, to_form(default_create_agent_params(), as: :create_agent))
     |> assign(:show_create_agent, false)
     |> assign(:pending_delete_slug, nil)
     |> assign(:memory_form, to_form(default_memory_entry(), as: :memory_entry))
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
     |> assign(:regenerated_token, nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    agents = list_agents()
    selected_slug = resolve_selected_agent_slug(params["agent_slug"], agents)
    selected_agent = selected_slug && ensure_selected_agent(selected_slug, agents)
    agents = list_agents()
    selected_agent = selected_agent && Repo.get(Agent, selected_agent.id)
    selected_entry = selected_agent && find_agent_directory_entry(agents, selected_agent.slug)

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

  def handle_event(
        "save_config",
        %{"config" => params},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    attrs = config_attrs_from_params(agent, params)

    case agent |> Agent.changeset(attrs) |> Repo.update() do
      {:ok, updated_agent} ->
        refresh_runtime_if_running(updated_agent)

        {:noreply,
         socket
         |> put_flash(:info, "Updated #{updated_agent.name}.")
         |> assign(:agents, list_agents())
         |> assign(:selected_agent, updated_agent)
         |> assign_agent_panel(updated_agent,
           selected_file_key: socket.assigns.selected_file_key,
           memory_filters: socket.assigns.memory_filters,
           config_params: params
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:config_form, build_config_form(agent, params))
         |> put_flash(:error, changeset_error_summary(changeset))}
    end
  end

  def handle_event("save_config", _params, socket), do: {:noreply, socket}

  def handle_event("create_agent", %{"create_agent" => params}, socket) do
    attrs = create_agent_attrs_from_params(params)

    case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
      {:ok, agent} ->
        {:noreply,
         socket
         |> put_flash(:info, "Created #{agent.name}.")
         |> assign(:show_create_agent, false)
         |> assign(:create_agent_form, to_form(default_create_agent_params(), as: :create_agent))
         |> push_patch(to: ~p"/control/#{agent.slug}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:create_agent_form, build_create_agent_form(params))
         |> put_flash(:error, changeset_error_summary(changeset))}
    end
  end

  def handle_event("create_agent", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_create_agent", _params, socket) do
    {:noreply, assign(socket, :show_create_agent, !socket.assigns.show_create_agent)}
  end

  # ── Onboarding flow events (delegated) ──────────────────────────────

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

  # ── Runtime management events (delegated) ──────────────────────────

  def handle_event("suspend_federated_runtime", params, socket),
    do: RuntimeEvents.handle("suspend_federated_runtime", params, socket)

  def handle_event("revoke_federated_runtime", params, socket),
    do: RuntimeEvents.handle("revoke_federated_runtime", params, socket)

  def handle_event("regenerate_federated_token", params, socket),
    do: RuntimeEvents.handle("regenerate_federated_token", params, socket)

  def handle_event("dismiss_regenerated_token", params, socket),
    do: RuntimeEvents.handle("dismiss_regenerated_token", params, socket)

  def handle_event("request_delete_agent", %{"slug" => slug}, socket) when is_binary(slug) do
    case find_agent_directory_entry(socket.assigns.agents, slug) do
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

  def handle_event(
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

  def handle_event("request_delete_agent", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_delete_agent", _params, socket) do
    {:noreply, assign(socket, :pending_delete_slug, nil)}
  end

  def handle_event("delete_agent", %{"slug" => slug}, socket) when is_binary(slug) do
    case {socket.assigns.pending_delete_slug,
          find_agent_directory_entry(socket.assigns.agents, slug)} do
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

  def handle_event(
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

  def handle_event("delete_agent", _params, socket), do: {:noreply, socket}

  def handle_event("select_workspace_file", %{"file_key" => file_key}, socket) do
    {:noreply,
     reload_selected_agent(socket,
       selected_file_key: file_key,
       memory_filters: socket.assigns.memory_filters
     )}
  end

  def handle_event(
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
       build_workspace_form(workspace_files, nil, %{
         "file_key" => next_workspace_file_key(workspace_files)
       })
     )}
  end

  def handle_event("new_workspace_file", _params, socket), do: {:noreply, socket}

  def handle_event(
        "save_workspace_file",
        %{"workspace_file" => params},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    file_key =
      params["file_key"] ||
        (socket.assigns.selected_workspace_file && socket.assigns.selected_workspace_file.file_key) ||
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
           build_workspace_form(socket.assigns.workspace_files, selected_workspace_file, params)
         )
         |> put_flash(:error, "Choose a file key before saving.")}

      true ->
        case MemoryContext.upsert_workspace_file(agent.id, String.trim(file_key), content, opts) do
          {:ok, workspace_file} ->
            refresh_runtime_if_running(agent)

            {:noreply,
             socket
             |> put_flash(:info, "Saved #{workspace_file.file_key}.")
             |> reload_selected_agent(
               selected_file_key: workspace_file.file_key,
               memory_filters: socket.assigns.memory_filters
             )}

          {:error, :stale_workspace_file} ->
            {:noreply,
             socket
             |> put_flash(:error, "That file changed underneath you. Refresh and try again.")
             |> reload_selected_agent(
               selected_file_key: socket.assigns.selected_file_key,
               memory_filters: socket.assigns.memory_filters
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(
               :workspace_form,
               build_workspace_form(
                 socket.assigns.workspace_files,
                 selected_workspace_file,
                 params
               )
             )
             |> put_flash(:error, changeset_error_summary(changeset))}
        end
    end
  end

  def handle_event("save_workspace_file", _params, socket), do: {:noreply, socket}

  def handle_event("filter_memories", %{"memory_filters" => params}, socket) do
    filters = normalize_memory_filters(params)

    {:noreply,
     reload_selected_agent(socket,
       selected_file_key: socket.assigns.selected_file_key,
       memory_filters: filters
     )}
  end

  def handle_event(
        "append_memory",
        %{"memory_entry" => params},
        %{assigns: %{selected_agent: %Agent{} = agent}} = socket
      ) do
    memory_type = normalize_memory_type(params["memory_type"])
    content = String.trim(params["content"] || "")

    cond do
      content == "" ->
        {:noreply,
         socket
         |> assign(:memory_form, build_memory_form(params))
         |> put_flash(:error, "Memory content cannot be blank.")}

      true ->
        case MemoryContext.append_memory(agent.id, memory_type, content,
               date: parse_memory_date(memory_type, params["date"]),
               metadata: %{"source" => "control_center"}
             ) do
          {:ok, _memory} ->
            {:noreply,
             socket
             |> put_flash(:info, "Added #{humanize_memory_type(memory_type)} memory.")
             |> assign(:memory_form, build_memory_form())
             |> reload_selected_agent(
               selected_file_key: socket.assigns.selected_file_key,
               memory_filters: socket.assigns.memory_filters
             )}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             socket
             |> assign(:memory_form, build_memory_form(params))
             |> put_flash(:error, changeset_error_summary(changeset))}
        end
    end
  end

  def handle_event("append_memory", _params, socket), do: {:noreply, socket}

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
            <%!-- Header section --%>
            <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
              <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
                <div class="min-w-0">
                  <.link patch={~p"/control"} class="btn btn-ghost btn-sm mb-3 w-fit lg:hidden">
                    <span class="hero-arrow-left h-4 w-4" /> Back to agents
                  </.link>
                  <div class="flex flex-wrap items-center gap-3">
                    <h1 class="truncate text-2xl font-semibold text-base-content">
                      {@selected_agent.name}
                    </h1>
                    <span class={[
                      "inline-block h-2.5 w-2.5 rounded-full",
                      agent_online?(@selected_agent, @runtime, @federation_online?) && "bg-success",
                      !agent_online?(@selected_agent, @runtime, @federation_online?) &&
                        "bg-base-content/25"
                    ]} />
                    <span class={agent_badge_class(@selected_agent.status)}>
                      {humanize_value(@selected_agent.status)}
                    </span>
                    <span
                      :if={@selected_agent.runtime_type != "external"}
                      class={runtime_badge_class(@runtime.status)}
                    >
                      Runtime {humanize_value(@runtime.status)}
                    </span>
                    <span
                      :if={@selected_agent.runtime_type == "external"}
                      class={[
                        "rounded-full px-2.5 py-1 text-[11px] font-semibold uppercase tracking-widest",
                        @federation_online? && "bg-success/15 text-success",
                        !@federation_online? && "bg-base-content/10 text-base-content/50"
                      ]}
                    >
                      {if @federation_online?, do: "Connected", else: "Disconnected"}
                    </span>
                    <span
                      :if={@selected_agent_directory_entry}
                      class={source_badge_class(@selected_agent_directory_entry.source)}
                    >
                      {humanize_value(@selected_agent_directory_entry.source_label)}
                    </span>
                  </div>
                  <p class="mt-1 text-sm text-base-content/60">{@selected_agent.slug}</p>
                  <div class="mt-3 flex flex-wrap gap-2 text-xs text-base-content/55">
                    <span
                      :if={@selected_agent.runtime_type == "external"}
                      class="inline-flex items-center gap-1 rounded-full bg-info/15 px-2.5 py-1 text-info"
                    >
                      <span class="hero-globe-alt h-3.5 w-3.5" /> Federated
                    </span>
                    <span
                      :if={@selected_agent.runtime_type != "external"}
                      class="rounded-full bg-base-200 px-2.5 py-1"
                    >
                      {primary_model_label(@selected_agent)}
                    </span>
                    <span
                      :if={@selected_agent.runtime_type != "external"}
                      class="rounded-full bg-base-200 px-2.5 py-1"
                    >
                      sandbox {@selected_agent.sandbox_mode || "off"}
                    </span>
                    <span
                      :if={@selected_agent.runtime_type != "external"}
                      class="rounded-full bg-base-200 px-2.5 py-1"
                    >
                      thinking {blank_fallback(@selected_agent.thinking_default, "default")}
                    </span>
                  </div>
                </div>

                <div
                  id="agent-primary-actions"
                  class="grid w-full grid-cols-2 gap-2 sm:w-auto sm:grid-cols-2 xl:grid-cols-4"
                >
                  <button
                    :if={@selected_agent.runtime_type != "external"}
                    id="start-runtime"
                    type="button"
                    phx-click="start_runtime"
                    class="btn btn-primary btn-sm w-full"
                    disabled={@runtime.running?}
                  >
                    Start runtime
                  </button>
                  <button
                    :if={@selected_agent.runtime_type != "external"}
                    id="refresh-runtime"
                    type="button"
                    phx-click="refresh_runtime"
                    class="btn btn-ghost btn-sm w-full"
                  >
                    Refresh runtime
                  </button>
                  <button
                    :if={@selected_agent.runtime_type != "external"}
                    id="stop-runtime"
                    type="button"
                    phx-click="stop_runtime"
                    class="btn btn-ghost btn-sm w-full text-error"
                    disabled={!@runtime.running?}
                  >
                    Stop runtime
                  </button>
                  <button
                    :if={@pending_delete_slug != @selected_agent.slug}
                    id="delete-agent"
                    type="button"
                    phx-click="request_delete_agent"
                    class="btn btn-ghost btn-sm w-full text-error"
                    disabled={
                      @selected_agent_directory_entry &&
                        @selected_agent_directory_entry.workspace_managed?
                    }
                  >
                    Delete agent
                  </button>
                  <button
                    :if={@pending_delete_slug == @selected_agent.slug}
                    id="delete-agent"
                    type="button"
                    phx-click="delete_agent"
                    class="btn btn-error btn-sm w-full"
                    disabled={
                      @selected_agent_directory_entry &&
                        @selected_agent_directory_entry.workspace_managed?
                    }
                  >
                    Confirm delete
                  </button>
                </div>
              </div>

              <div :if={@pending_delete_slug == @selected_agent.slug} class="mt-3">
                <button type="button" phx-click="cancel_delete_agent" class="btn btn-ghost btn-xs">
                  Cancel delete
                </button>
              </div>

              <%!-- Stat cards: federated agents show connection-relevant stats --%>
              <div
                :if={@selected_agent.runtime_type == "external"}
                class="mt-5 grid gap-3 grid-cols-2 sm:grid-cols-3"
              >
                <RuntimePanel.stat_card
                  label="Connection"
                  value={if(@federation_online?, do: "Online", else: "Offline")}
                  detail={if(@federation_online?, do: "websocket active", else: "not connected")}
                />
                <RuntimePanel.stat_card
                  label="Trust level"
                  value={
                    humanize_value((@federation_runtime && @federation_runtime.trust_level) || "—")
                  }
                  detail="permission scope"
                />
                <RuntimePanel.stat_card
                  label="Spaces"
                  value={length(@federation_spaces)}
                  detail="active memberships"
                />
              </div>
              <div
                :if={@selected_agent.runtime_type != "external"}
                class="mt-5 grid gap-3 grid-cols-2 sm:grid-cols-3 xl:grid-cols-5"
              >
                <RuntimePanel.stat_card
                  label="Runtime"
                  value={humanize_value(@runtime.status)}
                  detail={runtime_detail(@runtime)}
                />
                <RuntimePanel.stat_card
                  label="Active sessions"
                  value={length(@runtime.active_session_ids)}
                  detail="live in memory"
                />
                <RuntimePanel.stat_card
                  label="Workspace files"
                  value={@overview_counts.workspace_files}
                  detail="identity + instructions"
                />
                <RuntimePanel.stat_card
                  label="Memories"
                  value={@overview_counts.memories}
                  detail="daily, long-term, snapshot"
                />
                <RuntimePanel.stat_card
                  label="Vault creds"
                  value={@overview_counts.vault}
                  detail="agent + platform"
                />
              </div>
            </section>

            <%!-- Federation connection section (for external runtime agents) --%>
            <section
              :if={@selected_agent.runtime_type == "external" && @selected_agent.runtime_id}
              class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm"
            >
              <h2 class="text-lg font-semibold text-base-content">
                <span class="hero-globe-alt mr-1 inline-block h-5 w-5 align-text-bottom" />
                Federation Connection
              </h2>
              <p class="mt-1 text-sm text-base-content/60">
                External runtime linked to this agent.
              </p>
              <RuntimePanel.federation_connection_panel
                agent={@selected_agent}
                regenerated_token={@regenerated_token}
                federation_online?={@federation_online?}
              />
            </section>

            <%!-- Federated agent detail panels --%>
            <div :if={@selected_agent.runtime_type == "external"} class="flex flex-col gap-6">
              <%!-- Identity section --%>
              <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                <h2 class="text-lg font-semibold text-base-content">
                  <span class="hero-identification mr-1 inline-block h-5 w-5 align-text-bottom" />
                  Identity
                </h2>
                <p class="mt-1 text-sm text-base-content/60">
                  How this agent appears in Suite chat. Config and model routing are managed by the remote OpenClaw instance.
                </p>
                <.form
                  for={@config_form}
                  id="federated-identity-form"
                  phx-submit="save_config"
                  class="mt-4 space-y-4"
                >
                  <label class="form-control max-w-md">
                    <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                      Display name
                    </span>
                    <input
                      type="text"
                      name="config[name]"
                      value={@config_form[:name].value || ""}
                      class="input input-bordered w-full"
                    />
                  </label>
                  <div class="flex justify-stretch sm:justify-end">
                    <button type="submit" class="btn btn-neutral w-full sm:w-auto">
                      Update name
                    </button>
                  </div>
                </.form>
              </section>

              <%!-- Spaces section --%>
              <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                <h2 class="text-lg font-semibold text-base-content">
                  <span class="hero-chat-bubble-left-right mr-1 inline-block h-5 w-5 align-text-bottom" />
                  Spaces
                </h2>
                <p class="mt-1 text-sm text-base-content/60">
                  Spaces this agent participates in.
                </p>
                <div class="mt-4 space-y-2">
                  <div
                    :for={space <- @federation_spaces}
                    class="flex items-center justify-between rounded-2xl border border-base-300 px-4 py-3 text-sm"
                  >
                    <div>
                      <p class="font-semibold text-base-content">{space.space_name}</p>
                      <p class="text-xs text-base-content/50">{space.space_slug}</p>
                    </div>
                    <span class="rounded-full bg-base-200 px-2.5 py-1 text-[11px] uppercase tracking-widest text-base-content/55">
                      {space.attention_mode}
                    </span>
                  </div>
                  <div
                    :if={@federation_spaces == []}
                    class="rounded-2xl border border-dashed border-base-300 px-4 py-5 text-sm text-base-content/50"
                  >
                    Not participating in any spaces yet.
                  </div>
                </div>
              </section>
            </div>

            <%!-- Config + model routing (built-in agents only) --%>
            <div
              :if={@selected_agent.runtime_type != "external"}
              class="grid gap-6 xl:grid-cols-[minmax(0,1.6fr)_minmax(320px,0.9fr)]"
            >
              <div class="flex min-w-0 flex-col gap-6">
                <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                  <div class="flex items-start justify-between gap-4">
                    <div>
                      <h2 class="text-lg font-semibold text-base-content">Config + model routing</h2>
                      <p class="mt-1 text-sm text-base-content/60">
                        Edit the persisted agent definition. Runtime refresh uses the real AgentServer.
                      </p>
                    </div>
                  </div>

                  <.form
                    for={@config_form}
                    id="agent-config-form"
                    phx-submit="save_config"
                    class="mt-4 space-y-4"
                  >
                    <div class="grid gap-4 md:grid-cols-2">
                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Name
                        </span>
                        <input
                          type="text"
                          name="config[name]"
                          value={@config_form[:name].value || ""}
                          class="input input-bordered w-full"
                        />
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Status
                        </span>
                        <select name="config[status]" class="select select-bordered w-full">
                          <option
                            :for={status <- ["active", "paused", "archived"]}
                            selected={@config_form[:status].value == status}
                            value={status}
                          >
                            {humanize_value(status)}
                          </option>
                        </select>
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Primary model
                        </span>
                        <input
                          type="text"
                          name="config[primary_model]"
                          value={@config_form[:primary_model].value || ""}
                          class="input input-bordered w-full"
                          placeholder="anthropic/claude-sonnet-4-6"
                        />
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Fallbacks
                        </span>
                        <input
                          type="text"
                          name="config[fallback_models]"
                          value={@config_form[:fallback_models].value || ""}
                          class="input input-bordered w-full"
                          placeholder="openai/gpt-4.1, openai/gpt-4o-mini"
                        />
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Thinking default
                        </span>
                        <input
                          type="text"
                          name="config[thinking_default]"
                          value={@config_form[:thinking_default].value || ""}
                          class="input input-bordered w-full"
                          placeholder="medium"
                        />
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Max concurrent
                        </span>
                        <input
                          type="number"
                          min="1"
                          name="config[max_concurrent]"
                          value={@config_form[:max_concurrent].value || 1}
                          class="input input-bordered w-full"
                        />
                      </label>

                      <label class="form-control md:col-span-2">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Sandbox mode
                        </span>
                        <select
                          name="config[sandbox_mode]"
                          class="select select-bordered w-full md:max-w-xs"
                        >
                          <option
                            :for={mode <- ["off", "inherit", "require"]}
                            selected={(@config_form[:sandbox_mode].value || "off") == mode}
                            value={mode}
                          >
                            {mode}
                          </option>
                        </select>
                      </label>
                    </div>

                    <p
                      :if={
                        @selected_agent_directory_entry &&
                          @selected_agent_directory_entry.workspace_managed?
                      }
                      class="rounded-2xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/65"
                    >
                      This agent is sourced from the mounted workspace config. Use the workspace to remove it permanently.
                    </p>

                    <div class="rounded-2xl border border-base-300 bg-base-200/50 p-4">
                      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                        Resolved model chain
                      </p>
                      <div class="mt-3 flex flex-wrap gap-2">
                        <span
                          :for={model <- model_chain(@model_chain_result)}
                          class="rounded-full bg-base-100 px-3 py-1 text-sm text-base-content/70 shadow-sm"
                        >
                          {model}
                        </span>
                        <span
                          :if={model_chain(@model_chain_result) == []}
                          class="text-sm text-base-content/50"
                        >
                          No models configured yet.
                        </span>
                      </div>
                    </div>

                    <div class="flex justify-stretch sm:justify-end">
                      <button type="submit" class="btn btn-neutral w-full sm:w-auto">
                        Save config
                      </button>
                    </div>
                  </.form>
                </section>

                <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                  <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <h2 class="text-lg font-semibold text-base-content">Workspace files</h2>
                      <p class="mt-1 text-sm text-base-content/60">
                        These are the portable identity files that make an OpenClaw agent feel like itself.
                      </p>
                    </div>
                    <button type="button" phx-click="new_workspace_file" class="btn btn-ghost btn-sm">
                      New file
                    </button>
                  </div>

                  <div class="mt-4 grid gap-4 lg:grid-cols-[220px_minmax(0,1fr)]">
                    <div class="flex flex-col gap-2">
                      <button
                        :for={workspace_file <- @workspace_files}
                        type="button"
                        phx-click="select_workspace_file"
                        phx-value-file_key={workspace_file.file_key}
                        class={[
                          "rounded-2xl border px-3 py-2 text-left transition-colors",
                          @selected_file_key == workspace_file.file_key &&
                            "border-primary bg-primary/5 text-primary",
                          @selected_file_key != workspace_file.file_key &&
                            "border-base-300 bg-base-100 hover:border-primary/30"
                        ]}
                      >
                        <p class="truncate text-sm font-semibold">{workspace_file.file_key}</p>
                        <p class="text-xs text-base-content/50">v{workspace_file.version}</p>
                      </button>

                      <div
                        :if={@workspace_files == []}
                        class="rounded-2xl border border-dashed border-base-300 px-3 py-4 text-sm text-base-content/50"
                      >
                        No files yet.
                      </div>
                    </div>

                    <.form
                      for={@workspace_form}
                      id="workspace-file-form"
                      phx-submit="save_workspace_file"
                      class="space-y-3"
                    >
                      <div>
                        <label class="mb-1 block text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          File key
                        </label>
                        <input
                          :if={is_nil(@selected_workspace_file)}
                          type="text"
                          name="workspace_file[file_key]"
                          value={@workspace_form[:file_key].value || ""}
                          class="input input-bordered w-full md:max-w-sm"
                          placeholder="SOUL.md"
                        />
                        <div
                          :if={@selected_workspace_file}
                          class="rounded-2xl border border-base-300 bg-base-200/50 px-3 py-2 text-sm text-base-content/70"
                        >
                          {@selected_workspace_file.file_key}
                          <input
                            type="hidden"
                            name="workspace_file[file_key]"
                            value={@selected_workspace_file.file_key}
                          />
                        </div>
                      </div>

                      <div>
                        <label class="mb-1 block text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Content
                        </label>
                        <textarea
                          name="workspace_file[content]"
                          rows="18"
                          class="textarea textarea-bordered h-80 w-full font-mono text-sm leading-6"
                        >{@workspace_form[:content].value || ""}</textarea>
                      </div>

                      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
                        <p class="text-xs text-base-content/50">
                          {workspace_hint(@selected_workspace_file, @workspace_form[:file_key].value)}
                        </p>
                        <button type="submit" class="btn btn-neutral w-full sm:w-auto">
                          Save file
                        </button>
                      </div>
                    </.form>
                  </div>
                </section>

                <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                  <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                    <div>
                      <h2 class="text-lg font-semibold text-base-content">Memory browser</h2>
                      <p class="mt-1 text-sm text-base-content/60">
                        Browse recent memories and append new long-term, daily, or snapshot entries.
                      </p>
                    </div>
                  </div>

                  <div class="mt-4 grid gap-4 xl:grid-cols-[minmax(0,1fr)_320px]">
                    <div class="space-y-4">
                      <.form
                        for={@memory_filter_form}
                        id="memory-filter-form"
                        phx-change="filter_memories"
                        phx-submit="filter_memories"
                        class="grid gap-3 md:grid-cols-[180px_minmax(0,1fr)]"
                      >
                        <label class="form-control">
                          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                            Type
                          </span>
                          <select name="memory_filters[type]" class="select select-bordered w-full">
                            <option
                              :for={
                                {value, label} <- [
                                  {"all", "All"},
                                  {"long_term", "Long-term"},
                                  {"daily", "Daily"},
                                  {"snapshot", "Snapshot"}
                                ]
                              }
                              value={value}
                              selected={@memory_filter_form[:type].value == value}
                            >
                              {label}
                            </option>
                          </select>
                        </label>

                        <label class="form-control">
                          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                            Search
                          </span>
                          <input
                            type="text"
                            name="memory_filters[query]"
                            value={@memory_filter_form[:query].value || ""}
                            class="input input-bordered w-full"
                            placeholder="keyword recall"
                          />
                        </label>
                      </.form>

                      <div class="space-y-3">
                        <article
                          :for={memory <- @recent_memories}
                          class="rounded-2xl border border-base-300 bg-base-100 px-4 py-3"
                        >
                          <div class="flex flex-wrap items-center gap-2 text-[11px] uppercase tracking-widest text-base-content/50">
                            <span>{humanize_memory_type(memory.memory_type)}</span>
                            <span :if={memory.date}>{Date.to_iso8601(memory.date)}</span>
                            <span>{format_datetime(memory.inserted_at)}</span>
                          </div>
                          <p class="mt-2 whitespace-pre-wrap text-sm leading-6 text-base-content/80">
                            {memory.content}
                          </p>
                        </article>

                        <div
                          :if={@recent_memories == []}
                          class="rounded-2xl border border-dashed border-base-300 px-4 py-5 text-sm text-base-content/50"
                        >
                          Nothing matched this memory filter.
                        </div>
                      </div>
                    </div>

                    <.form
                      for={@memory_form}
                      id="memory-entry-form"
                      phx-submit="append_memory"
                      class="space-y-3 rounded-2xl border border-base-300 bg-base-200/40 p-4"
                    >
                      <div>
                        <p class="text-sm font-semibold text-base-content">Add memory</p>
                        <p class="text-xs text-base-content/50">
                          Writes through MemoryContext so later runtime modules see the real data.
                        </p>
                      </div>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Memory type
                        </span>
                        <select name="memory_entry[memory_type]" class="select select-bordered w-full">
                          <option
                            :for={
                              {value, label} <- [
                                {"long_term", "Long-term"},
                                {"daily", "Daily"},
                                {"snapshot", "Snapshot"}
                              ]
                            }
                            value={value}
                            selected={@memory_form[:memory_type].value == value}
                          >
                            {label}
                          </option>
                        </select>
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Date (for daily)
                        </span>
                        <input
                          type="date"
                          name="memory_entry[date]"
                          value={@memory_form[:date].value || ""}
                          class="input input-bordered w-full"
                        />
                      </label>

                      <label class="form-control">
                        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                          Content
                        </span>
                        <textarea
                          name="memory_entry[content]"
                          rows="9"
                          class="textarea textarea-bordered w-full leading-6"
                        >{@memory_form[:content].value || ""}</textarea>
                      </label>

                      <button type="submit" class="btn btn-neutral w-full">Append memory</button>
                    </.form>
                  </div>
                </section>
              </div>

              <div class="flex min-w-0 flex-col gap-6">
                <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                  <h2 class="text-lg font-semibold text-base-content">Runtime + sessions</h2>
                  <p class="mt-1 text-sm text-base-content/60">
                    Monitoring reads the real AgentServer state plus persisted session history.
                  </p>

                  <div class="mt-4 rounded-2xl border border-base-300 bg-base-200/40 p-4 text-sm text-base-content/75">
                    <div class="flex items-center justify-between gap-3">
                      <span>Status</span>
                      <span class={runtime_badge_class(@runtime.status)}>
                        {humanize_value(@runtime.status)}
                      </span>
                    </div>
                    <div class="mt-2 flex items-center justify-between gap-3">
                      <span>PID</span>
                      <span class="font-mono text-xs text-base-content/55">
                        {runtime_pid_label(@runtime.pid)}
                      </span>
                    </div>
                    <div class="mt-2 flex items-center justify-between gap-3">
                      <span>Active session IDs</span>
                      <span class="text-right text-xs text-base-content/55">
                        {runtime_sessions_label(@runtime.active_session_ids)}
                      </span>
                    </div>
                  </div>

                  <div class="mt-4 space-y-3">
                    <article
                      :for={session <- @recent_sessions}
                      class="rounded-2xl border border-base-300 px-4 py-3 text-sm"
                    >
                      <div class="flex flex-wrap items-center gap-2">
                        <span class={session_badge_class(session.status)}>
                          {humanize_value(session.status)}
                        </span>
                        <span class="font-mono text-[11px] text-base-content/45">
                          {short_id(session.id)}
                        </span>
                      </div>
                      <p class="mt-2 text-base-content/70">
                        {blank_fallback(session.model_used, "model not recorded")}
                      </p>
                      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/50">
                        <span>started {format_datetime(session.started_at)}</span>
                        <span :if={session.ended_at}>ended {format_datetime(session.ended_at)}</span>
                        <span :if={session.parent_session_id}>
                          parent {short_id(session.parent_session_id)}
                        </span>
                      </div>
                    </article>

                    <div
                      :if={@recent_sessions == []}
                      class="rounded-2xl border border-dashed border-base-300 px-4 py-5 text-sm text-base-content/50"
                    >
                      No sessions yet.
                    </div>
                  </div>
                </section>

                <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
                  <h2 class="text-lg font-semibold text-base-content">Vault visibility</h2>
                  <p class="mt-1 text-sm text-base-content/60">
                    Metadata only — secrets stay encrypted. Agent runtime still resolves values through Platform.Vault.get/2.
                  </p>

                  <div class="mt-4 space-y-4">
                    <div>
                      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                        Agent-scoped credentials
                      </p>
                      <div class="mt-2 space-y-2">
                        <RuntimePanel.credential_row
                          :for={credential <- @agent_credentials}
                          credential={credential}
                        />
                        <div
                          :if={@agent_credentials == []}
                          class="rounded-2xl border border-dashed border-base-300 px-3 py-4 text-sm text-base-content/50"
                        >
                          No agent-scoped credentials.
                        </div>
                      </div>
                    </div>

                    <div>
                      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
                        Relevant platform credentials
                      </p>
                      <div class="mt-2 space-y-2">
                        <RuntimePanel.credential_row
                          :for={credential <- @platform_credentials}
                          credential={credential}
                        />
                        <div
                          :if={@platform_credentials == []}
                          class="rounded-2xl border border-dashed border-base-300 px-3 py-4 text-sm text-base-content/50"
                        >
                          No matching platform credentials for this model chain.
                        </div>
                      </div>
                    </div>
                  </div>
                </section>
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
    |> assign(:memory_filters, default_memory_filters())
    |> assign(:memory_filter_form, to_form(default_memory_filters(), as: :memory_filters))
    |> assign(:recent_memories, [])
    |> assign(:recent_sessions, [])
    |> assign(:agent_credentials, [])
    |> assign(:platform_credentials, [])
    |> assign(:config_form, to_form(%{}, as: :config))
    |> assign(:create_agent_form, to_form(default_create_agent_params(), as: :create_agent))
    |> assign(:show_create_agent, socket.assigns[:show_create_agent] || false)
    |> assign(:pending_delete_slug, nil)
    |> assign(:memory_form, to_form(default_memory_entry(), as: :memory_entry))
    |> assign(:agent_status, PlatformWeb.ShellLive.default_agent_status())
    |> assign(:selected_agent_directory_entry, nil)
    |> assign(:regenerated_token, nil)
    |> assign(:federation_runtime, nil)
    |> assign(:federation_online?, false)
    |> assign(:federation_spaces, [])
  end

  defp assign_agent_panel(socket, %Agent{} = agent, opts) do
    memory_filters =
      normalize_memory_filters(
        Keyword.get(
          opts,
          :memory_filters,
          socket.assigns[:memory_filters] || default_memory_filters()
        )
      )

    workspace_files = MemoryContext.list_workspace_files(agent.id)

    selected_workspace_file =
      select_workspace_file(
        workspace_files,
        Keyword.get(opts, :selected_file_key) || socket.assigns[:selected_file_key]
      )

    agent_credentials = Platform.Vault.list(scope: {:agent, agent.id})
    platform_credentials = relevant_platform_credentials(agent)
    runtime = runtime_snapshot(agent)

    socket
    |> assign(:page_title, "Control Center · #{agent.name}")
    |> assign(:selected_agent, agent)
    |> assign(:runtime, runtime)
    |> assign(:overview_counts, %{
      workspace_files: length(workspace_files),
      memories: count_memories(agent.id),
      sessions: count_sessions(agent.id),
      vault: length(agent_credentials) + length(platform_credentials)
    })
    |> assign(:model_chain_result, Router.model_chain(agent))
    |> assign(:workspace_files, workspace_files)
    |> assign(:selected_workspace_file, selected_workspace_file)
    |> assign(:selected_file_key, selected_workspace_file && selected_workspace_file.file_key)
    |> assign(
      :workspace_form,
      build_workspace_form(
        workspace_files,
        selected_workspace_file,
        Keyword.get(opts, :workspace_params, %{})
      )
    )
    |> assign(:memory_filters, memory_filters)
    |> assign(:memory_filter_form, to_form(memory_filters, as: :memory_filters))
    |> assign(:recent_memories, list_filtered_memories(agent.id, memory_filters))
    |> assign(:recent_sessions, list_recent_sessions(agent.id))
    |> assign(:agent_credentials, agent_credentials)
    |> assign(:platform_credentials, platform_credentials)
    |> assign(:config_form, build_config_form(agent, Keyword.get(opts, :config_params, %{})))
    |> assign(
      :selected_agent_directory_entry,
      find_agent_directory_entry(socket.assigns.agents, agent.slug)
    )
    |> assign(:pending_delete_slug, pending_delete_slug(socket, agent.slug))
    |> assign(:memory_form, build_memory_form(Keyword.get(opts, :memory_params)))
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
    agents = list_agents()

    socket
    |> assign(:agents, agents)
    |> assign(:selected_agent, refreshed_agent)
    |> assign(
      :selected_agent_directory_entry,
      find_agent_directory_entry(agents, refreshed_agent.slug)
    )
    |> assign_agent_panel(refreshed_agent, opts)
  end

  def reload_selected_agent(socket, _opts), do: socket

  defp list_agents do
    persisted_agents = list_persisted_agents()
    persisted_by_slug = Map.new(persisted_agents, &{&1.slug, &1})

    configured_agents =
      case WorkspaceBootstrap.list_configured_agents() do
        {:ok, agents} -> agents
        {:error, _reason} -> []
      end

    configured_items =
      Enum.map(configured_agents, fn configured_agent ->
        case Map.get(persisted_by_slug, configured_agent.id) do
          %Agent{} = agent ->
            build_agent_directory_entry(agent, :workspace)

          nil ->
            build_configured_agent_directory_entry(configured_agent)
        end
      end)

    configured_slugs = MapSet.new(configured_items, & &1.slug)

    persisted_items =
      persisted_agents
      |> Enum.reject(&MapSet.member?(configured_slugs, &1.slug))
      |> Enum.map(&build_agent_directory_entry(&1, :database))

    (configured_items ++ persisted_items)
    |> Enum.map(&attach_runtime_status/1)
    |> Enum.sort_by(&{&1.name, &1.slug})
  end

  defp list_persisted_agents do
    from(a in Agent, order_by: [asc: a.slug])
    |> Repo.all()
  end

  defp resolve_selected_agent_slug(nil, _agents), do: nil

  defp resolve_selected_agent_slug(slug, agents) do
    if Enum.any?(agents, &(&1.slug == slug)),
      do: slug,
      else: resolve_selected_agent_slug(nil, agents)
  end

  defp ensure_selected_agent(slug, agents) when is_binary(slug) do
    case find_agent_directory_entry(agents, slug) do
      %{agent: %Agent{} = agent} ->
        agent

      %{workspace_managed?: true} ->
        case WorkspaceBootstrap.ensure_agent(slug: slug) do
          {:ok, agent} -> agent
          {:error, _reason} -> Repo.get_by(Agent, slug: slug)
        end

      _ ->
        Repo.get_by(Agent, slug: slug)
    end
  end

  defp ensure_selected_agent(_slug, _agents), do: nil

  defp handle_delete_agent(socket, %Agent{} = agent) do
    case delete_agent(agent) do
      :ok ->
        socket =
          socket
          |> put_flash(:info, "Deleted #{agent.name}.")
          |> assign(:agents, list_agents())
          |> assign(:pending_delete_slug, nil)
          |> assign(:selected_agent, nil)
          |> assign(:selected_agent_directory_entry, nil)

        {:noreply, push_patch(socket, to: ~p"/control")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not delete agent: #{inspect(reason)}")}
    end
  end

  defp find_agent_directory_entry(agents, slug) when is_binary(slug) do
    Enum.find(agents, &(&1.slug == slug))
  end

  defp find_agent_directory_entry(_agents, _slug), do: nil

  defp pending_delete_slug(socket, selected_slug) do
    case socket.assigns[:pending_delete_slug] do
      ^selected_slug -> selected_slug
      _ -> nil
    end
  end

  defp runtime_snapshot(%Agent{} = agent) do
    pid = AgentServer.whereis(agent.id)

    case AgentServer.state(agent.id) do
      {:ok, state} ->
        %{
          running?: is_pid(pid),
          pid: pid,
          status: state.status,
          active_session_ids: Map.keys(state.active_sessions),
          workspace_keys: Map.keys(state.workspace || %{})
        }

      {:error, _reason} ->
        %{
          running?: false,
          pid: nil,
          status: if(agent.status in ["paused", "archived"], do: :paused, else: :idle),
          active_session_ids: [],
          workspace_keys: []
        }
    end
  end

  defp count_memories(agent_id) do
    from(m in Memory, where: m.agent_id == ^agent_id)
    |> Repo.aggregate(:count, :id)
  end

  defp count_sessions(agent_id) do
    from(s in Session, where: s.agent_id == ^agent_id)
    |> Repo.aggregate(:count, :id)
  end

  defp list_recent_sessions(agent_id) do
    from(s in Session,
      where: s.agent_id == ^agent_id,
      order_by: [desc: s.started_at, desc: s.id],
      limit: ^@session_limit
    )
    |> Repo.all()
  end

  defp list_filtered_memories(agent_id, filters) do
    opts = [limit: @memory_limit]

    opts =
      case filters["type"] do
        "all" -> opts
        type -> Keyword.put(opts, :memory_type, type)
      end

    opts =
      case String.trim(filters["query"] || "") do
        "" -> opts
        query -> Keyword.put(opts, :query, query)
      end

    MemoryContext.list_memories(agent_id, opts)
  end

  defp relevant_platform_credentials(%Agent{} = agent) do
    providers = providers_for_agent(agent)

    Platform.Vault.list(scope: {:platform, nil})
    |> Enum.filter(fn credential ->
      providers == [] || is_nil(credential.provider) || credential.provider in providers
    end)
  end

  defp providers_for_agent(%Agent{} = agent) do
    agent
    |> Router.model_chain()
    |> model_chain()
    |> Enum.map(&provider_for_model/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp provider_for_model(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      ["openai-codex", _rest] -> "openai"
      [provider, _rest] -> provider
      _ -> nil
    end
  end

  defp build_config_form(%Agent{} = agent, overrides) do
    model_config = normalize_map(agent.model_config || %{})

    base = %{
      "name" => agent.name,
      "status" => agent.status,
      "primary_model" => Map.get(model_config, "primary", ""),
      "fallback_models" => Enum.join(List.wrap(Map.get(model_config, "fallbacks", [])), ", "),
      "thinking_default" => agent.thinking_default || "",
      "max_concurrent" => agent.max_concurrent || 1,
      "sandbox_mode" => agent.sandbox_mode || "off"
    }

    to_form(Map.merge(base, normalize_map(overrides)), as: :config)
  end

  defp build_create_agent_form(overrides) do
    to_form(Map.merge(default_create_agent_params(), normalize_map(overrides)), as: :create_agent)
  end

  defp build_workspace_form(
         _workspace_files,
         %WorkspaceFile{} = selected_workspace_file,
         overrides
       ) do
    base = %{
      "file_key" => selected_workspace_file.file_key,
      "content" => selected_workspace_file.content
    }

    to_form(Map.merge(base, normalize_map(overrides)), as: :workspace_file)
  end

  defp build_workspace_form(workspace_files, nil, overrides) do
    base = %{
      "file_key" => next_workspace_file_key(workspace_files),
      "content" => ""
    }

    to_form(Map.merge(base, normalize_map(overrides)), as: :workspace_file)
  end

  defp build_memory_form(overrides \\ nil) do
    to_form(Map.merge(default_memory_entry(), normalize_map(overrides || %{})), as: :memory_entry)
  end

  defp default_memory_filters do
    %{"type" => "all", "query" => ""}
  end

  defp default_create_agent_params do
    %{
      "name" => "",
      "slug" => "",
      "primary_model" => "",
      "status" => "active",
      "max_concurrent" => 1,
      "sandbox_mode" => "off"
    }
  end

  defp default_memory_entry do
    %{
      "memory_type" => "long_term",
      "date" => Date.utc_today() |> Date.to_iso8601(),
      "content" => ""
    }
  end

  defp normalize_memory_filters(params) do
    params = normalize_map(params)

    %{
      "type" => Map.get(params, "type", "all"),
      "query" => Map.get(params, "query", "")
    }
  end

  defp select_workspace_file([], _selected_file_key), do: nil

  defp select_workspace_file(workspace_files, selected_file_key)
       when is_binary(selected_file_key) do
    Enum.find(workspace_files, &(&1.file_key == selected_file_key)) || List.first(workspace_files)
  end

  defp select_workspace_file(workspace_files, _selected_file_key), do: List.first(workspace_files)

  defp next_workspace_file_key(workspace_files) do
    used = MapSet.new(workspace_files, & &1.file_key)

    Enum.find(@workspace_defaults, &(not MapSet.member?(used, &1))) || "NOTES.md"
  end

  defp config_attrs_from_params(%Agent{} = agent, params) do
    params = normalize_map(params)
    model_config = normalize_map(agent.model_config || %{})

    updated_model_config =
      model_config
      |> Map.put("primary", String.trim(Map.get(params, "primary_model", "")))
      |> Map.put("fallbacks", parse_fallbacks(Map.get(params, "fallback_models", "")))

    %{
      name: String.trim(Map.get(params, "name", agent.name || "")),
      status: Map.get(params, "status", agent.status),
      thinking_default: blank_to_nil(Map.get(params, "thinking_default")),
      max_concurrent:
        parse_positive_integer(Map.get(params, "max_concurrent")) || agent.max_concurrent || 1,
      sandbox_mode: blank_fallback(Map.get(params, "sandbox_mode"), agent.sandbox_mode || "off"),
      model_config: updated_model_config
    }
  end

  defp create_agent_attrs_from_params(params) do
    params = normalize_map(params)
    name = String.trim(Map.get(params, "name", ""))
    slug = params |> Map.get("slug", "") |> to_string() |> slugify()
    primary_model = String.trim(Map.get(params, "primary_model", ""))

    %{
      slug: slug,
      name: name,
      status: blank_fallback(Map.get(params, "status"), "active"),
      max_concurrent: parse_positive_integer(Map.get(params, "max_concurrent")) || 1,
      sandbox_mode: blank_fallback(Map.get(params, "sandbox_mode"), "off"),
      model_config:
        if(primary_model == "", do: %{}, else: %{"primary" => primary_model, "fallbacks" => []})
    }
  end

  defp parse_fallbacks(raw) when is_binary(raw) do
    raw
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_fallbacks(_raw), do: []

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp parse_memory_date("daily", value) when is_binary(value) do
    case Date.from_iso8601(String.trim(value)) do
      {:ok, date} -> date
      _ -> Date.utc_today()
    end
  end

  defp parse_memory_date("daily", _value), do: Date.utc_today()
  defp parse_memory_date(_memory_type, _value), do: nil

  defp normalize_memory_type(nil), do: "long_term"

  defp normalize_memory_type(value),
    do: value |> to_string() |> String.trim() |> blank_fallback("long_term")

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

  defp delete_agent(%Agent{} = agent) do
    :ok = AgentServer.stop_agent(agent)

    session_ids_query =
      from(s in Session,
        where: s.agent_id == ^agent.id,
        select: s.id
      )

    Multi.new()
    |> Multi.delete_all(
      :context_shares,
      from(cs in ContextShare,
        where:
          cs.from_session_id in subquery(session_ids_query) or
            cs.to_session_id in subquery(session_ids_query)
      )
    )
    |> Multi.delete_all(:sessions, from(s in Session, where: s.agent_id == ^agent.id))
    |> Multi.delete(:agent, agent)
    |> Repo.transaction()
    |> case do
      {:ok, _changes} -> :ok
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp build_agent_directory_entry(%Agent{} = agent, source) do
    %{
      slug: agent.slug,
      name: agent.name,
      status: agent.status,
      max_concurrent: agent.max_concurrent || 1,
      primary_model: primary_model_label(agent),
      source: source,
      source_label: source_label(source),
      workspace_managed?: source == :workspace,
      persisted?: true,
      agent: agent,
      runtime_type: agent.runtime_type || "built_in",
      runtime_status: runtime_status(agent),
      running?: runtime_running?(agent)
    }
  end

  defp build_configured_agent_directory_entry(configured_agent) do
    attrs = normalize_map(configured_agent.attrs || %{})
    model_config = normalize_map(Map.get(attrs, "model_config", %{}))

    %{
      slug: configured_agent.id,
      name: configured_agent.name,
      status: Map.get(attrs, "status", "active"),
      max_concurrent: Map.get(attrs, "max_concurrent", 1),
      primary_model: Map.get(model_config, "primary", "no primary model"),
      source: :workspace,
      source_label: source_label(:workspace),
      workspace_managed?: true,
      persisted?: false,
      agent: nil,
      runtime_type: "built_in",
      runtime_status: :unknown,
      running?: false
    }
  end

  defp attach_runtime_status(%{agent: %Agent{runtime_type: "external"} = agent} = entry) do
    runtime = Federation.get_runtime_for_agent(agent)
    online? = runtime != nil && RuntimePresence.online?(runtime.runtime_id)

    entry
    |> Map.put(:runtime_status, if(online?, do: :running, else: :idle))
    |> Map.put(:running?, online?)
  end

  defp attach_runtime_status(%{agent: %Agent{} = agent} = entry) do
    entry
    |> Map.put(:runtime_status, runtime_status(agent))
    |> Map.put(:running?, runtime_running?(agent))
  end

  defp attach_runtime_status(entry), do: entry

  defp source_label(:workspace), do: "mounted workspace"
  defp source_label(:database), do: "control center"

  defp primary_model_label(%Agent{} = agent) do
    case normalize_map(agent.model_config || %{}) do
      %{"primary" => value} when is_binary(value) and value != "" -> value
      _ -> "no primary model"
    end
  end

  defp model_chain({:ok, chain}), do: chain
  defp model_chain(_result), do: []

  defp runtime_detail(%{running?: true, pid: pid}), do: runtime_pid_label(pid)
  defp runtime_detail(_runtime), do: "not started"

  defp runtime_running?(%Agent{} = agent), do: is_pid(AgentServer.whereis(agent.id))

  defp agent_online?(%Agent{runtime_type: "external"}, _runtime, federation_online?),
    do: federation_online?

  defp agent_online?(_agent, runtime, _federation_online?), do: runtime.running?

  defp runtime_status(%Agent{} = agent) do
    case runtime_snapshot(agent) do
      %{status: status} -> status
      _ -> :unknown
    end
  end

  defp runtime_pid_label(pid) when is_pid(pid), do: inspect(pid)
  defp runtime_pid_label(_pid), do: "stopped"

  defp runtime_sessions_label([]), do: "none"
  defp runtime_sessions_label(ids), do: Enum.map_join(ids, ", ", &short_id/1)

  defp workspace_hint(%WorkspaceFile{version: version}, _file_key),
    do: "Editing existing file · version #{version}"

  defp workspace_hint(nil, file_key) do
    if is_binary(file_key) and String.trim(file_key) != "" do
      "Creating a new workspace file"
    else
      "Choose a file key to create a new workspace file"
    end
  end

  defp changeset_error_summary(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      replacements = Map.new(opts, fn {key, value} -> {to_string(key), value} end)

      Regex.replace(~r/%{(\w+)}/, msg, fn _, key ->
        replacements |> Map.get(key, key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field} #{&1}") end)
    |> Enum.join(", ")
  rescue
    _ -> "Please check the form and try again."
  end

  defp normalize_map(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_value(%{} = map), do: normalize_map(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp blank_fallback(value, fallback) do
    case blank_to_nil(value) do
      nil -> fallback
      kept -> kept
    end
  end

  defp slugify(value) when is_binary(value) do
    value
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  defp slugify(value), do: value |> to_string() |> slugify()
end
