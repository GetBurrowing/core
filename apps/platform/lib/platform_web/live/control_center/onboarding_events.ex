defmodule PlatformWeb.ControlCenter.OnboardingEvents do
  @moduledoc """
  Handle_event clauses for onboarding flows: template selection, federate
  submission, import, and general onboarding navigation.
  """
  use PlatformWeb, :verified_routes

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, push_patch: 2]
  import PlatformWeb.ControlCenter.Helpers, only: [slugify: 1, changeset_error_summary: 1]

  alias Platform.Agents.{Agent, WorkspaceBootstrap}
  alias Platform.Federation
  alias Platform.Repo

  @role_templates [
    %{
      id: "designer",
      name: "Designer",
      icon: "hero-paint-brush",
      description: "Visual design, UI/UX, branding",
      default_name: "Designer",
      system_prompt: "You are a skilled visual designer...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["canvas", "image", "web_search"]
    },
    %{
      id: "researcher",
      name: "Researcher",
      icon: "hero-magnifying-glass",
      description: "Deep research, analysis, synthesis",
      default_name: "Researcher",
      system_prompt: "You are a thorough researcher...",
      model_tier: "high",
      suggested_model: "anthropic/claude-opus-4-6",
      tool_profile: "minimal",
      tools_allow: ["web_search", "web_fetch", "pdf", "group:fs"]
    },
    %{
      id: "architect",
      name: "Architect",
      icon: "hero-cube-transparent",
      description: "System design, ADRs, code review",
      default_name: "Architect",
      system_prompt: "You are a senior software architect...",
      model_tier: "high",
      suggested_model: "anthropic/claude-opus-4-6",
      tool_profile: "full",
      tools_allow: ["group:fs", "exec", "web_search"]
    },
    %{
      id: "writer",
      name: "Writer",
      icon: "hero-pencil-square",
      description: "Content, docs, copywriting",
      default_name: "Writer",
      system_prompt: "You are a skilled writer...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["group:fs", "web_search"]
    },
    %{
      id: "analyst",
      name: "Analyst",
      icon: "hero-chart-bar",
      description: "Data analysis, reporting, dashboards",
      default_name: "Analyst",
      system_prompt: "You are a data analyst...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["canvas", "web_fetch", "exec"]
    },
    %{
      id: "devops",
      name: "DevOps",
      icon: "hero-server-stack",
      description: "Infrastructure, CI/CD, monitoring",
      default_name: "DevOps",
      system_prompt: "You are a DevOps engineer...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "full",
      tools_allow: ["exec", "group:fs", "web_search"]
    },
    %{
      id: "pm",
      name: "Project Manager",
      icon: "hero-clipboard-document-list",
      description: "Planning, tracking, coordination",
      default_name: "PM",
      system_prompt: "You are a project manager...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["canvas", "web_search"]
    },
    %{
      id: "sales",
      name: "Sales",
      icon: "hero-currency-dollar",
      description: "Outreach, proposals, CRM",
      default_name: "Sales",
      system_prompt: "You are a sales professional...",
      model_tier: "mid",
      suggested_model: "anthropic/claude-sonnet-4-6",
      tool_profile: "minimal",
      tools_allow: ["web_search", "web_fetch", "canvas"]
    }
  ]

  def role_templates, do: @role_templates

  def handle("open_onboarding_chooser", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_onboarding_chooser, true)
     |> assign(:onboarding_flow, nil)
     |> assign(:selected_template, nil)
     |> assign(:federate_result, nil)}
  end

  def handle("close_onboarding", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_onboarding_chooser, false)
     |> assign(:onboarding_flow, nil)
     |> assign(:selected_template, nil)
     |> assign(:federate_result, nil)}
  end

  def handle("choose_onboarding", %{"flow" => flow}, socket) do
    socket =
      socket
      |> assign(:show_onboarding_chooser, true)
      |> then(fn socket ->
        case flow do
          "import" ->
            agents =
              case WorkspaceBootstrap.list_configured_agents() do
                {:ok, list} -> list
                {:error, _} -> []
              end

            socket
            |> assign(:onboarding_flow, :import)
            |> assign(:import_agents, agents)
            |> assign(:import_selected, MapSet.new())

          "create" ->
            socket
            |> assign(:onboarding_flow, :create)
            |> assign(:show_create_agent, true)

          _ ->
            assign(socket, :onboarding_flow, String.to_existing_atom(flow))
        end
      end)

    {:noreply, socket}
  end

  def handle("select_template", %{"template_id" => template_id}, socket) do
    template = Enum.find(@role_templates, &(&1.id == template_id))

    {:noreply,
     socket
     |> assign(:selected_template, template)
     |> assign(
       :template_form,
       Phoenix.Component.to_form(%{"name" => (template && template.default_name) || ""},
         as: :template
       )
     )}
  end

  def handle("back_to_templates", _params, socket) do
    {:noreply, assign(socket, :selected_template, nil)}
  end

  def handle("create_from_template", %{"template" => %{"name" => name}}, socket) do
    template = socket.assigns.selected_template

    if is_nil(template) do
      {:noreply, put_flash(socket, :error, "No template selected.")}
    else
      name = String.trim(name)
      slug = slugify(name)

      attrs = %{
        slug: slug,
        name: name,
        status: "active",
        model_config: %{
          "primary" => template.suggested_model,
          "fallbacks" => []
        },
        tools_config: %{
          "profile" => template.tool_profile,
          "allow" => template.tools_allow
        },
        metadata: %{
          "template_id" => template.id,
          "system_prompt" => template.system_prompt
        }
      }

      case %Agent{} |> Agent.changeset(attrs) |> Repo.insert() do
        {:ok, agent} ->
          {:noreply,
           socket
           |> put_flash(:info, "Created #{agent.name} from #{template.name} template.")
           |> assign(:show_onboarding_chooser, false)
           |> assign(:onboarding_flow, nil)
           |> assign(:selected_template, nil)
           |> push_patch(to: ~p"/control/#{agent.slug}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(:template_form, Phoenix.Component.to_form(%{"name" => name}, as: :template))
           |> put_flash(:error, changeset_error_summary(changeset))}
      end
    end
  end

  def handle("create_from_template", _params, socket), do: {:noreply, socket}

  def handle("submit_federate", %{"federate" => params}, socket) do
    runtime_id = String.trim(params["runtime_id"] || "")
    display_name = String.trim(params["display_name"] || "")
    agent_name = String.trim(params["agent_name"] || "")
    owner_id = socket.assigns.current_user_id

    cond do
      runtime_id == "" ->
        {:noreply, put_flash(socket, :error, "Runtime ID is required.")}

      agent_name == "" ->
        {:noreply, put_flash(socket, :error, "Agent name is required.")}

      is_nil(owner_id) ->
        {:noreply, put_flash(socket, :error, "You must be logged in.")}

      true ->
        runtime_attrs = %{
          runtime_id: runtime_id,
          display_name: if(display_name == "", do: nil, else: display_name),
          transport: "websocket",
          status: "pending"
        }

        agent_attrs = %{
          slug: slugify(agent_name),
          name: agent_name,
          status: "active",
          runtime_type: "external"
        }

        with {:ok, runtime} <- Federation.register_runtime(owner_id, runtime_attrs),
             {:ok, agent} <- Federation.link_agent(runtime, agent_attrs),
             {:ok, _runtime, raw_token} <- Federation.activate_runtime(runtime) do
          ws_url = "wss://#{PlatformWeb.Endpoint.host()}/runtime/ws"

          {:noreply,
           socket
           |> assign(:federate_result, %{
             runtime_id: runtime_id,
             token: raw_token,
             ws_url: ws_url,
             agent: agent
           })
           |> put_flash(:info, "Federated agent #{agent.name} created.")}
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, put_flash(socket, :error, changeset_error_summary(changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Federation failed: #{inspect(reason)}")}
        end
    end
  end

  def handle("submit_federate", _params, socket), do: {:noreply, socket}

  def handle("federate_done", _params, socket) do
    agent = get_in(socket.assigns, [:federate_result, :agent])

    socket =
      socket
      |> assign(:show_onboarding_chooser, false)
      |> assign(:onboarding_flow, nil)
      |> assign(:federate_result, nil)

    if agent do
      {:noreply, push_patch(socket, to: ~p"/control/#{agent.slug}")}
    else
      {:noreply, push_patch(socket, to: ~p"/control")}
    end
  end

  def handle("toggle_import_agent", %{"agent_id" => agent_id}, socket) do
    selected = socket.assigns.import_selected

    selected =
      if MapSet.member?(selected, agent_id),
        do: MapSet.delete(selected, agent_id),
        else: MapSet.put(selected, agent_id)

    {:noreply, assign(socket, :import_selected, selected)}
  end

  def handle("submit_import", _params, socket) do
    selected = socket.assigns.import_selected
    agents = socket.assigns.import_agents

    to_import = Enum.filter(agents, &MapSet.member?(selected, &1.id))

    if to_import == [] do
      {:noreply, put_flash(socket, :error, "Select at least one agent to import.")}
    else
      results =
        Enum.map(to_import, fn configured_agent ->
          case WorkspaceBootstrap.ensure_agent(slug: configured_agent.id) do
            {:ok, agent} -> {:ok, agent}
            {:error, reason} -> {:error, configured_agent.id, reason}
          end
        end)

      imported = Enum.count(results, &match?({:ok, _}, &1))
      last_agent = results |> Enum.filter(&match?({:ok, _}, &1)) |> List.last()

      socket =
        socket
        |> put_flash(:info, "Imported #{imported} agent(s).")
        |> assign(:show_onboarding_chooser, false)
        |> assign(:onboarding_flow, nil)

      case last_agent do
        {:ok, agent} -> {:noreply, push_patch(socket, to: ~p"/control/#{agent.slug}")}
        _ -> {:noreply, push_patch(socket, to: ~p"/control")}
      end
    end
  end
end
