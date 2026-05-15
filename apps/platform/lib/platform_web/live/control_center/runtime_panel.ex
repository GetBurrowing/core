defmodule PlatformWeb.ControlCenter.RuntimePanel do
  @moduledoc """
  Function components for runtime management UI — federation connection
  panel, stat cards, and credential rows.
  """
  use Phoenix.Component

  alias Platform.Agents.{Agent, AgentRuntime}
  alias Platform.Federation

  import PlatformWeb.ControlCenter.Helpers

  # ── Stat card ──────────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :detail, :string, default: nil

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-200/40 px-4 py-3">
      <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">{@label}</p>
      <p class="mt-2 text-2xl font-semibold text-base-content">{@value}</p>
      <p :if={@detail} class="mt-1 text-xs text-base-content/55">{@detail}</p>
    </div>
    """
  end

  # ── Credential row ─────────────────────────────────────────────────

  attr :credential, :map, required: true

  def credential_row(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 px-3 py-3 text-sm">
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

  attr :agent, Agent, required: true
  attr :regenerated_token, :string, default: nil
  attr :federation_online?, :boolean, default: false

  def federation_connection_panel(assigns) do
    runtime = Federation.get_runtime(assigns.agent.runtime_id)
    assigns = assign(assigns, :fed_runtime, runtime)

    ~H"""
    <div :if={@fed_runtime} class="mt-4 space-y-3">
      <div class="rounded-2xl border border-base-300 bg-base-200/40 p-4 text-sm">
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

      <%!-- Allowed bundles editor --%>
      <div class="rounded-2xl border border-base-300 bg-base-200/40 p-4 text-sm">
        <div class="flex items-center justify-between gap-3">
          <span class="font-semibold">Allowed capability bundles</span>
          <span class="text-[11px] uppercase tracking-widest text-base-content/50">
            {length(@fed_runtime.allowed_bundles)} of {length(AgentRuntime.valid_bundles())}
          </span>
        </div>
        <p class="mt-1 text-xs text-base-content/55">
          Scopes both <code>tools/list</code>
          and <code>tools/call</code>
          on the MCP endpoint and federation channel.
        </p>
        <form phx-submit="update_runtime_bundles" class="mt-3 space-y-2">
          <div class="grid grid-cols-2 gap-x-3 gap-y-1.5 sm:grid-cols-3">
            <label
              :for={bundle <- AgentRuntime.valid_bundles()}
              class="inline-flex cursor-pointer items-center gap-2 text-xs"
            >
              <input
                type="checkbox"
                name="bundles[]"
                value={bundle}
                checked={bundle in @fed_runtime.allowed_bundles}
                class="checkbox checkbox-xs"
              />
              <span class="font-mono">{bundle}</span>
            </label>
          </div>
          <div class="flex justify-end">
            <button type="submit" class="btn btn-primary btn-sm">Save bundles</button>
          </div>
        </form>
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
          :if={@fed_runtime.status == "active"}
          type="button"
          phx-click="suspend_federated_runtime"
          class="btn btn-ghost btn-sm"
        >
          Suspend
        </button>
        <button
          :if={@fed_runtime.status != "revoked"}
          type="button"
          phx-click="revoke_federated_runtime"
          class="btn btn-ghost btn-sm text-error"
        >
          Revoke
        </button>
        <button
          :if={@fed_runtime.status != "revoked"}
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
      class="mt-4 rounded-2xl border border-dashed border-base-300 px-4 py-5 text-sm text-base-content/50"
    >
      Runtime record not found.
    </div>
    """
  end
end
