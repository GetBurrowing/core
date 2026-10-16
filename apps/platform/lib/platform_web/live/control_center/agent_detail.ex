defmodule PlatformWeb.ControlCenter.AgentDetail do
  @moduledoc """
  Function components for the agent detail panel in the Control Center.

  Each component renders a section of the agent detail view — header, stats,
  config form, workspace editor, memory browser, runtime monitor, and vault panel.
  Pure rendering only; no socket access or handle_event clauses.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  import PlatformWeb.ControlCenter.Helpers

  alias PlatformWeb.ControlCenter.AgentAvatarUpload
  alias PlatformWeb.ControlCenter.RuntimePanel
  alias PlatformWeb.ControlCenter.VaultEvents

  # ── Header ────────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :runtime, :map, required: true
  attr :federation_online?, :boolean, required: true
  attr :selected_agent_directory_entry, :map, default: nil
  attr :pending_delete_slug, :string, default: nil
  attr :can_manage?, :boolean, default: false

  def header(assigns) do
    ~H"""
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
      <div class="flex flex-col gap-4 xl:flex-row xl:items-start xl:justify-between">
        <div class="min-w-0">
          <.link patch={~p"/control"} class="btn btn-ghost btn-sm mb-3 w-fit lg:hidden">
            <span class="hero-arrow-left h-4 w-4" /> Back to agents
          </.link>
          <div class="flex flex-wrap items-center gap-3">
            <h1 class="truncate text-2xl font-semibold text-base-content">
              {@agent.name}
            </h1>
            <span class={[
              "inline-block h-2.5 w-2.5 rounded-full",
              agent_online?(@agent, @runtime, @federation_online?) && "bg-success",
              !agent_online?(@agent, @runtime, @federation_online?) &&
                "bg-base-content/25"
            ]} />
            <span class={agent_badge_class(@agent.status)}>
              {humanize_value(@agent.status)}
            </span>
            <span
              :if={@agent.runtime_type != "external"}
              class={runtime_badge_class(@runtime.status)}
            >
              Runtime {humanize_value(@runtime.status)}
            </span>
            <span
              :if={@agent.runtime_type == "external"}
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
          <p class="mt-1 text-sm text-base-content/60">{@agent.slug}</p>
          <div class="mt-3 flex flex-wrap gap-2 text-xs text-base-content/55">
            <span
              :if={@agent.runtime_type == "external"}
              class="inline-flex items-center gap-1 rounded-full bg-info/15 px-2.5 py-1 text-info"
            >
              <span class="hero-globe-alt h-3.5 w-3.5" /> Federated
            </span>
            <span
              :if={@agent.runtime_type != "external"}
              class="rounded-full bg-base-200 px-2.5 py-1"
            >
              {primary_model_label(@agent)}
            </span>
            <span
              :if={@agent.runtime_type != "external"}
              class="rounded-full bg-base-200 px-2.5 py-1"
            >
              sandbox {@agent.sandbox_mode || "off"}
            </span>
            <span
              :if={@agent.runtime_type != "external"}
              class="rounded-full bg-base-200 px-2.5 py-1"
            >
              thinking {blank_fallback(@agent.thinking_default, "default")}
            </span>
          </div>
        </div>

        <div
          :if={@can_manage?}
          id="agent-primary-actions"
          class="grid w-full grid-cols-2 gap-2 sm:w-auto sm:grid-cols-2 xl:grid-cols-4"
        >
          <button
            :if={@agent.runtime_type != "external"}
            id="start-runtime"
            type="button"
            phx-click="start_runtime"
            class="btn btn-primary btn-sm w-full"
            disabled={@runtime.running?}
          >
            Start runtime
          </button>
          <button
            :if={@agent.runtime_type != "external"}
            id="refresh-runtime"
            type="button"
            phx-click="refresh_runtime"
            class="btn btn-ghost btn-sm w-full"
          >
            Refresh runtime
          </button>
          <button
            :if={@agent.runtime_type != "external"}
            id="stop-runtime"
            type="button"
            phx-click="stop_runtime"
            class="btn btn-ghost btn-sm w-full text-error"
            disabled={!@runtime.running?}
          >
            Stop runtime
          </button>
          <button
            :if={@pending_delete_slug != @agent.slug}
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
            :if={@pending_delete_slug == @agent.slug}
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

      <div :if={@pending_delete_slug == @agent.slug} class="mt-3">
        <button type="button" phx-click="cancel_delete_agent" class="btn btn-ghost btn-xs">
          Cancel delete
        </button>
      </div>
    </section>
    """
  end

  # ── Stats ─────────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :runtime, :map, required: true
  attr :federation_online?, :boolean, required: true
  attr :federation_runtime, :map, default: nil
  attr :federation_spaces, :list, default: []
  attr :overview_counts, :map, required: true

  def stats(assigns) do
    ~H"""
    <%!-- Stat cards: federated agents show connection-relevant stats --%>
    <div
      :if={@agent.runtime_type == "external"}
      class="mt-5 grid gap-3 grid-cols-2 sm:grid-cols-3"
    >
      <RuntimePanel.stat_card
        label="Connection"
        value={if(@federation_online?, do: "Online", else: "Offline")}
        detail={if(@federation_online?, do: "websocket active", else: "not connected")}
      />
      <RuntimePanel.stat_card
        label="Trust level"
        value={humanize_value((@federation_runtime && @federation_runtime.trust_level) || "—")}
        detail="permission scope"
      />
      <RuntimePanel.stat_card
        label="Spaces"
        value={length(@federation_spaces)}
        detail="active memberships"
      />
    </div>
    <div
      :if={@agent.runtime_type != "external"}
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
    """
  end

  # ── Federation panels ─────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :config_form, :map, required: true
  attr :uploads, :map, required: true
  attr :regenerated_token, :string, default: nil
  attr :federation_online?, :boolean, required: true
  attr :federation_spaces, :list, default: []
  attr :show_add_space_modal, :boolean, default: false
  attr :available_spaces, :list, default: []
  attr :available_meeting_spaces, :list, default: []
  attr :can_manage?, :boolean, default: false

  def federation_panels(assigns) do
    ~H"""
    <%!-- Federation connection section --%>
    <section
      :if={@agent.runtime_id}
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
    >
      <h2 class="text-lg font-semibold text-base-content">
        <span class="hero-globe-alt mr-1 inline-block h-5 w-5 align-text-bottom" />
        Federation Connection
      </h2>
      <p class="mt-1 text-sm text-base-content/60">
        External runtime linked to this agent.
      </p>
      <RuntimePanel.federation_connection_panel
        agent={@agent}
        regenerated_token={@regenerated_token}
        federation_online?={@federation_online?}
        can_manage?={@can_manage?}
      />
    </section>

    <%!-- Identity and Voice are two CARDS inside ONE form (01a06dff stage 2).
    They are drawn as separate cards because voice describes how the agent
    behaves in a room, not how it connects — but they submit together on
    purpose. `AgentData.config_attrs_from_params/2` builds the FULL attrs map
    from the submitted params and `color` has no fallback to the stored agent
    (`blank_to_nil`), so a SECOND `phx-submit="save_config"` form carrying only
    the voice fields would blank the agent's colour on every voice save — which
    an operator reads as "setting the voice broke the avatar". "Save voice" is
    therefore another submit button of THIS form, and one submit carries name,
    colour and voice together.

    `phx-change`: see the note on the native config form — the avatar
    `live_file_input` needs it to report a picked file. It is also what makes
    the half-set warning on the voice card appear as you type. --%>
    <.form
      :if={@can_manage?}
      for={@config_form}
      id="federated-identity-form"
      phx-submit="save_config"
      phx-change="validate_config"
      class="flex flex-col gap-6"
    >
      <%!-- Identity section --%>
      <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
        <h2 class="text-lg font-semibold text-base-content">
          <span class="hero-identification mr-1 inline-block h-5 w-5 align-text-bottom" /> Identity
        </h2>
        <p class="mt-1 text-sm text-base-content/60">
          How this agent appears in Suite chat. Config and model routing are managed by the remote OpenClaw instance.
        </p>
        <div class="mt-4 space-y-4">
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
          <%!-- Color family picker for federated agents --%>
          <div>
            <span class="mb-2 block text-xs font-semibold uppercase tracking-widest text-base-content/50">
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
                  name="config[color]"
                  value={color.id}
                  class="sr-only peer"
                  checked={(@config_form[:color].value || "") == color.id}
                />
                <span
                  class={[
                    "flex flex-col items-center gap-1 px-2 py-1.5 rounded-lg border-2 transition-all",
                    "peer-checked:border-current border-transparent hover:border-edge"
                  ]}
                  style={"color: #{color.accent};"}
                >
                  <span class="w-5 h-5 rounded-full" style={"background: #{color.accent};"}></span>
                  <span class="text-[9px] text-base-content/60 font-medium">{color.label}</span>
                </span>
              </label>
            </div>
          </div>
          <.avatar_field agent={@agent} uploads={@uploads} />
          <div class="flex justify-stretch sm:justify-end">
            <button type="submit" class="btn btn-neutral w-full sm:w-auto">
              Update identity
            </button>
          </div>
        </div>
      </section>

      <.voice_card agent={@agent} config_form={@config_form} />
    </.form>

    <%!-- Spaces section --%>
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
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
          class="flex items-center justify-between rounded-2xl border border-edge px-4 py-3 text-sm"
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
          class="rounded-2xl border border-dashed border-edge px-4 py-5 text-sm text-base-content/50"
        >
          Not participating in any spaces yet.
        </div>
      </div>

      <button
        :if={@can_manage?}
        type="button"
        phx-click="show_add_space_modal"
        class="btn btn-sm btn-outline mt-3 w-full"
      >
        <span class="hero-plus size-4" /> Add to Space
      </button>
    </section>

    <div
      :if={@can_manage? and @show_add_space_modal}
      class="fixed inset-0 z-50 flex items-center justify-center bg-base-300/60"
    >
      <div class="w-full max-w-md rounded-2xl border border-edge bg-base-100 p-6 shadow-xl">
        <h3 class="mb-4 text-base font-semibold">Add Agent to Space</h3>
        <form phx-submit="add_agent_to_space">
          <div class="form-control mb-4">
            <label class="label"><span class="label-text">Space</span></label>
            <select name="space_id" class="select select-bordered w-full" required>
              <option value="">Select a space...</option>
              <%= for space <- @available_spaces do %>
                <option value={space.id}>{space.name}</option>
              <% end %>
              <optgroup :if={@available_meeting_spaces != []} label="Meetings">
                <%= for space <- @available_meeting_spaces do %>
                  <option value={space.id}>{space.name}</option>
                <% end %>
              </optgroup>
            </select>
          </div>
          <div class="form-control mb-6">
            <label class="label"><span class="label-text">Role</span></label>
            <select name="role" class="select select-bordered w-full">
              <option value="member" selected>Member</option>
              <%!-- `principal` gates @mention eligibility
                    (`attention_router.ex:360`, `role in ["principal",
                    "member"]`) and blocks removal at `shell.html.heex:169`. It
                    has never been a default responder — the old label claimed
                    a behaviour the router does not implement (task 019f9790
                    stage 4). --%>
              <option value="principal">Principal (can be @mentioned)</option>
            </select>
          </div>
          <div class="flex justify-end gap-2">
            <button type="button" phx-click="hide_add_space_modal" class="btn btn-ghost btn-sm">
              Cancel
            </button>
            <button type="submit" class="btn btn-primary btn-sm">Add to Space</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ── Avatar ────────────────────────────────────────────────────────

  @doc """
  Avatar picker for the agent identity forms (task `01a00122` stage 2).

  Sits beside the color picker because it is the same kind of field: both
  decide how this agent is recognised at a glance, and `color` is the
  fallback this control replaces.

  There is deliberately NO URL text field. The rejection of the previous
  plan was explicit that linking off-platform to host a simple image is the
  wrong shape, so the only way in is a file on the operator's machine.

  Remove is not an afterthought either: with upload as the only input, an
  agent that has been given an avatar could never get back to its
  color-and-initials fallback.
  """
  attr :agent, :map, required: true
  attr :uploads, :map, required: true

  def avatar_field(assigns) do
    assigns =
      assigns
      |> assign(:upload, assigns.uploads[AgentAvatarUpload.upload_name()])
      |> assign(:initials, agent_initials(assigns.agent.name))

    ~H"""
    <div id="agent-avatar-field">
      <span class="mb-2 block text-xs font-semibold uppercase tracking-widest text-base-content/50">
        Avatar
      </span>
      <div class="flex flex-wrap items-center gap-4 rounded-2xl border border-edge bg-base-200/50 p-4">
        <div class="flex size-16 shrink-0 items-center justify-center overflow-hidden rounded-full border border-edge bg-base-100">
          <img
            :if={@agent.avatar_url}
            src={@agent.avatar_url}
            alt={"#{@agent.name} avatar"}
            class="size-full object-cover"
            data-avatar-kind="agent"
          />
          <span
            :if={!@agent.avatar_url}
            class="text-sm font-semibold uppercase tracking-wide text-base-content/50"
            data-avatar-kind="agent-fallback"
          >
            {@initials}
          </span>
        </div>

        <div class="min-w-0 flex-1 space-y-2">
          <.live_file_input
            upload={@upload}
            class="file-input file-input-bordered file-input-sm w-full max-w-xs"
          />

          <p class="text-xs text-base-content/60">
            {AgentAvatarUpload.accept_label()} up to {AgentAvatarUpload.max_file_size_label()}.
            The image is saved with the rest of the form.
          </p>

          <div :for={entry <- @upload.entries} class="flex items-center gap-2 text-xs">
            <span class="truncate text-base-content/70">{entry.client_name}</span>
            <%!-- Only for an entry that will actually upload. A rejected
            entry never gets progress, and a full-looking bar under a
            rejection message reads as "it worked". --%>
            <progress
              :if={entry.valid?}
              class="progress progress-primary w-24"
              value={entry.progress}
              max="100"
            >
            </progress>
            <button
              type="button"
              class="btn btn-ghost btn-xs"
              phx-click="cancel_avatar_upload"
              phx-value-ref={entry.ref}
              aria-label="Cancel this upload"
            >
              Cancel
            </button>
          </div>

          <p
            :for={message <- avatar_upload_errors(@upload)}
            class="text-xs text-error"
            data-avatar-upload-error
          >
            {message}
          </p>

          <button
            :if={@agent.avatar_url}
            type="button"
            class="btn btn-ghost btn-xs"
            phx-click="remove_avatar"
          >
            Remove avatar
          </button>
        </div>
      </div>
    </div>
    """
  end

  # Flattens the config-level errors (too many files) and the per-entry
  # errors (not accepted, too large) into one list of operator-facing
  # strings, so the template does not have to nest two comprehensions.
  defp avatar_upload_errors(upload) do
    config_errors = Enum.map(upload_errors(upload), &AgentAvatarUpload.error_message/1)

    entry_errors =
      Enum.flat_map(upload.entries, fn entry ->
        Enum.map(upload_errors(upload, entry), &AgentAvatarUpload.error_message/1)
      end)

    Enum.uniq(config_errors ++ entry_errors)
  end

  defp agent_initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.join()
    |> case do
      "" -> "A"
      initials -> String.upcase(initials)
    end
  end

  defp agent_initials(_name), do: "A"

  # ── Config form ───────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :config_form, :map, required: true
  attr :uploads, :map, required: true
  attr :model_chain_result, :any, required: true
  attr :selected_agent_directory_entry, :map, default: nil

  def config_form(assigns) do
    ~H"""
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-lg font-semibold text-base-content">Config + model routing</h2>
          <p class="mt-1 text-sm text-base-content/60">
            Edit the persisted agent definition. Runtime refresh uses the real AgentServer.
          </p>
        </div>
      </div>

      <%!-- `phx-change` is required by the avatar `live_file_input`: a picked
      file is only reported to the server through the enclosing form's change
      event. --%>
      <.form
        for={@config_form}
        id="agent-config-form"
        phx-submit="save_config"
        phx-change="validate_config"
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

        <.voice_fields config_form={@config_form} />

        <p class="text-xs text-base-content/50">
          Spoken personality lives in this agent's
          <code class="rounded bg-base-200 px-1">{Platform.Agents.Voice.personality_file_key()}</code>
          workspace file below, not here.
        </p>

        <%!-- Color family picker --%>
        <div>
          <span class="mb-2 block text-xs font-semibold uppercase tracking-widest text-base-content/50">
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
                name="config[color]"
                value={color.id}
                class="sr-only peer"
                checked={(@config_form[:color].value || "") == color.id}
              />
              <span
                class={[
                  "flex flex-col items-center gap-1 px-2 py-1.5 rounded-lg border-2 transition-all",
                  "peer-checked:border-current border-transparent hover:border-edge"
                ]}
                style={"color: #{color.accent};"}
              >
                <span class="w-5 h-5 rounded-full" style={"background: #{color.accent};"}></span>
                <span class="text-[9px] text-base-content/60 font-medium">{color.label}</span>
              </span>
            </label>
          </div>
        </div>

        <.avatar_field agent={@agent} uploads={@uploads} />

        <p
          :if={
            @selected_agent_directory_entry &&
              @selected_agent_directory_entry.workspace_managed?
          }
          class="rounded-2xl border border-edge bg-base-200/50 px-3 py-2 text-sm text-base-content/65"
        >
          This agent is sourced from the mounted workspace config. Use the workspace to remove it permanently.
        </p>

        <div class="rounded-2xl border border-edge bg-base-200/50 p-4">
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
    """
  end

  @doc """
  The voice controls for an agent's config form.

  Extracted from `config_form/1` so every surface that offers voice renders
  the same fields (01a06dff). The provider is a select over
  `Platform.Agents.Voice.known_providers/0`, so adding a provider stays one
  entry in that module.
  """
  attr :config_form, :map, required: true

  def voice_fields(assigns) do
    ~H"""
    <%!-- Voice (01a03f4f). The provider is a select over
    `Platform.Agents.Voice.known_providers/0`, NOT a hard-coded vendor
    list here — adding a provider is one entry in that module and this
    control follows it. --%>
    <div class="grid gap-4 md:grid-cols-3">
      <label class="form-control">
        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Voice provider
        </span>
        <.voice_provider_select config_form={@config_form} />
      </label>

      <label class="form-control">
        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Voice ID
        </span>
        <.voice_id_input config_form={@config_form} />
      </label>

      <label class="form-control">
        <span class="mb-1 text-xs font-semibold uppercase tracking-widest text-base-content/50">
          Voice model
        </span>
        <.voice_model_input config_form={@config_form} />
      </label>
    </div>
    """
  end

  @doc """
  The voice card on the external-agent panel (01a06dff stage 2).

  A voice was reachable only from `config_form/1`, which
  `control_center_live.ex` renders solely for `runtime_type != "external"` —
  so every external agent had a voice column nothing in the UI could write.
  This is the same three fields on the branch external agents actually get.

  Two things about it are load-bearing:

  * The effective-voice line reads `Platform.Agents.Voice.config_for/1` on the
    STORED agent, never `@config_form`. A form echoing its own params back is
    the one thing that cannot tell an operator whether the save landed, and
    wiring it to form state would reproduce the class of bug that produced
    this ticket. After a save `save_config_with_avatar/4` re-assigns
    `:selected_agent` from `Repo.update/1`, so this line re-reads the row.
  * There is no `<form>` here. The inputs belong to `federated-identity-form`
    and "Save voice" is one of its submit buttons — see the comment there for
    why a second form would blank the agent's colour.

  Colour is spent deliberately: `--color-info` for the unset state, which is
  the correct permanent state for most agents; `--color-warning` only for the
  genuinely transient half-set one; `--color-error` never, because nothing on
  this card is a failure.
  """
  attr :agent, :map, required: true
  attr :config_form, :map, required: true

  def voice_card(assigns) do
    provider = assigns.config_form[:voice_provider].value |> to_string() |> String.trim()
    voice_id = assigns.config_form[:voice_id].value |> to_string() |> String.trim()

    assigns =
      assigns
      |> assign(:effective_voice, Platform.Agents.Voice.config_for(assigns.agent))
      |> assign(:half_set?, provider != "" and voice_id == "")

    ~H"""
    <section
      data-role="agent-voice-card"
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
    >
      <h2 class="text-[13px] font-semibold text-base-content">
        <span class="hero-speaker-wave mr-1 inline-block h-4 w-4 align-text-bottom" /> Voice
      </h2>

      <%!-- The signature element: what this agent ACTUALLY speaks with right
      now, read back from the stored row. Everything below stays quiet so this
      line reads first. --%>
      <div class="mt-3 border-b border-edge pb-3">
        <p
          :if={is_nil(@effective_voice)}
          data-role="agent-voice-effective"
          class="text-[13px] font-semibold text-info"
        >
          Using the shared fallback voice — sounds identical to every other agent.
        </p>
        <p
          :if={@effective_voice}
          data-role="agent-voice-effective"
          class="flex flex-wrap items-baseline gap-x-1 text-[13px] font-semibold text-base-content"
        >
          <span>Speaking as</span>
          <%!-- An opaque token that gets pasted and compared character by
          character, so it wraps and never truncates. The provider label is
          what gives way when the row is too narrow. --%>
          <span data-role="agent-voice-effective-id" class="break-all font-mono text-[11px]">
            {@effective_voice["voice_id"]}
          </span>
          <span>via</span>
          <span data-role="agent-voice-effective-provider" class="min-w-0 truncate">
            {@effective_voice["provider"]}
          </span>
        </p>
      </div>

      <p class="mt-3 text-[12px] font-normal text-neutral">
        How this agent sounds out loud when it speaks in a meeting room.
      </p>

      <%!-- Provider and voice id share ONE ground because they are one
      setting wearing two inputs: neither is meaningful alone, and
      `AgentData.voice_config_from_params/1` stores both or neither. --%>
      <fieldset class={[
        "mt-3 rounded-field bg-base-200 p-4",
        @half_set? && "border border-warning"
      ]}>
        <div class="grid gap-4 sm:grid-cols-2">
          <label class="form-control min-w-0">
            <span class="mb-1 text-[13px] font-semibold text-base-content">Provider</span>
            <.voice_provider_select config_form={@config_form} />
          </label>

          <label class="form-control min-w-0">
            <span class="mb-1 text-[13px] font-semibold text-base-content">Voice id</span>
            <.voice_id_input
              config_form={@config_form}
              class="input input-bordered w-full font-mono text-[11px]"
            />
            <span class="mt-1 text-[12px] font-normal text-neutral">
              Paste the id from ElevenLabs. Both fields or neither.
            </span>
          </label>
        </div>

        <p
          :if={@half_set?}
          data-role="agent-voice-half-set"
          class="mt-3 text-[12px] font-normal text-warning"
        >
          A provider without a voice id saves as no voice at all.
        </p>
      </fieldset>

      <label class="form-control mt-4 min-w-0 max-w-xs">
        <span class="mb-1 truncate text-[13px] font-semibold text-base-content">Voice model</span>
        <.voice_model_input config_form={@config_form} class="input input-bordered w-full truncate" />
      </label>

      <div class="mt-4 flex justify-stretch sm:justify-end">
        <button type="submit" class="btn btn-neutral w-full sm:w-auto">
          Save voice
        </button>
      </div>
    </section>
    """
  end

  @doc """
  The provider control, shared by every surface that offers a voice.

  One definition so `Voice.known_providers/0` stays the single place a
  provider is added — a second copy of this select is how the built-in form
  and the external card would drift apart.
  """
  attr :config_form, :map, required: true
  attr :class, :string, default: "select select-bordered w-full"

  def voice_provider_select(assigns) do
    ~H"""
    <select name="config[voice_provider]" class={@class}>
      <option value="" selected={(@config_form[:voice_provider].value || "") == ""}>
        No voice
      </option>
      <option
        :for={provider <- Platform.Agents.Voice.known_providers()}
        selected={@config_form[:voice_provider].value == provider}
        value={provider}
      >
        {provider}
      </option>
    </select>
    """
  end

  @doc "The voice id control. `config[voice_id]` is read by `AgentData.voice_config_from_params/1`."
  attr :config_form, :map, required: true
  attr :class, :string, default: "input input-bordered w-full"

  def voice_id_input(assigns) do
    ~H"""
    <input
      type="text"
      name="config[voice_id]"
      value={@config_form[:voice_id].value || ""}
      class={@class}
      placeholder="the provider's voice identifier"
    />
    """
  end

  @doc "The optional voice model control."
  attr :config_form, :map, required: true
  attr :class, :string, default: "input input-bordered w-full"

  def voice_model_input(assigns) do
    ~H"""
    <input
      type="text"
      name="config[voice_model]"
      value={@config_form[:voice_model].value || ""}
      class={@class}
      placeholder="optional"
    />
    """
  end

  # ── Workspace editor ──────────────────────────────────────────────

  attr :workspace_files, :list, required: true
  attr :selected_file_key, :string, default: nil
  attr :selected_workspace_file, :map, default: nil
  attr :workspace_form, :map, required: true

  def workspace_editor(assigns) do
    ~H"""
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
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
                "border-edge bg-base-100 hover:border-primary/30"
            ]}
          >
            <p class="truncate text-sm font-semibold">{workspace_file.file_key}</p>
            <p class="text-xs text-base-content/50">v{workspace_file.version}</p>
          </button>

          <div
            :if={@workspace_files == []}
            class="rounded-2xl border border-dashed border-edge px-3 py-4 text-sm text-base-content/50"
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
              class="rounded-2xl border border-edge bg-base-200/50 px-3 py-2 text-sm text-base-content/70"
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
    """
  end

  # ── Memory browser ────────────────────────────────────────────────

  attr :memory_filter_form, :map, required: true
  attr :recent_memories, :list, required: true
  attr :memory_form, :map, required: true

  def memory_browser(assigns) do
    ~H"""
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
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
              class="rounded-2xl border border-edge bg-base-100 px-4 py-3"
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
              class="rounded-2xl border border-dashed border-edge px-4 py-5 text-sm text-base-content/50"
            >
              Nothing matched this memory filter.
            </div>
          </div>
        </div>

        <.form
          for={@memory_form}
          id="memory-entry-form"
          phx-submit="append_memory"
          class="space-y-3 rounded-2xl border border-edge bg-base-200/40 p-4"
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
    """
  end

  # ── Runtime monitor ───────────────────────────────────────────────

  attr :runtime, :map, required: true
  attr :recent_sessions, :list, required: true

  def runtime_monitor(assigns) do
    ~H"""
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
      <h2 class="text-lg font-semibold text-base-content">Runtime + sessions</h2>
      <p class="mt-1 text-sm text-base-content/60">
        Monitoring reads the real AgentServer state plus persisted session history.
      </p>

      <div class="mt-4 rounded-2xl border border-edge bg-base-200/40 p-4 text-sm text-base-content/75">
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
          class="rounded-2xl border border-edge px-4 py-3 text-sm"
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
          class="rounded-2xl border border-dashed border-edge px-4 py-5 text-sm text-base-content/50"
        >
          No sessions yet.
        </div>
      </div>
    </section>
    """
  end

  # ── Vault panel ───────────────────────────────────────────────────

  attr :agent_credentials, :list, required: true
  attr :platform_credentials, :list, required: true
  attr :all_platform_credentials, :list, default: []
  attr :root_admin?, :boolean, default: false
  attr :show_credential_form, :boolean, default: false
  attr :credential_form, :map, default: %{}

  def vault_panel(assigns) do
    ~H"""
    <section class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
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
              class="rounded-2xl border border-dashed border-edge px-3 py-4 text-sm text-base-content/50"
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
              class="rounded-2xl border border-dashed border-edge px-3 py-4 text-sm text-base-content/50"
            >
              No matching platform credentials for this model chain.
            </div>
          </div>
        </div>

        <%!-- The write surface. Admin-only, and the gate that matters lives in
              `VaultEvents.admin_only/2` — this `:if` only decides whether a
              button is drawn. The list below is deliberately UNFILTERED, unlike
              "Relevant platform credentials" above, which hides anything whose
              provider is outside this agent's model chain: an admin who has
              just added an `elevenlabs` key to an Anthropic agent's page needs
              to see that it landed, not wonder where it went. --%>
        <div :if={@root_admin?} class="border-t border-edge pt-4" data-role="vault-manage">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <p class="text-xs font-semibold uppercase tracking-widest text-base-content/50">
              All platform credentials
            </p>
            <button
              type="button"
              phx-click="toggle_credential_form"
              data-role="toggle-credential-form"
              class="btn btn-xs btn-outline"
            >
              {if @show_credential_form, do: "Cancel", else: "Add or replace"}
            </button>
          </div>

          <div class="mt-2 space-y-2">
            <RuntimePanel.credential_row
              :for={credential <- @all_platform_credentials}
              credential={credential}
            />
            <div
              :if={@all_platform_credentials == []}
              class="rounded-2xl border border-dashed border-edge px-3 py-4 text-sm text-base-content/50"
            >
              No platform credentials yet.
            </div>
          </div>

          <form
            :if={@show_credential_form}
            phx-submit="create_credential"
            data-role="credential-form"
            class="mt-4 space-y-3 rounded-2xl border border-edge bg-base-200/40 p-4"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <div>
                <label
                  class="text-xs font-semibold uppercase text-base-content/60"
                  for="credential-slug"
                >
                  Slug
                </label>
                <input
                  id="credential-slug"
                  name="slug"
                  value={Map.get(@credential_form, "slug", "")}
                  required
                  data-role="credential-slug"
                  class="input input-sm input-bordered w-full font-mono"
                />
                <p class="mt-1 text-xs text-base-content/55">
                  The key agents resolve. An existing slug is replaced, not duplicated.
                </p>
              </div>

              <div>
                <label
                  class="text-xs font-semibold uppercase text-base-content/60"
                  for="credential-name"
                >
                  Name
                </label>
                <input
                  id="credential-name"
                  name="name"
                  value={Map.get(@credential_form, "name", "")}
                  data-role="credential-name"
                  class="input input-sm input-bordered w-full"
                />
                <p class="mt-1 text-xs text-base-content/55">Optional. Defaults to the slug.</p>
              </div>

              <div>
                <label
                  class="text-xs font-semibold uppercase text-base-content/60"
                  for="credential-type"
                >
                  Type
                </label>
                <select
                  id="credential-type"
                  name="credential_type"
                  data-role="credential-type"
                  class="select select-sm select-bordered w-full"
                >
                  <option
                    :for={type <- VaultEvents.credential_types()}
                    value={type}
                    selected={Map.get(@credential_form, "credential_type", "api_key") == type}
                  >
                    {type}
                  </option>
                </select>
              </div>

              <div>
                <label
                  class="text-xs font-semibold uppercase text-base-content/60"
                  for="credential-provider"
                >
                  Provider
                </label>
                <input
                  id="credential-provider"
                  name="provider"
                  value={Map.get(@credential_form, "provider", "")}
                  data-role="credential-provider"
                  class="input input-sm input-bordered w-full"
                />
                <p class="mt-1 text-xs text-base-content/55">
                  Optional. Sets which model chains list this above.
                </p>
              </div>
            </div>

            <div>
              <label
                class="text-xs font-semibold uppercase text-base-content/60"
                for="credential-secret"
              >
                Secret
              </label>
              <%!-- No `value`, ever, and no `phx-change` on this form. The
                    submitted secret is consumed by the write and never enters
                    socket assigns, so there is nothing here to echo back — see
                    `VaultEvents`' moduledoc. There is deliberately no reveal
                    affordance anywhere in this panel: if someone needs the
                    value, they replace it. --%>
              <input
                id="credential-secret"
                name="secret"
                type="password"
                required
                autocomplete="off"
                data-role="credential-secret"
                class="input input-sm input-bordered w-full font-mono"
              />
              <p class="mt-1 text-xs text-base-content/55">
                Write-only. Stored encrypted and never displayed again.
              </p>
            </div>

            <div>
              <label
                class="text-xs font-semibold uppercase text-base-content/60"
                for="credential-expires"
              >
                Expires
              </label>
              <input
                id="credential-expires"
                name="expires_at"
                type="date"
                value={Map.get(@credential_form, "expires_at", "")}
                data-role="credential-expires"
                class="input input-sm input-bordered w-full"
              />
              <p class="mt-1 text-xs text-base-content/55">
                Optional. Surfaces the credential in Platform.Vault.expiring_soon/1.
              </p>
            </div>

            <button type="submit" data-role="credential-submit" class="btn btn-sm btn-primary">
              Save credential
            </button>
          </form>
        </div>
      </div>
    </section>
    """
  end

  # ── Private helpers used by components ────────────────────────────

  defp agent_online?(%{runtime_type: "external"}, _runtime, federation_online?),
    do: federation_online?

  defp agent_online?(_agent, runtime, _federation_online?), do: runtime.running?

  defp runtime_detail(%{running?: true, pid: pid}), do: runtime_pid_label(pid)
  defp runtime_detail(_runtime), do: "not started"

  defp runtime_pid_label(pid) when is_pid(pid), do: inspect(pid)
  defp runtime_pid_label(_pid), do: "stopped"

  defp runtime_sessions_label([]), do: "none"
  defp runtime_sessions_label(ids), do: Enum.map_join(ids, ", ", &short_id/1)

  defp model_chain({:ok, chain}), do: chain
  defp model_chain(_result), do: []
end
