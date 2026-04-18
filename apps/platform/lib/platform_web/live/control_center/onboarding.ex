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
  attr :role_templates, :list, required: true

  def overlay(assigns) do
    ~H"""
    <div
      :if={@show}
      class="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-base-300/80 backdrop-blur-sm"
    >
      <div class="w-full max-w-2xl px-4 py-8 sm:py-16">
        <div class="rounded-3xl border border-base-300 bg-base-100 p-6 shadow-xl sm:p-8">
          <div class="flex items-center justify-between">
            <h2 class="text-xl font-semibold text-base-content">
              {cond do
                @federate_result -> "Connection Details"
                @selected_template -> @selected_template.name <> " Template"
                @onboarding_flow == :template -> "Choose a Template"
                @onboarding_flow == :federate -> "Federate an Agent"
                @onboarding_flow == :import -> "Import from Workspace"
                @onboarding_flow == :create -> "Create Custom Agent"
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

          <.chooser_cards :if={is_nil(@onboarding_flow)} />

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
        </div>
      </div>
    </div>
    """
  end

  defp chooser_cards(assigns) do
    ~H"""
    <div class="mt-6 grid gap-4 sm:grid-cols-2">
      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="template"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-base-300 bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-briefcase h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">From a Template</span>
        <span class="text-xs text-base-content/55">
          Designer, Researcher, Architect, and more
        </span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="federate"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-base-300 bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-globe-alt h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Federate</span>
        <span class="text-xs text-base-content/55">
          Connect an agent from OpenClaw or Claude Code
        </span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="import"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-base-300 bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-arrow-down-tray h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Import</span>
        <span class="text-xs text-base-content/55">From an OpenClaw or Claude Code workspace</span>
      </button>

      <button
        type="button"
        phx-click="choose_onboarding"
        phx-value-flow="create"
        class="group flex flex-col items-center gap-3 rounded-2xl border border-base-300 bg-base-100 px-4 py-6 text-center transition hover:border-primary/40 hover:bg-primary/5"
      >
        <span class="hero-wrench-screwdriver h-8 w-8 text-primary" />
        <span class="text-sm font-semibold text-base-content">Create Custom</span>
        <span class="text-xs text-base-content/55">Full manual setup</span>
      </button>
    </div>
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
          class="flex flex-col items-center gap-2 rounded-2xl border border-base-300 bg-base-100 px-3 py-4 text-center transition hover:border-primary/40 hover:bg-primary/5"
        >
          <span class={"#{tmpl.icon} h-6 w-6 text-primary"} />
          <span class="text-sm font-semibold text-base-content">{tmpl.name}</span>
          <span class="text-[11px] text-base-content/55">{tmpl.description}</span>
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
        <div class="rounded-2xl border border-base-300 bg-base-200/40 px-4 py-3">
          <div class="flex items-center gap-3">
            <span class={"#{@selected_template.icon} h-6 w-6 text-primary"} />
            <div>
              <p class="text-sm font-semibold">{@selected_template.name}</p>
              <p class="text-xs text-base-content/55">{@selected_template.description}</p>
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
            placeholder="e.g. rowan-home-openclaw"
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
            placeholder="Rowan's OpenClaw"
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
        class="rounded-2xl border border-dashed border-base-300 px-4 py-6 text-center text-sm text-base-content/55"
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
                "border-base-300 hover:border-primary/30"
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
                  "peer-checked:border-current border-transparent hover:border-base-300"
                ]}
                style={"color: #{color.accent};"}
              >
                <span class="w-5 h-5 rounded-full" style={"background: #{color.accent};"}></span>
                <span class="text-[9px] text-base-content/60 font-medium">{color.label}</span>
              </span>
            </label>
          </div>
        </div>

        <button type="submit" class="btn btn-primary w-full">Create agent</button>
      </.form>
    </div>
    """
  end

  defp federation_config_snippet(ws_url, runtime_id) do
    Jason.encode!(
      %{
        "suite" => %{"url" => ws_url, "runtime_id" => runtime_id, "token" => "<paste-token-here>"}
      },
      pretty: true
    )
  end
end
