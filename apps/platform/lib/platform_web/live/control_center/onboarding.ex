defmodule PlatformWeb.ControlCenter.Onboarding do
  @moduledoc """
  Function components for the onboarding overlay — chooser, template flow,
  federate flow, import flow, and create custom flow.
  """
  use Phoenix.Component

  import PlatformWeb.ControlCenter.Helpers

  attr :show, :boolean, required: true
  attr :onboarding_flow, :atom, default: nil
  attr :selected_template, :map, default: nil
  attr :template_form, :map, required: true
  attr :federate_form, :map, required: true
  attr :federate_result, :map, default: nil
  attr :import_agents, :list, default: []
  attr :import_selected, :any, required: true
  attr :create_agent_form, :map, required: true
  attr :external_agent_form, :map, required: true
  attr :probe_result, :map, default: nil
  attr :role_templates, :list, required: true
  attr :roles, :list, default: []
  attr :role_assignments_by_key, :map, default: %{}
  # "Run on this server" is offered only while an agent host is connected
  # (task 01a10322 stage 4).
  attr :agent_host_connected?, :boolean, default: false

  def overlay(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-base-300/80 backdrop-blur-sm"
    >
      <div class="w-full max-w-2xl px-4 py-8 sm:py-16">
        <div class="rounded-3xl border border-edge bg-base-100 p-6 shadow-xl sm:p-8">
          <div class="flex items-center justify-between">
            <h2 class="text-xl font-semibold text-base-content">
              {cond do
                @federate_result -> "Connection Details"
                @selected_template -> @selected_template.name <> " Template"
                @onboarding_flow == :template -> "Choose a Template"
                @onboarding_flow == :federate -> "Federate an Agent"
                @onboarding_flow == :import -> "Import from Workspace"
                @onboarding_flow == :create -> "Create Custom Agent"
                @onboarding_flow == :external -> "External Agent"
                @onboarding_flow == :native -> "Run on this server"
                true -> "Add Agent"
              end}
            </h2>
            <button
              type="button"
              phx-click="close_onboarding"
              class="btn btn-ghost btn-sm btn-circle"
            >
              <span class="hero-x-mark h-5 w-5" />
            </button>
          </div>

          <.chooser_cards
            :if={is_nil(@onboarding_flow)}
            agent_host_connected?={@agent_host_connected?}
          />

          <.native_flow :if={@onboarding_flow == :native} />

          <.template_flow
            :if={@onboarding_flow == :template}
            selected_template={@selected_template}
            template_form={@template_form}
            role_templates={@role_templates}
          />

          <.federate_flow
            :if={@onboarding_flow == :federate}
            federate_form={@federate_form}
            federate_result={@federate_result}
          />

          <.import_flow
            :if={@onboarding_flow == :import}
            import_agents={@import_agents}
            import_selected={@import_selected}
          />

          <.create_flow
            :if={@onboarding_flow == :create}
            create_agent_form={@create_agent_form}
          />

          <.external_agent_flow
            :if={@onboarding_flow == :external}
            external_agent_form={@external_agent_form}
            probe_result={@probe_result}
            role_templates={@role_templates}
            roles={@roles}
            role_assignments_by_key={@role_assignments_by_key}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :agent_host_connected?, :boolean, default: false

  defp chooser_cards(assigns) do
    ~H"""
    <div class="mt-6 grid gap-4 sm:grid-cols-2">
      <button
        :if={@agent_host_connected?}
        id="choose-native"
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="native"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-edge bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5 sm:col-span-2"
      >
        <span class="hero-server h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Run on this server</span>
        <span class="text-xs text-base-content/60">
          Claude Code on this server. Start, stop and restart it from this page.
        </span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="template"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-edge bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-briefcase h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">From a Template</span>
        <span class="text-xs text-subtle">
          Designer, Researcher, Architect, and more
        </span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="federate"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-edge bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-globe-alt h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Federate</span>
        <span class="text-xs text-subtle">
          Connect an agent from OpenClaw or Claude Code
        </span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="import"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-edge bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-arrow-down-tray h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Import</span>
        <span class="text-xs text-subtle">From an OpenClaw or Claude Code workspace</span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="create"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-edge bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-wrench-screwdriver h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Create Custom</span>
        <span class="text-xs text-subtle">Full manual setup</span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="external"
        class="group relative flex flex-col items-center gap-3 rounded-2xl border-2 border-dashed border-purple-500/60 bg-base-100 px-4 py-6 text-center transition hover:border-purple-500 hover:bg-purple-500/5 sm:col-span-2"
      >
        <span class="absolute -top-2 -right-2 rounded-full bg-purple-500 px-2 py-0.5 text-[10px] font-bold text-white">
          New
        </span>
        <span class="hero-bolt h-8 w-8 text-purple-500" />
        <span class="text-sm font-semibold text-base-content">External Agent</span>
        <span class="text-xs text-subtle">
          OpenAI-compatible (vLLM / llama.cpp / etc.) or Ollama-native — no Burrow-managed runtime.
        </span>
      </button>
    </div>
    """
  end

  # Name and harness, nothing else: the token, the user and the unit are the
  # install's job. Codex CLI stays disabled until suite-cli's `suite codex`
  # has merged, and the server refuses it too
  # (`NativeAgentEvents.available_harnesses/0`).
  defp native_flow(assigns) do
    ~H"""
    <form id="native-agent-form" phx-submit="submit_native" class="mt-6 space-y-4">
      <label class="form-control">
        <span class="mb-1 text-sm font-semibold text-base-content">Name</span>
        <input
          type="text"
          name="native[name]"
          class="input input-bordered w-full"
          placeholder="Ada"
          autocomplete="off"
          required
          autofocus
        />
      </label>

      <fieldset>
        <legend class="mb-1 text-sm font-semibold text-base-content">Harness</legend>
        <div class="grid gap-2 sm:grid-cols-2">
          <label class="flex cursor-pointer items-center gap-3 rounded-field border border-edge px-3 py-3">
            <input
              type="radio"
              name="native[harness]"
              value="claude_code"
              class="radio radio-sm"
              checked
            />
            <span class="text-sm text-base-content">Claude Code</span>
          </label>
          <label class="flex items-center gap-3 rounded-field border border-edge px-3 py-3 opacity-60">
            <input
              type="radio"
              name="native[harness]"
              value="codex"
              class="radio radio-sm"
              disabled
            />
            <span class="text-sm text-base-content">
              Codex CLI <span class="block text-xs text-base-content/60">Not available yet</span>
            </span>
          </label>
        </div>
      </fieldset>

      <button type="submit" class="btn btn-primary w-full">Create and start</button>
    </form>
    """
  end

  attr :selected_template, :map, default: nil
  attr :template_form, :map, required: true
  attr :role_templates, :list, required: true

  defp template_flow(assigns) do
    ~H"""
    <div :if={is_nil(@selected_template)} class="mt-6">
      <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
        <button
          :for={tmpl <- @role_templates}
          type="button"
          phx-click="select_template"
          phx-value-template_id={tmpl.id}
          class="flex flex-col items-center gap-2 rounded-2xl border border-edge bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
        >
          <span class={"#{tmpl.icon} h-6 w-6 text-primary"} />
          <span class="text-sm font-semibold text-base-content">{tmpl.name}</span>
          <span class="text-[11px] text-subtle">{tmpl.description}</span>
        </button>
      </div>
    </div>

    <div :if={@selected_template} class="mt-6">
      <button type="button" phx-click="back_to_templates" class="btn btn-ghost btn-sm mb-4">
        <span class="hero-arrow-left h-4 w-4" /> Back
      </button>
      <.form
        for={@template_form}
        id="template-create-form"
        phx-submit="create_from_template"
        class="space-y-4"
      >
        <div class="rounded-2xl border border-edge bg-base-200/40 px-4 py-3">
          <div class="flex items-center gap-3">
            <span class={"#{@selected_template.icon} h-6 w-6 text-primary"} />
            <div>
              <p class="text-sm font-semibold">{@selected_template.name}</p>
              <p class="text-xs text-subtle">{@selected_template.description}</p>
            </div>
          </div>
          <p class="mt-2 text-xs text-base-content/50">
            Model: {@selected_template.suggested_model} · Tools: {Enum.join(
              @selected_template.tools_allow,
              ", "
            )}
          </p>
        </div>
        <label class="form-control">
          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Agent Name
          </span>
          <input
            type="text"
            name="template[name]"
            value={@template_form[:name].value || ""}
            class="input input-bordered w-full"
            placeholder="e.g. Designer"
            autofocus
          />
        </label>
        <button type="submit" class="btn btn-primary w-full">Create</button>
      </.form>
    </div>
    """
  end

  attr :federate_form, :map, required: true
  attr :federate_result, :map, default: nil

  defp federate_flow(assigns) do
    ~H"""
    <div :if={is_nil(@federate_result)} class="mt-6">
      <.form
        for={@federate_form}
        id="federate-form"
        phx-submit="submit_federate"
        class="space-y-4"
      >
        <label class="form-control">
          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Runtime ID
          </span>
          <input
            type="text"
            name="federate[runtime_id]"
            value={@federate_form[:runtime_id].value || ""}
            class="input input-bordered w-full"
            placeholder="e.g. alex-home-openclaw"
            autofocus
          />
        </label>
        <label class="form-control">
          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Display Name (optional)
          </span>
          <input
            type="text"
            name="federate[display_name]"
            value={@federate_form[:display_name].value || ""}
            class="input input-bordered w-full"
            placeholder="Alex's OpenClaw"
          />
        </label>
        <label class="form-control">
          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Agent Name
          </span>
          <input
            type="text"
            name="federate[agent_name]"
            value={@federate_form[:agent_name].value || ""}
            class="input input-bordered w-full"
            placeholder="Zip"
          />
        </label>
        <button type="submit" class="btn btn-primary w-full">Federate Agent</button>
      </.form>
    </div>

    <div :if={@federate_result} class="mt-6 space-y-4">
      <div class="rounded-2xl border border-warning/40 bg-warning/10 p-4">
        <p class="text-sm font-semibold text-warning-content">
          <span class="hero-exclamation-triangle mr-1 inline-block h-4 w-4 align-text-bottom" />
          Save this token now. It cannot be retrieved later.
        </p>
      </div>

      <div class="space-y-3">
        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Runtime ID
          </p>
          <div class="mt-1 flex items-center gap-2">
            <code class="flex-1 rounded-lg bg-base-200 px-3 py-2 font-mono text-sm">
              {@federate_result.runtime_id}
            </code>
            <button
              type="button"
              id="copy-runtime-id"
              phx-hook="CopyToClipboard"
              data-clipboard-text={@federate_result.runtime_id}
              class="btn btn-ghost btn-sm"
            >
              Copy
            </button>
          </div>
        </div>

        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Auth Token
          </p>
          <div class="mt-1 flex items-center gap-2">
            <code class="flex-1 break-all rounded-lg bg-warning/10 px-3 py-2 font-mono text-xs">
              {@federate_result.token}
            </code>
            <button
              type="button"
              id="copy-auth-token"
              phx-hook="CopyToClipboard"
              data-clipboard-text={@federate_result.token}
              class="btn btn-ghost btn-sm"
            >
              Copy
            </button>
          </div>
        </div>

        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            WebSocket URL
          </p>
          <div class="mt-1 flex items-center gap-2">
            <code class="flex-1 rounded-lg bg-base-200 px-3 py-2 font-mono text-sm">
              {@federate_result.ws_url}
            </code>
            <button
              type="button"
              id="copy-ws-url"
              phx-hook="CopyToClipboard"
              data-clipboard-text={@federate_result.ws_url}
              class="btn btn-ghost btn-sm"
            >
              Copy
            </button>
          </div>
        </div>

        <div>
          <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
            openclaw.json snippet
          </p>
          <pre class="mt-1 overflow-x-auto rounded-lg bg-base-200 p-3 font-mono text-xs leading-5"><code>{federation_config_snippet(@federate_result.ws_url, @federate_result.runtime_id)}</code></pre>
        </div>
      </div>

      <button type="button" phx-click="federate_done" class="btn btn-primary w-full">
        Done
      </button>
    </div>
    """
  end

  attr :import_agents, :list, default: []
  attr :import_selected, :any, required: true

  defp import_flow(assigns) do
    ~H"""
    <div class="mt-6">
      <div
        :if={@import_agents == []}
        class="rounded-2xl border border-dashed border-edge px-4 py-6 text-center text-sm text-subtle"
      >
        No workspace agents found. Mount an OpenClaw workspace with an <code>openclaw.json</code>
        to import agents.
      </div>
      <div :if={@import_agents != []} class="space-y-4">
        <div class="space-y-2">
          <label
            :for={agent <- @import_agents}
            class={[
              "flex cursor-pointer items-center gap-3 rounded-2xl border px-4 py-3 transition",
              MapSet.member?(@import_selected, agent.id) && "border-primary bg-primary/5",
              !MapSet.member?(@import_selected, agent.id) &&
                "border-edge hover:border-primary/30"
            ]}
          >
            <input
              type="checkbox"
              checked={MapSet.member?(@import_selected, agent.id)}
              phx-click="toggle_import_agent"
              phx-value-agent_id={agent.id}
              class="checkbox checkbox-primary checkbox-sm"
            />
            <div>
              <p class="text-sm font-semibold text-base-content">{agent.name}</p>
              <p class="text-xs text-base-content/50">{agent.id}</p>
            </div>
          </label>
        </div>
        <button
          type="button"
          phx-click="submit_import"
          class="btn btn-primary w-full"
          disabled={MapSet.size(@import_selected) == 0}
        >
          Import {MapSet.size(@import_selected)} agent(s)
        </button>
      </div>
    </div>
    """
  end

  attr :create_agent_form, :map, required: true

  defp create_flow(assigns) do
    ~H"""
    <div class="mt-6">
      <.form
        for={@create_agent_form}
        id="create-agent-form"
        phx-submit="create_agent"
        class="space-y-3"
      >
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Name
            </span>
            <input
              type="text"
              name="create_agent[name]"
              value={@create_agent_form[:name].value || ""}
              class="input input-bordered w-full"
              placeholder="Research Agent"
            />
          </label>
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Slug
            </span>
            <input
              type="text"
              name="create_agent[slug]"
              value={@create_agent_form[:slug].value || ""}
              class="input input-bordered w-full"
              placeholder="research-agent"
            />
          </label>
          <label class="form-control sm:col-span-2">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Primary model
            </span>
            <input
              type="text"
              name="create_agent[primary_model]"
              value={@create_agent_form[:primary_model].value || ""}
              class="input input-bordered w-full"
              placeholder="anthropic/claude-sonnet-4-6"
            />
          </label>
        </div>
        <div class="grid gap-3 sm:grid-cols-3">
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Status
            </span>
            <select name="create_agent[status]" class="select select-bordered w-full">
              <option
                :for={status <- ["active", "paused", "archived"]}
                selected={@create_agent_form[:status].value == status}
                value={status}
              >
                {humanize_value(status)}
              </option>
            </select>
          </label>
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Max
            </span>
            <input
              type="number"
              min="1"
              name="create_agent[max_concurrent]"
              value={@create_agent_form[:max_concurrent].value || 1}
              class="input input-bordered w-full"
            />
          </label>
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Sandbox
            </span>
            <select name="create_agent[sandbox_mode]" class="select select-bordered w-full">
              <option
                :for={mode <- ["off", "inherit", "require"]}
                selected={(@create_agent_form[:sandbox_mode].value || "off") == mode}
                value={mode}
              >
                {mode}
              </option>
            </select>
          </label>
        </div>
        <%!-- Color family picker --%>
        <div class="form-control">
          <span class="mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Color family
          </span>
          <div class="flex flex-wrap gap-2">
            <label
              :for={color <- Platform.Agents.ColorPalette.all()}
              class="cursor-pointer"
              title={color.label}
            >
              <input
                type="radio"
                name="create_agent[color]"
                value={color.id}
                class="sr-only peer"
                checked={(@create_agent_form[:color].value || "") == color.id}
              />
              <span
                class={[
                  "flex flex-col items-center gap-1 px-2 py-1.5 rounded-lg border-2 transition-all",
                  "peer-checked:border-current border-transparent hover:border-edge"
                ]}
                style={"color: var(#{color.token});"}
              >
                <span class="w-5 h-5 rounded-full" style={"background: var(#{color.token});"}></span>
                <span class="text-[9px] text-subtle font-medium">{color.label}</span>
              </span>
            </label>
          </div>
        </div>

        <button type="submit" class="btn btn-primary w-full">Create agent</button>
      </.form>
    </div>
    """
  end

  attr :external_agent_form, :map, required: true
  attr :probe_result, :map, default: nil
  attr :role_templates, :list, required: true
  attr :roles, :list, default: []
  attr :role_assignments_by_key, :map, default: %{}

  defp external_agent_flow(assigns) do
    endpoint_kind = assigns.external_agent_form[:endpoint_kind].value || "openai_compat"
    default_behavior = assigns.external_agent_form[:default_behavior].value || "chat"
    vault_mode = assigns.external_agent_form[:vault_mode].value || "paste"
    save_to_vault? = checkbox_truthy?(assigns.external_agent_form[:save_to_vault].value)
    selected_role_key = assigns.external_agent_form[:role_key].value || ""

    vault_options =
      try do
        Platform.Vault.list(scope: {:platform, nil})
      rescue
        _ -> []
      end
      |> Enum.filter(fn cred ->
        cred.credential_type in ["api_key", "token", "bearer"]
      end)

    assigns =
      assigns
      |> Phoenix.Component.assign(:endpoint_kind, endpoint_kind)
      |> Phoenix.Component.assign(:default_behavior, default_behavior)
      |> Phoenix.Component.assign(:vault_mode, vault_mode)
      |> Phoenix.Component.assign(:save_to_vault, save_to_vault?)
      |> Phoenix.Component.assign(:vault_options, vault_options)
      |> Phoenix.Component.assign(:selected_role_key, selected_role_key)

    ~H"""
    <div class="mt-6">
      <div class="mb-4 rounded-2xl border border-dashed border-purple-500/40 bg-purple-500/5 px-4 py-3">
        <p class="text-sm font-semibold text-base-content">External Agent · configure</p>
        <p class="mt-1 text-xs text-subtle">
          Connect an OpenAI-compatible or Ollama-native endpoint. No Burrow-managed runtime — Burrow
          calls the model directly. Credentials are stored in
          <code class="rounded bg-base-200 px-1 py-0.5 font-mono text-[11px]">Platform.Vault</code>
          on submit (vault sub-form lands in stage 3).
        </p>
      </div>

      <.form
        for={@external_agent_form}
        id="external-agent-form"
        phx-change="external_agent_change"
        phx-submit="submit_external"
        class="space-y-4"
      >
        <%!-- Identity row: name + slug --%>
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Display Name
            </span>
            <input
              type="text"
              name="external_agent[name]"
              value={@external_agent_form[:name].value || ""}
              class="input input-bordered w-full"
              placeholder="e.g. Local Llama"
              autofocus
            />
          </label>
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Slug
            </span>
            <input
              type="text"
              name="external_agent[slug]"
              value={@external_agent_form[:slug].value || ""}
              class="input input-bordered w-full font-mono text-sm"
              placeholder="auto-derived from name"
            />
          </label>
        </div>

        <%!-- Endpoint Kind dropdown + conditional help text --%>
        <label class="form-control">
          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Endpoint Kind
          </span>
          <select name="external_agent[endpoint_kind]" class="select select-bordered w-full">
            <option value="openai_compat" selected={@endpoint_kind == "openai_compat"}>
              OpenAI-compatible (Chat Completions)
            </option>
            <option value="ollama_native" selected={@endpoint_kind == "ollama_native"}>
              Ollama-native
            </option>
          </select>
          <span
            :if={@endpoint_kind == "openai_compat"}
            class="mt-1 text-xs text-subtle"
          >
            Use for OpenAI, OpenRouter, Together, vLLM, LM Studio, or any server speaking <code class="font-mono">/v1/chat/completions</code>.
          </span>
          <span
            :if={@endpoint_kind == "ollama_native"}
            class="mt-1 text-xs text-subtle"
          >
            Use for local Ollama installations speaking the native
            <code class="font-mono">/api/chat</code>
            endpoint.
          </span>
        </label>

        <%!-- Base URL + Model --%>
        <div class="grid gap-3 sm:grid-cols-2">
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Base URL
            </span>
            <input
              type="text"
              name="external_agent[base_url]"
              value={@external_agent_form[:base_url].value || ""}
              class="input input-bordered w-full font-mono text-sm"
              placeholder={base_url_placeholder(@endpoint_kind)}
            />
          </label>
          <label class="form-control">
            <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
              Model
            </span>
            <input
              type="text"
              name="external_agent[model]"
              value={@external_agent_form[:model].value || ""}
              class="input input-bordered w-full font-mono text-sm"
              placeholder={model_placeholder(@endpoint_kind)}
            />
          </label>
        </div>

        <%!-- Default Behavior pill row --%>
        <div class="form-control">
          <span class="mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Default Behavior
          </span>
          <div class="flex flex-wrap gap-2">
            <label
              :for={behavior <- ~w(chat dispatch dispatch_and_chat)}
              class="cursor-pointer"
              title={behavior_label(behavior)}
            >
              <input
                type="radio"
                name="external_agent[default_behavior]"
                value={behavior}
                class="sr-only peer"
                checked={@default_behavior == behavior}
              />
              <span class={[
                "inline-flex items-center rounded-full border px-3 py-1 text-xs font-medium transition",
                "border-edge bg-base-100 text-base-content/70 hover:border-primary/50",
                "peer-checked:border-primary peer-checked:bg-primary/10 peer-checked:text-primary"
              ]}>
                {behavior_label(behavior)}
              </span>
            </label>
          </div>
          <span class="mt-1 text-xs text-base-content/50">
            {behavior_description(@default_behavior)}
          </span>
        </div>

        <%!-- Credentials sub-form (stage 3): From-vault / Paste-new tab toggle --%>
        <div class="form-control" id="external-agent-vault">
          <span class="mb-2 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Credentials
          </span>

          <div role="tablist" class="tabs tabs-boxed mb-3 inline-flex">
            <button
              type="button"
              role="tab"
              phx-click="set_vault_mode"
              phx-value-mode="from_vault"
              class={["tab", @vault_mode == "from_vault" && "tab-active"]}
              aria-selected={@vault_mode == "from_vault"}
            >
              From vault
            </button>
            <button
              type="button"
              role="tab"
              phx-click="set_vault_mode"
              phx-value-mode="paste"
              class={["tab", @vault_mode == "paste" && "tab-active"]}
              aria-selected={@vault_mode == "paste"}
            >
              + Paste new
            </button>
          </div>

          <%!-- Hidden field tracks the active mode through form submits --%>
          <input type="hidden" name="external_agent[vault_mode]" value={@vault_mode} />

          <%!-- From-vault mode: <select> of existing platform-scoped credentials --%>
          <div :if={@vault_mode == "from_vault"} class="space-y-2">
            <div
              :if={@vault_options == []}
              class="rounded-lg border border-dashed border-edge bg-base-200/30 px-3 py-3 text-xs text-subtle"
            >
              No vault credentials yet — switch to Paste new.
            </div>
            <select
              :if={@vault_options != []}
              name="external_agent[vault_key]"
              class="select select-bordered w-full font-mono text-sm"
            >
              <option
                value=""
                disabled
                selected={(@external_agent_form[:vault_key].value || "") == ""}
              >
                — Select a vault credential —
              </option>
              <option
                :for={opt <- @vault_options}
                value={opt.slug}
                selected={@external_agent_form[:vault_key].value == opt.slug}
              >
                {opt.name || opt.slug}
              </option>
            </select>
            <%!-- Preserve the paste-mode secret so a round-trip doesn't blank it --%>
            <input
              type="hidden"
              name="external_agent[secret]"
              value={@external_agent_form[:secret].value || ""}
            />
            <%!-- Preserve save_to_vault checkbox state across tab toggle --%>
            <input
              type="hidden"
              name="external_agent[save_to_vault]"
              value={if @save_to_vault, do: "true", else: "false"}
            />
          </div>

          <%!-- Paste-new mode: vault_key + secret + save-to-vault checkbox --%>
          <div :if={@vault_mode == "paste"} class="space-y-3">
            <label class="form-control">
              <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                Name in vault
              </span>
              <input
                type="text"
                name="external_agent[vault_key]"
                value={@external_agent_form[:vault_key].value || ""}
                class="input input-bordered w-full font-mono text-sm"
                placeholder="my-openrouter-key"
                autocomplete="off"
              />
            </label>
            <label class="form-control">
              <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
                Secret
              </span>
              <input
                type="password"
                name="external_agent[secret]"
                value={@external_agent_form[:secret].value || ""}
                class="input input-bordered w-full font-mono text-sm"
                placeholder="••••••••"
                autocomplete="off"
              />
            </label>
            <label class="flex items-center gap-2 text-sm">
              <%!-- Hidden predecessor so an unchecked box submits "false" --%>
              <input type="hidden" name="external_agent[save_to_vault]" value="false" />
              <input
                type="checkbox"
                name="external_agent[save_to_vault]"
                value="true"
                class="checkbox checkbox-primary checkbox-sm"
                checked={@save_to_vault}
              />
              <span>Save to vault on submit</span>
            </label>
            <p class="text-xs text-base-content/50">
              Unchecked = stored only in memory, lost on restart.
            </p>
          </div>
        </div>

        <%!-- Connection Status panel (stage 4) --%>
        <.connection_status_panel probe_result={@probe_result} />

        <%!-- Role assignment (stage 6) --%>
        <div class="form-control" id="external-agent-role">
          <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
            Assign a role (optional)
          </span>
          <select
            name="external_agent[role_key]"
            class="select select-bordered w-full"
            aria-label="Assign a role"
          >
            <option value="" selected={@selected_role_key in [nil, ""]}>
              — Skip role assignment —
            </option>
            <%= for role <- @roles do %>
              <% taken = Map.get(@role_assignments_by_key, role.key) %>
              <option
                value={role.key}
                disabled={not is_nil(taken) and @selected_role_key != role.key}
                selected={@selected_role_key == role.key}
              >
                <%= if taken && @selected_role_key != role.key do %>
                  {role.name} (taken by {taken.name})
                <% else %>
                  {role.name}
                <% end %>
              </option>
            <% end %>
          </select>
          <span class="mt-1 text-xs text-base-content/50">
            Pinning to a role auto-routes its responsibilities to this agent.
          </span>
        </div>

        <button type="submit" class="btn btn-primary w-full">
          Save External Agent
        </button>
      </.form>
    </div>
    """
  end

  attr :probe_result, :map, default: nil

  @doc false
  def connection_status_panel(assigns) do
    ~H"""
    <div
      id="external-agent-connection-status"
      class="rounded-2xl border border-edge bg-base-200/40 p-4"
    >
      <p class="mb-3 text-xs font-semibold uppercase tracking-widest text-base-content/50">
        Connection Status
      </p>

      <%!-- Row 1: probe result pill or muted placeholder --%>
      <div class="mb-2 flex items-center gap-2">
        <span
          :if={is_nil(@probe_result)}
          class="text-xs text-subtle"
        >
          Run probe on save
        </span>
        <span
          :if={@probe_result && @probe_result[:status] == :ok}
          class="badge badge-success badge-sm gap-1"
        >
          <span class="hero-check-circle h-3 w-3" />
          Probe OK · {@probe_result[:model_count]} models · {@probe_result[:latency_ms]}ms
        </span>
        <span
          :if={@probe_result && @probe_result[:status] == :error}
          class="badge badge-error badge-sm gap-1"
        >
          <span class="hero-x-circle h-3 w-3" />
          {probe_error_label(@probe_result[:reason])}
        </span>
      </div>

      <%!-- Row 2: static liveness dot (no first save yet) --%>
      <div class="flex items-center gap-2">
        <span class="inline-block h-2.5 w-2.5 rounded-full bg-base-content/25" />
        <span class="text-xs text-subtle">Not connected yet</span>
      </div>
    </div>
    """
  end

  defp probe_error_label(:unauthorized), do: "Unauthorized (check API key)"
  defp probe_error_label(:http_error), do: "HTTP error from endpoint"
  defp probe_error_label(:timeout), do: "Probe timed out"
  defp probe_error_label(:network_error), do: "Network error (unreachable)"
  defp probe_error_label(other) when is_atom(other), do: "Probe failed: #{Atom.to_string(other)}"
  defp probe_error_label(other), do: "Probe failed: #{inspect(other)}"

  defp checkbox_truthy?(true), do: true
  defp checkbox_truthy?("true"), do: true
  defp checkbox_truthy?("on"), do: true
  defp checkbox_truthy?(nil), do: true
  defp checkbox_truthy?(_), do: false

  defp base_url_placeholder("ollama_native"), do: "http://localhost:11434"
  defp base_url_placeholder(_), do: "https://api.openai.com/v1"

  defp model_placeholder("ollama_native"), do: "llama3.2:latest"
  defp model_placeholder(_), do: "gpt-4o-mini"

  defp behavior_label("chat"), do: "Chat"
  defp behavior_label("dispatch"), do: "Dispatch"
  defp behavior_label("dispatch_and_chat"), do: "Dispatch + Chat"
  defp behavior_label(other), do: other

  defp behavior_description("chat"),
    do: "Responds inline in spaces it's invited to. No autonomous task execution."

  defp behavior_description("dispatch"),
    do: "Picks up dispatched tasks. Silent in chat unless explicitly mentioned."

  defp behavior_description("dispatch_and_chat"),
    do: "Both: chats in spaces and accepts dispatched tasks."

  defp behavior_description(_), do: ""

  defp federation_config_snippet(ws_url, runtime_id) do
    Jason.encode!(
      %{
        "suite" => %{"url" => ws_url, "runtime_id" => runtime_id, "token" => "<paste-token-here>"}
      },
      pretty: true
    )
  end
end
