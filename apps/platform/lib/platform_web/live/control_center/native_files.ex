defmodule PlatformWeb.ControlCenter.NativeFiles do
  @moduledoc """
  "Agent files" on a native agent's detail pane: which files the agent host
  writes into the agent's work dir, read-only, with the way to edit them.

  Task 01a10322 stage 5 put an editor here. Task 01a17b1c stage 5 retired its
  write path: every edit now goes through the configuration screen
  (`PlatformWeb.AgentConfigLive`, `/control/:slug/config`) and
  `Platform.Agents.ConfigFiles`, so one gate, one audit trail and one conflict
  check guard these files instead of two.

  A person who cannot manage the agent sees only "Only the agent's owner or an
  admin can edit its files.".

  Pure rendering: no socket, no DB.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: PlatformWeb.Endpoint,
    router: PlatformWeb.Router,
    statics: PlatformWeb.static_paths()

  @locked "Only the agent's owner or an admin can edit its files."

  @doc "What a non-manager sees in place of the file list."
  def locked_message, do: @locked

  attr :agent, :map, required: true
  attr :can_manage?, :boolean, required: true
  attr :workspace_files, :list, required: true

  def summary(assigns) do
    ~H"""
    <section id="native-files" class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-lg font-semibold text-base-content">Agent files</h2>
          <p class="mt-1 text-sm text-subtle">
            Changes apply the next time {@agent.name} starts.
          </p>
        </div>
        <.link
          :if={@can_manage?}
          id="native-files-configure"
          navigate={~p"/control/#{@agent.slug}/config"}
          class="btn btn-sm btn-ghost border border-subtle"
        >
          Edit in Configuration
        </.link>
      </div>

      <p :if={not @can_manage?} id="native-files-locked" class="mt-4 text-sm text-subtle">
        {locked_message()}
      </p>

      <ul :if={@can_manage?} id="native-files-list" class="mt-4 flex flex-col gap-1">
        <li :for={file <- @workspace_files} class="font-mono text-xs text-base-content">
          {file.file_key}
        </li>
      </ul>
    </section>
    """
  end
end
