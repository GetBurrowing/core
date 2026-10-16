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
  alias Platform.ExternalAgents
  alias Platform.ExternalAgents.EphemeralCredentials
  alias Platform.Federation
  alias Platform.Repo
  alias Platform.Roles
  alias Platform.Vault
  alias PlatformWeb.ControlCenter.AgentData

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

  @doc """
  Delegates to `AgentData.default_external_agent_params/0` — kept here as a
  back-compat shim so other modules that imported this name keep compiling.
  """
  defdelegate default_external_agent_params, to: AgentData

  @doc """
  Handle one Control Center onboarding event, dispatched on the event name.

  Clauses cover the onboarding chooser, the template flow, the federate flow,
  and the External Agent form (change / vault-mode tab / submit). Each event
  that takes params has a permissive trailing clause returning the socket
  unchanged, so a malformed payload is a no-op rather than a crash.

  The reasoning specific to a clause is a comment on that clause: `@doc` is
  per name/arity, so a second one is discarded by the compiler rather than
  appended, and the per-clause notes were previously being dropped silently.
  """
  def handle("open_onboarding_chooser", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_onboarding_chooser, true)
     |> assign(:onboarding_flow, nil)
     |> assign(:selected_template, nil)
     |> assign(:federate_result, nil)
     |> assign(:probe_result, nil)}
  end

  def handle("close_onboarding", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_onboarding_chooser, false)
     |> assign(:onboarding_flow, nil)
     |> assign(:selected_template, nil)
     |> assign(:federate_result, nil)
     |> assign(:probe_result, nil)}
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

          "native" ->
            assign(socket, :onboarding_flow, :native)

          "external" ->
            socket
            |> assign(:onboarding_flow, :external)
            |> assign(:external_agent_form, AgentData.build_external_agent_form())
            |> assign(:probe_result, nil)

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

    cond do
      runtime_id == "" ->
        {:noreply, put_flash(socket, :error, "Runtime ID is required.")}

      agent_name == "" ->
        {:noreply, put_flash(socket, :error, "Agent name is required.")}

      is_nil(socket.assigns.current_user_id) ->
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

        # One transaction: register, link, activate (task 01a10322 stage 1).
        # A failed link or activation no longer leaves a pending runtime row.
        case Federation.provision_agent_runtime(
               socket.assigns.access_scope,
               agent_attrs,
               runtime_attrs
             ) do
          {:ok, agent, _runtime, raw_token} ->
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

  # `phx-change` cycle for the External Agent form. Auto-slugifies the slug
  # from the display name when slug is blank or matches the prior auto-slug,
  # and keeps every other entered value intact (full round-trip through
  # `to_form`). Stage-3 adds vault sub-form fields (`vault_mode`, `vault_key`,
  # `secret`, `save_to_vault`) which round-trip the same way.
  def handle("external_agent_change", %{"external_agent" => params}, socket) do
    prior = current_external_agent_params(socket)

    name_in = String.trim(Map.get(params, "name", ""))
    slug_in = String.trim(Map.get(params, "slug", ""))

    prior_name = String.trim(Map.get(prior, "name", ""))
    prior_slug = String.trim(Map.get(prior, "slug", ""))

    derived =
      cond do
        # User edited the slug directly — respect their value.
        slug_in != prior_slug -> slug_in
        # Slug is blank or was auto-derived from prior name — re-derive.
        slug_in == "" or slug_in == slugify(prior_name) -> slugify(name_in)
        true -> slug_in
      end

    next_params =
      prior
      |> Map.merge(params)
      |> Map.put("slug", derived)
      |> normalize_save_to_vault(params)

    {:noreply,
     assign(socket, :external_agent_form, AgentData.build_external_agent_form(next_params))}
  end

  def handle("external_agent_change", _params, socket), do: {:noreply, socket}

  # Tab toggle in the Vault sub-form. Updates `vault_mode` in the form params
  # without touching any other entered value (no DB hit). Round-trips through
  # `to_form` so subsequent renders pick up the new mode while preserving
  # vault_key / secret / save_to_vault and every other field.
  #
  # This is the regression e2e case B exercises — tabbing back and forth
  # cannot blank inputs the user already filled in.
  def handle("set_vault_mode", %{"mode" => mode}, socket) when mode in ["from_vault", "paste"] do
    next_params =
      socket
      |> current_external_agent_params()
      |> Map.put("vault_mode", mode)

    {:noreply,
     assign(socket, :external_agent_form, AgentData.build_external_agent_form(next_params))}
  end

  def handle("set_vault_mode", _params, socket), do: {:noreply, socket}

  # Submit the External Agent form (stage 4 — full wiring).
  #
  # Pipeline:
  #   1. Build agent attrs from form params (forces `kind: "external"` via
  #      `Platform.ExternalAgents.create_external_agent/1`).
  #   2. On changeset error → re-render form with errors via flash.
  #   3. On insert success → write the credential branch:
  #      * paste + save_to_vault=true → `Platform.Vault.put_inline/2`
  #      * paste + save_to_vault=false → `EphemeralCredentials.put/2`
  #      * from_vault → no write (credential already exists)
  #   4. Run `Platform.ExternalAgents.probe/1`. Failure does NOT roll back —
  #      we keep the agent, assign `:probe_result` with the error, and flash
  #      a warning. The user can re-probe later from agent detail.
  #   5. Close modal + push_patch to the new agent's control-center page.
  def handle("submit_external", %{"external_agent" => params}, socket) do
    attrs = build_external_agent_attrs(params)

    case ExternalAgents.create_external_agent(attrs) do
      {:ok, agent} ->
        :ok = persist_credential(agent, params)
        probe_outcome = ExternalAgents.probe(agent)
        probe_assigns = probe_outcome_to_assigns(probe_outcome)
        role_flash = maybe_assign_role(params, agent)

        socket =
          socket
          |> assign(:probe_result, probe_assigns)
          |> assign(:show_onboarding_chooser, false)
          |> assign(:onboarding_flow, nil)
          |> assign(:selected_template, nil)
          |> assign(:federate_result, nil)
          |> assign(:external_agent_form, AgentData.build_external_agent_form())
          |> probe_outcome_flash(probe_outcome, agent)
          |> apply_role_flash(role_flash)
          |> push_patch(to: ~p"/control/#{agent.slug}")

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:external_agent_form, AgentData.build_external_agent_form(params))
         |> put_flash(:error, changeset_error_summary(changeset))}
    end
  end

  def handle("submit_external", _params, socket), do: {:noreply, socket}

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

  defp build_external_agent_attrs(params) do
    name = String.trim(Map.get(params, "name", ""))
    slug_in = String.trim(Map.get(params, "slug", ""))
    slug = if slug_in == "", do: slugify(name), else: slugify(slug_in)
    behavior = Map.get(params, "default_behavior", "chat")

    %{
      name: name,
      slug: slug,
      status: "active",
      endpoint_kind: Map.get(params, "endpoint_kind", "openai_compat"),
      base_url: String.trim(Map.get(params, "base_url", "")),
      model: String.trim(Map.get(params, "model", "")),
      vault_key: vault_key_for_attrs(params),
      metadata: %{"default_behavior" => behavior}
    }
  end

  # Decision: vault_key on the row is set when:
  #   * vault_mode == "paste" AND save_to_vault is truthy → persist the
  #     pasted key into Vault, store it as the row's vault_key reference.
  #   * vault_mode == "from_vault" → user picked an existing vault slug.
  # Otherwise (ephemeral path) → vault_key stays nil and the secret is
  # written to ETS keyed by the *new* agent's id (handled in
  # persist_credential/2 after the row exists).
  defp vault_key_for_attrs(params) do
    case Map.get(params, "vault_mode", "paste") do
      "from_vault" ->
        case String.trim(Map.get(params, "vault_key", "")) do
          "" -> nil
          key -> key
        end

      "paste" ->
        if truthy?(Map.get(params, "save_to_vault", true)) do
          case String.trim(Map.get(params, "vault_key", "")) do
            "" -> nil
            key -> key
          end
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp persist_credential(agent, params) do
    secret = Map.get(params, "secret", "")
    vault_key = String.trim(Map.get(params, "vault_key", ""))
    mode = Map.get(params, "vault_mode", "paste")
    save? = truthy?(Map.get(params, "save_to_vault", true))

    cond do
      mode == "paste" and save? and vault_key != "" and is_binary(secret) and secret != "" ->
        case Vault.put_inline(vault_key, secret) do
          {:ok, _credential} -> :ok
          # Don't fail the whole submit on a vault write hiccup — surface
          # via probe/agent detail instead. Tests cover the happy path.
          {:error, _changeset} -> :ok
        end

      mode == "paste" and is_binary(secret) and secret != "" ->
        EphemeralCredentials.put(agent.id, secret)

      true ->
        :ok
    end
  end

  defp probe_outcome_to_assigns({:ok, %{latency_ms: latency_ms, model_count: model_count}}) do
    %{status: :ok, latency_ms: latency_ms, model_count: model_count}
  end

  defp probe_outcome_to_assigns({:error, reason}) do
    %{status: :error, reason: reason}
  end

  defp probe_outcome_flash(socket, {:ok, _}, agent) do
    put_flash(socket, :info, "Created #{agent.name} · probe OK.")
  end

  defp probe_outcome_flash(socket, {:error, reason}, agent) do
    # The layout's flash_group only renders :info and :error — there's
    # no :warning channel today. Use :error so the user sees the failure;
    # the wording captures the "saved anyway" softening.
    put_flash(
      socket,
      :error,
      "Probe failed: #{Atom.to_string(reason)}. #{agent.name} saved anyway."
    )
  end

  # Optionally pin the new agent to a role if the form's role_key field
  # carried a value. Returns one of `:noop`, `{:ok, role_key}`, or
  # `{:error, role_key, reason}` so the caller can surface a flash
  # without nesting more conditionals.
  defp maybe_assign_role(params, %Agent{} = agent) do
    case params |> Map.get("role_key", "") |> to_string() |> String.trim() do
      "" ->
        :noop

      role_key ->
        case Roles.assign_role(role_key, agent.id) do
          {:ok, _assignment} ->
            {:ok, role_key}

          {:error, _changeset} ->
            {:error, role_key, :already_assigned}
        end
    end
  end

  defp apply_role_flash(socket, :noop), do: socket

  defp apply_role_flash(socket, {:ok, role_key}) do
    put_flash(socket, :info, "Pinned to role #{role_key}.")
  end

  defp apply_role_flash(socket, {:error, role_key, :already_assigned}) do
    put_flash(
      socket,
      :error,
      "Role #{role_key} is already filled — unassign the current agent in the Roles tab first."
    )
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("on"), do: true
  defp truthy?(false), do: false
  defp truthy?("false"), do: false
  defp truthy?(nil), do: false
  defp truthy?(_), do: false

  defp current_external_agent_params(socket) do
    case socket.assigns[:external_agent_form] do
      %Phoenix.HTML.Form{params: params} when is_map(params) -> params
      _ -> AgentData.default_external_agent_params()
    end
  end

  # When the change event includes any vault sub-form key, the
  # `save_to_vault` checkbox must be respected literally — Phoenix omits
  # unchecked boxes from the form payload. We detect that the user
  # *interacted* with the vault sub-form (by checking for `vault_mode` or
  # `vault_key` in the incoming params) and treat a missing key as
  # explicitly unchecked.
  defp normalize_save_to_vault(merged, raw_params) do
    interacted? =
      Map.has_key?(raw_params, "vault_mode") or Map.has_key?(raw_params, "vault_key") or
        Map.has_key?(raw_params, "secret") or Map.has_key?(raw_params, "save_to_vault")

    cond do
      not interacted? ->
        merged

      Map.has_key?(raw_params, "save_to_vault") ->
        Map.put(merged, "save_to_vault", truthy_checkbox?(raw_params["save_to_vault"]))

      true ->
        Map.put(merged, "save_to_vault", false)
    end
  end

  defp truthy_checkbox?(true), do: true
  defp truthy_checkbox?("true"), do: true
  defp truthy_checkbox?("on"), do: true
  defp truthy_checkbox?(_), do: false
end
