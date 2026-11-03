defmodule PlatformWeb.ControlCenter.RuntimePanel do
  @moduledoc """
  Function components for runtime management UI — federation connection
  panel, stat cards, and credential rows.
  """
  use Phoenix.Component

  alias Platform.Agents.Agent
  alias Platform.Access.{Caps, Registry, RuntimeProfiles, Scope}
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
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content">{@label}</p>
      <p class="mt-2 text-2xl font-semibold text-base-content">{@value}</p>
      <p :if={@detail} class="mt-1 text-xs text-subtle">{@detail}</p>
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
          <p class="truncate font-mono text-[11px] text-subtle">{@credential.slug}</p>
        </div>
        <span class="rounded-full bg-base-200 px-2 py-1 text-[11px] uppercase tracking-widest text-subtle">
          {@credential.credential_type}
        </span>
      </div>
      <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-subtle">
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
  attr(:federation_runtime, :any, default: nil)
  attr(:regenerated_token, :string, default: nil)
  attr(:federation_online?, :boolean, default: false)
  attr(:can_manage?, :boolean, default: false)
  attr(:managed?, :boolean, default: false)
  attr(:can_grant?, :boolean, default: false)
  # Not rendered here (the panel lives at the LiveView root, see
  # `grant_panel/1`); passed so the rows re-render when a grant closes it.
  attr(:grant_panel, :map, default: nil)

  def federation_connection_panel(assigns) do
    runtime = assigns.federation_runtime || Federation.get_runtime(assigns.agent.runtime_id)
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

    # The owner cap, read from the same runtime Scope ToolAuthorization uses
    # (task 01a1a2e4-9265 stage 2). Never recomputed here.
    caps = if runtime, do: Caps.for_runtime(runtime), else: %{}
    owner = if runtime, do: Caps.owner(runtime), else: %{user: nil, org_id: nil}

    assigns =
      assigns
      |> assign(:fed_runtime, runtime)
      |> assign(:tool_modules, modules)
      |> assign(:module_choices, module_choices)
      |> assign(:restrictions, restrictions)
      |> assign(:owner_permissions, owner_permissions)
      |> assign(:caps, caps)
      |> assign(:owner_name, owner_name(owner))

    ~H"""
    <div :if={@fed_runtime} class="mt-4 space-y-3">
      <div class="rounded-2xl border border-edge bg-base-200/40 p-4 text-sm">
        <div class="flex items-center justify-between gap-3">
          <span>Connection</span>
          <span class={[
            "inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-semibold uppercase tracking-widest",
            @federation_online? && "bg-success/15 text-success",
            !@federation_online? && "bg-base-content/10 text-subtle"
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
          <span class={
            if @fed_runtime.status == "suspended",
              do: "rounded-full bg-warning/15 px-3 py-1 text-xs font-semibold text-warning",
              else: runtime_badge_class(String.to_existing_atom(@fed_runtime.status))
          }>
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

      <%!-- First-run note (task 01a10322 stage 4): the Pending slot, info fill
           with info-content, above the bundles it explains. Copy verbatim
           from canvas 01a10325-8f2d-7001-b858-b92639451ceb. --%>
      <div
        :if={first_agent_grant?(@fed_runtime)}
        id="first-agent-note"
        class="flex items-start gap-2 rounded-box bg-info px-4 py-3 text-sm text-info-content"
      >
        <span class="hero-information-circle mt-0.5 size-4 shrink-0" aria-hidden="true" />
        <span>
          {@agent.name} is the first agent on this install, so its tool profile starts with the configured modules. Access stays capped at its owner.
        </span>
      </div>

      <div
        class="rounded-2xl border border-edge bg-base-200/40 p-4 text-sm"
        data-role="agent-tool-profile"
      >
        <h3 class="font-semibold">Tool profile</h3>
        <p class="mt-1 text-xs text-subtle">
          Loads only these modules. Never grants access.
        </p>
        <form :if={@can_manage?} phx-submit="save_tool_profile" class="mt-3 space-y-3">
          <div class="grid grid-cols-1 gap-2 sm:grid-cols-2">
            <div :for={module <- @module_choices} class="min-w-0 space-y-1">
              <label
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
              <.bundle_status
                :if={module in @tool_modules}
                module={module}
                capped={Map.get(@caps, module, [])}
                owner_name={@owner_name}
                can_grant?={@can_grant?}
              />
            </div>
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Save tool profile</button>
        </form>
        <div :if={!@can_manage?} class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-2">
          <div :for={module <- @tool_modules} class="min-w-0 space-y-1">
            <code class="rounded bg-base-100 px-2 py-1 text-xs">{module}</code>
            <.bundle_status
              module={module}
              capped={Map.get(@caps, module, [])}
              owner_name={@owner_name}
              can_grant?={@can_grant?}
            />
          </div>
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
        <p :if={!@can_manage?} class="mt-2 text-xs text-subtle">
          {if is_nil(@restrictions),
            do: "Inherits owner's access",
            else: "Allowed: " <> (@restrictions |> Map.keys() |> Enum.sort() |> Enum.join(", "))}
        </p>
      </div>

      <%!-- Regenerated token display --%>
      <div
        :if={@regenerated_token && !@managed?}
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
          data-confirm="Suspend this runtime? This blocks runtime authentication until you unsuspend it."
          class="btn btn-ghost btn-sm"
        >
          Suspend
        </button>
        <button
          :if={@can_manage? and @fed_runtime.status == "suspended"}
          type="button"
          phx-click="unsuspend_federated_runtime"
          class="btn btn-primary btn-sm"
        >
          Unsuspend
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
          :if={@can_manage? and @fed_runtime.status != "revoked" and !@managed?}
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
      class="mt-4 rounded-2xl border border-dashed border-edge px-4 py-5 text-sm text-subtle"
    >
      Runtime record not found.
    </div>
    """
  end

  # ── Bundle status line (task 01a1a2e4-9265 stage 2) ──────────────────
  #
  # Under a bundle that is ON: one warning line per permission the owner cap
  # removes (canvas 01a1a2e4-ef8e), or the info hint when nothing is capped.
  # The toggle itself is never changed. The owner name and the label never
  # truncate; only the mono key does.

  attr(:module, :string, required: true)
  attr(:capped, :list, required: true)
  attr(:owner_name, :string, default: nil)
  attr(:can_grant?, :boolean, default: false)

  defp bundle_status(assigns) do
    ~H"""
    <div :if={@capped != []} class="space-y-1">
      <div
        :for={cap <- @capped}
        data-role="bundle-capped-line"
        data-bundle={@module}
        data-permission={cap.permission}
        class="flex min-w-0 items-start gap-1.5 text-[13px] leading-5 text-base-content"
      >
        <span
          class="hero-exclamation-triangle mt-0.5 size-4 shrink-0 text-warning"
          aria-hidden="true"
        />
        <span class="flex min-w-0 flex-1 flex-wrap items-baseline gap-x-1.5">
          <span :if={@owner_name}>
            On, but capped: {@owner_name} doesn't have "{cap.label}"
          </span>
          <span :if={!@owner_name}>On, but capped by this agent's default member access</span>
          <span
            data-role="capped-permission-key"
            class="min-w-0 max-w-full truncate font-mono text-xs text-subtle"
          >
            {cap.permission}
          </span>
        </span>
      </div>
      <div :if={@owner_name && @can_grant?} class="pl-[22px]">
        <button
          :for={cap <- @capped}
          type="button"
          data-role="bundle-grant-button"
          data-bundle={@module}
          phx-click="open_grant_panel"
          phx-value-bundle={@module}
          phx-value-permission={cap.permission}
          class="btn btn-primary btn-sm"
        >
          Grant…
        </button>
      </div>
      <p
        :if={@owner_name && !@can_grant?}
        data-role="bundle-ask-admin"
        data-bundle={@module}
        class="pl-[22px] text-xs text-subtle"
      >
        Ask an org admin to grant this
      </p>
    </div>
    <p
      :if={@capped == []}
      data-role="bundle-inherited-hint"
      data-bundle={@module}
      class="flex items-center gap-1.5 text-xs text-info"
    >
      <span class="hero-information-circle size-4 shrink-0" aria-hidden="true" /> Inherited from owner
    </p>
    """
  end

  # ── Grant panel (task 01a1a2e4-9265 stage 3) ───────────────────────────
  #
  # A right side panel at lg and up, a bottom sheet below lg only. Rendered
  # at the ControlCenterLive root, outside the tool-profile form (no nested
  # forms) and outside the detail pane, whose containing block would
  # otherwise clip a `fixed` panel. Every event is
  # authorized server-side (ControlCenterLive :access_admin, then RoleAdmin).

  attr(:panel, :map, required: true)

  def grant_panel(assigns) do
    ~H"""
    <div
      id="grant-panel"
      data-role="grant-panel"
      class="fixed inset-0 z-[60] bg-black/40 lg:pointer-events-none lg:bg-transparent"
    >
      <button
        type="button"
        class="absolute inset-0 h-full w-full cursor-default lg:hidden"
        phx-click="close_grant_panel"
        aria-label="Close"
      />
      <div
        role="dialog"
        aria-labelledby="grant-panel-title"
        class={[
          "absolute inset-x-0 bottom-0 w-full max-h-[75vh] overflow-y-auto rounded-t-2xl bg-base-200 p-5 pb-[calc(1.25rem+env(safe-area-inset-bottom))]",
          "lg:pointer-events-auto lg:inset-y-0 lg:left-auto lg:right-0 lg:max-h-none lg:max-w-md lg:rounded-none lg:border-l lg:border-edge lg:shadow-xl"
        ]}
      >
        <form
          id="grant-form"
          phx-change="grant_path_change"
          phx-submit="grant_capped_permission"
          class="space-y-4 text-sm"
        >
          <input type="hidden" name="bundle" value={@panel.bundle} />
          <input type="hidden" name="permission" value={@panel.permission} />
          <h3 id="grant-panel-title" class="font-semibold text-base-content">
            Give {@panel.owner_name} and this agent:
          </h3>
          <p class="text-[13px] text-subtle">
            "{@panel.label}" <span class="font-mono text-xs">{@panel.permission}</span>
          </p>

          <div class="space-y-2">
            <label class="flex items-center gap-2">
              <input
                type="radio"
                name="path"
                value="existing"
                data-role="grant-path-existing"
                checked={@panel.path == "existing"}
                disabled={@panel.roles == []}
                class="radio radio-sm"
              />
              <span>Existing role</span>
            </label>
            <select
              :if={@panel.roles != []}
              name="role_key"
              data-role="grant-existing-role"
              disabled={@panel.path != "existing"}
              class="select select-sm w-full"
            >
              <option
                :for={role <- @panel.roles}
                value={role.key}
                selected={role.key == @panel.role_key}
              >
                {role.name}
              </option>
            </select>
            <p :if={@panel.roles == []} class="pl-6 text-xs text-subtle">
              No existing role has this permission
            </p>
          </div>

          <div class="space-y-2">
            <label class="flex items-center gap-2">
              <input
                type="radio"
                name="path"
                value="new"
                data-role="grant-path-new"
                checked={@panel.path == "new"}
                class="radio radio-sm"
              />
              <span>New role</span>
            </label>
            <div :if={@panel.path == "new"} class="space-y-2 pl-6">
              <input
                type="text"
                name="name"
                value={@panel.new_name}
                placeholder="Role name"
                data-role="grant-new-name"
                class="input input-sm w-full"
              />
              <input type="hidden" name="permissions[]" value="" />
              <label
                :for={opt <- @panel.offered}
                class="flex items-start gap-2"
                data-role="grant-new-permission"
              >
                <input
                  type="checkbox"
                  name="permissions[]"
                  value={opt.permission}
                  checked={opt.permission in @panel.new_permissions}
                  class="checkbox checkbox-sm mt-0.5"
                />
                <span class="min-w-0">
                  <span class="block">{opt.label}</span>
                  <span class="block truncate font-mono text-xs text-subtle">{opt.permission}</span>
                </span>
              </label>
            </div>
          </div>

          <fieldset class="space-y-2">
            <legend class="text-xs font-semibold text-subtle">Applies to:</legend>
            <input type="hidden" name="owner" value="false" />
            <label class="flex items-center gap-2">
              <input
                type="checkbox"
                name="owner"
                value="true"
                checked={@panel.owner?}
                data-role="grant-applies-owner"
                class="checkbox checkbox-sm"
              />
              <span>{@panel.owner_name} (owner)</span>
            </label>
            <input type="hidden" name="agent" value="false" />
            <label class="flex items-center gap-2">
              <input
                type="checkbox"
                name="agent"
                value="true"
                checked={@panel.agent?}
                data-role="grant-applies-agent"
                class="checkbox checkbox-sm"
              />
              <span>{@panel.agent_name} (agent)</span>
            </label>
          </fieldset>

          <p :if={@panel.error} data-role="grant-error" class="text-[13px] text-error" role="alert">
            {@panel.error}
          </p>

          <div class="flex items-center gap-2">
            <button type="submit" data-role="grant-submit" class="btn btn-primary btn-sm">
              Grant
            </button>
            <button type="button" phx-click="close_grant_panel" class="btn btn-ghost btn-sm">
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  defp owner_name(%{user: %{name: name}}) when is_binary(name) and name != "", do: name
  defp owner_name(%{user: %{email: email}}) when is_binary(email), do: email
  defp owner_name(_owner), do: nil

  defp first_agent_grant?(%{metadata: %{"first_agent_grant" => true}}), do: true
  defp first_agent_grant?(_runtime), do: false
end
