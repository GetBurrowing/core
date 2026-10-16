defmodule PlatformWeb.ControlCenter.RuntimePanel do
  @moduledoc """
  Function components for runtime management UI — federation connection
  panel, stat cards, and credential rows.
  """
  use Phoenix.Component

  alias Platform.Agents.Agent
  alias Platform.Access.{Registry, RuntimeProfiles, Scope}
  alias Platform.Federation.ToolSurface
  alias Platform.Federation

  import PlatformWeb.ControlCenter.Helpers

  # ── Stat card ──────────────────────────────────────────────────────

  attr(:label, :string, required: true)
  attr(:value, :any, required: true)
  attr(:detail, :string, default: nil)

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-edge bg-base-200/40 px-4 py-3">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">{@label}</p>
      <p class="mt-2 text-2xl font-semibold text-base-content">{@value}</p>
      <p :if={@detail} class="mt-1 text-xs text-base-content/55">{@detail}</p>
    </div>
    """
  end

  # ── Credential row ─────────────────────────────────────────────────

  attr(:credential, :map, required: true)

  def credential_row(assigns) do
    ~H"""
    <div class="rounded-2xl border border-edge px-3 py-3 text-sm">
      <div class="flex flex-wrap items-center justify-between gap-2">
        <div class="min-w-0">
          <p class="truncate font-semibold text-base-content">
            {@credential.name || @credential.slug}
          </p>
          <p class="truncate font-mono text-[11px] text-base-content/45">{@credential.slug}</p>
        </div>
        <span class="rounded-full bg-base-200 px-2 py-1 text-[11px] uppercase tracking-widest text-base-content/55">
          {@credential.credential_type}
        </span>
      </div>
      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/55">
        <span :if={@credential.provider}>provider {@credential.provider}</span>
        <span>scope {@credential.scope_type}</span>
        <span :if={@credential.expires_at}>expires {format_datetime(@credential.expires_at)}</span>
        <span :if={@credential.last_used_at}>
          last used {format_datetime(@credential.last_used_at)}
        </span>
      </div>
    </div>
    """
  end

  # ── Federation connection panel ────────────────────────────────────

  attr(:agent, Agent, required: true)
  attr(:regenerated_token, :string, default: nil)
  attr(:federation_online?, :boolean, default: false)
  attr(:can_manage?, :boolean, default: false)

  def federation_connection_panel(assigns) do
    runtime = Federation.get_runtime(assigns.agent.runtime_id)
    profile = runtime && RuntimeProfiles.get(runtime)
    modules = if runtime, do: RuntimeProfiles.tool_profile(runtime, profile), else: []
    restrictions = if runtime, do: RuntimeProfiles.restrictions(runtime, profile), else: nil
    owner_scope = if runtime, do: Scope.for_user(%{id: runtime.owner_user_id}), else: nil

    owner_permissions =
      if owner_scope,
        do:
          Enum.filter(
            Registry.permission_names(),
            &Platform.Access.holds_anywhere?(owner_scope, &1)
          ),
        else: []

    module_choices = modules ++ (ToolSurface.all_bundles() -- modules)

    assigns =
      assigns
      |> assign(:fed_runtime, runtime)
      |> assign(:tool_modules, modules)
      |> assign(:module_choices, module_choices)
      |> assign(:restrictions, restrictions)
      |> assign(:owner_permissions, owner_permissions)

    ~H"""
    <div :if={@fed_runtime} class="mt-4 space-y-3">
      <div class="rounded-2xl border border-edge bg-base-200/40 p-4 text-sm">
        <div class="flex items-center justify-between gap-3">
          <span>Connection</span>
          <span class={[
            "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-semibold uppercase tracking-widest",
            @federation_online? && "bg-success/15 text-success",
            !@federation_online? && "bg-base-content/10 text-base-content/50"
          ]}>
            <span class={[
              "inline-block h-2 w-2 rounded-full",
              @federation_online? && "bg-success",
              !@federation_online? && "bg-base-content/25"
            ]} />
            {if @federation_online?, do: "Connected", else: "Disconnected"}
          </span>
        </div>
        <div class="mt-2 flex items-center justify-between gap-3">
          <span>Runtime ID</span>
          <code class="font-mono text-xs">{@fed_runtime.runtime_id}</code>
        </div>
        <div class="mt-2 flex items-center justify-between gap-3">
          <span>Status</span>
          <span class={runtime_badge_class(String.to_existing_atom(@fed_runtime.status))}>
            {humanize_value(@fed_runtime.status)}
          </span>
        </div>
        <div class="mt-2 flex items-center justify-between gap-3">
          <span>Trust level</span>
          <span class="rounded-full bg-base-200 px-2 py-0.5 text-xs">
            {humanize_value(@fed_runtime.trust_level)}
          </span>
        </div>
        <div class="mt-2 flex items-center justify-between gap-3">
          <span>Transport</span>
          <span class="text-xs">{@fed_runtime.transport}</span>
        </div>
        <div :if={@fed_runtime.last_connected_at} class="mt-2 flex items-center justify-between gap-3">
          <span>Last connected</span>
          <span class="text-xs">{format_datetime(@fed_runtime.last_connected_at)}</span>
        </div>
      </div>

      <div
        class="rounded-2xl border border-edge bg-base-200/40 p-4 text-sm"
        data-role="agent-tool-profile"
      >
        <h3 class="font-semibold">Tool profile</h3>
        <p class="mt-1 text-xs text-base-content/55">
          Loads only these modules. Never grants access.
        </p>
        <form :if={@can_manage?} phx-submit="save_tool_profile" class="mt-3 space-y-3">
          <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
            <label
              :for={module <- @module_choices}
              class="flex items-center gap-2 text-xs"
              data-role={if module in ToolSurface.all_bundles(), do: nil, else: "orphan-bundle"}
            >
              <input
                :if={module not in ToolSurface.all_bundles()}
                type="hidden"
                name="modules[]"
                value={module}
              />
              <input
                type="checkbox"
                name="modules[]"
                value={module}
                checked={module in @tool_modules}
                disabled={module not in ToolSurface.all_bundles()}
                class="checkbox checkbox-xs"
              />
              <span class="break-all font-mono">{module}</span>
              <span :if={module not in ToolSurface.all_bundles()}>(module not installed)</span>
            </label>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Save tool profile</button>
        </form>
        <div :if={!@can_manage?} class="mt-2 flex flex-wrap gap-2">
          <code :for={module <- @tool_modules} class="rounded bg-base-100 px-2 py-1 text-xs">
            {module}
          </code>
        </div>
      </div>

      <div class="rounded-2xl border border-edge bg-base-200/40 p-4 text-sm">
        <h3 class="font-semibold">Restrict this agent</h3>
        <form :if={@can_manage?} phx-submit="save_agent_restrictions" class="mt-3 space-y-3">
          <input type="hidden" name="inherit" value="false" />
          <input
            id="agent-inherit-access"
            type="checkbox"
            name="inherit"
            value="true"
            checked={is_nil(@restrictions)}
            class="checkbox checkbox-xs peer"
            data-role="agent-restrict-toggle"
          />
          <label for="agent-inherit-access" class="ml-2 text-xs">Inherit owner's access</label>
          <div class="grid grid-cols-1 gap-2 peer-checked:hidden sm:grid-cols-2">
            <label :for={permission <- @owner_permissions} class="flex items-center gap-2 text-xs">
              <input
                type="checkbox"
                name="permissions[]"
                value={permission}
                checked={is_nil(@restrictions) or Map.has_key?(@restrictions, permission)}
                data-role="agent-restrict-permission"
                class="checkbox checkbox-xs"
              />
              <span class="break-all font-mono">{permission}</span>
            </label>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Save restriction</button>
        </form>
        <p :if={!@can_manage?} class="mt-2 text-xs text-base-content/60">
          {if is_nil(@restrictions),
            do: "Inherits owner's access",
            else: "Allowed: " <> (@restrictions |> Map.keys() |> Enum.sort() |> Enum.join(", "))}
        </p>
      </div>

      <%!-- Regenerated token display --%>
      <div
        :if={@regenerated_token}
        class="rounded-2xl border border-warning/40 bg-warning/10 p-4 space-y-2"
      >
        <p class="text-sm font-semibold text-warning-content">
          <span class="hero-exclamation-triangle mr-1 inline-block h-4 w-4 align-text-bottom" />
          New token generated. Save it now.
        </p>
        <div class="flex items-center gap-2">
          <code class="flex-1 break-all rounded-lg bg-warning/10 px-3 py-2 font-mono text-xs">
            {@regenerated_token}
          </code>
          <button
            type="button"
            id="copy-regen-token"
            phx-hook="CopyToClipboard"
            data-clipboard-text={@regenerated_token}
            class="btn btn-ghost btn-sm"
          >
            Copy
          </button>
        </div>
        <button type="button" phx-click="dismiss_regenerated_token" class="btn btn-ghost btn-xs">
          Dismiss
        </button>
      </div>

      <div class="flex flex-wrap gap-2">
        <button
          :if={@can_manage? and @fed_runtime.status == "active"}
          type="button"
          phx-click="suspend_federated_runtime"
          class="btn btn-ghost btn-sm"
        >
          Suspend
        </button>
        <button
          :if={@can_manage? and @fed_runtime.status != "revoked"}
          type="button"
          phx-click="revoke_federated_runtime"
          class="btn btn-ghost btn-sm text-error"
        >
          Revoke
        </button>
        <button
          :if={@can_manage? and @fed_runtime.status != "revoked"}
          type="button"
          phx-click="regenerate_federated_token"
          class="btn btn-ghost btn-sm"
        >
          Regenerate Token
        </button>
      </div>
    </div>

    <div
      :if={is_nil(@fed_runtime)}
      class="mt-4 rounded-2xl border border-dashed border-edge px-4 py-5 text-sm text-base-content/50"
    >
      Runtime record not found.
    </div>
    """
  end
end
