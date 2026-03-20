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

  alias PlatformWeb.ControlCenter.RuntimePanel

  # ── Header ────────────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :runtime, :map, required: true
  attr :federation_online?, :boolean, required: true
  attr :selected_agent_directory_entry, :map, default: nil
  attr :pending_delete_slug, :string, default: nil

  def header(assigns) do
    ~H"""
    <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
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
  attr :regenerated_token, :string, default: nil
  attr :federation_online?, :boolean, required: true
  attr :federation_spaces, :list, default: []

  def federation_panels(assigns) do
    ~H"""
    <%!-- Federation connection section --%>
    <section
      :if={@agent.runtime_id}
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
        agent={@agent}
        regenerated_token={@regenerated_token}
        federation_online?={@federation_online?}
      />
    </section>

    <%!-- Identity section --%>
    <section class="rounded-3xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <h2 class="text-lg font-semibold text-base-content">
        <span class="hero-identification mr-1 inline-block h-5 w-5 align-text-bottom" /> Identity
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
    """
  end

  # ── Config form ───────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :config_form, :map, required: true
  attr :model_chain_result, :any, required: true
  attr :selected_agent_directory_entry, :map, default: nil

  def config_form(assigns) do
    ~H"""
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
    """
  end

  # ── Workspace editor ──────────────────────────────────────────────

  attr :workspace_files, :list, required: true
  attr :selected_file_key, :string, default: nil
  attr :selected_workspace_file, :map, default: nil
  attr :workspace_form, :map, required: true

  def workspace_editor(assigns) do
    ~H"""
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
    """
  end

  # ── Memory browser ────────────────────────────────────────────────

  attr :memory_filter_form, :map, required: true
  attr :recent_memories, :list, required: true
  attr :memory_form, :map, required: true

  def memory_browser(assigns) do
    ~H"""
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
    """
  end

  # ── Runtime monitor ───────────────────────────────────────────────

  attr :runtime, :map, required: true
  attr :recent_sessions, :list, required: true

  def runtime_monitor(assigns) do
    ~H"""
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
    """
  end

  # ── Vault panel ───────────────────────────────────────────────────

  attr :agent_credentials, :list, required: true
  attr :platform_credentials, :list, required: true

  def vault_panel(assigns) do
    ~H"""
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
