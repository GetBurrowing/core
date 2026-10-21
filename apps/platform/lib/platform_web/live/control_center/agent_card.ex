defmodule PlatformWeb.ControlCenter.AgentCard do
  @moduledoc """
  Function component for a single agent directory entry in the sidebar list.

  Native (install-managed) and federated agents share ONE row shape (task
  01a10322 stage 4, design canvas 01a10325-8f2d-7001-b858-b92639451ceb): a
  dot, the name, one meta line. The kind of agent lives in the meta line
  ("Claude Code on this server · <model>" / "Federated from <runtime>"), not
  in a pill, so the two read as equals.

  A tag appears only on an exception, and a row carries at most one
  contextual button (Log in, Restart or Start). The row's tap target (the
  link to the detail) excludes the button. What each state shows is derived
  in `PlatformWeb.ControlCenter.NativeStatus`.
  """
  use Phoenix.Component
  use PlatformWeb, :verified_routes

  alias PlatformWeb.ControlCenter.NativeStatus

  attr :agent, :map, required: true
  attr :selected_slug, :string, default: nil
  # True when the viewer may Start / Stop / Restart / log in this agent
  # (`NativeAgents.can_manage?/2`). The server re-checks on every event; this
  # only decides whether the button is enabled.
  attr :can_manage?, :boolean, default: false

  def card(assigns) do
    assigns =
      assigns
      |> assign(:view, NativeStatus.row(assigns.agent))
      |> assign(:meta, NativeStatus.meta_line(assigns.agent))

    ~H"""
    <article
      id={"agent-row-#{@agent.slug}"}
      data-row-state={@view.state}
      class={[
        "mb-3 flex items-center gap-2 rounded-2xl border px-3 py-3 transition-colors",
        @selected_slug == @agent.slug && "border-primary bg-primary/5 shadow-sm",
        @selected_slug != @agent.slug &&
          "border-edge bg-base-100 hover:border-primary/30 hover:bg-base-100/80"
      ]}
    >
      <.link
        patch={~p"/control/#{@agent.slug}"}
        class="flex min-w-0 flex-1 items-center gap-3 text-left"
      >
        <span
          aria-hidden="true"
          class={[
            "inline-block h-2 w-2 shrink-0 rounded-full",
            @view.running? && "bg-success",
            !@view.running? && "bg-base-content/25"
          ]}
        />
        <%!-- Line 1 is the name and the exception tag; line 2, the meta line,
             runs the full width under both, as the canvas draws it. --%>
        <span class="min-w-0 flex-1">
          <span class="flex min-w-0 items-center gap-2">
            <span class="min-w-0 flex-1 truncate text-sm font-semibold leading-5 text-base-content">
              {@agent.name}
            </span>
            <.status_tag :if={@view.tag} tag={@view.tag} />
          </span>
          <span
            class="block truncate text-xs leading-4 text-subtle"
            data-role="row-meta"
            title={@meta}
          >
            {@meta}
          </span>
        </span>
      </.link>

      <.row_action
        :if={@view.action}
        view={@view}
        agent={@agent}
        can_manage?={@can_manage?}
      />
    </article>
    """
  end

  @doc """
  The exception tag. Needs login is a warning FILL with black text (warning
  is never a text colour); Crashed pairs the error icon with the word;
  everything else is plain `base-content/60` text with no fill.
  """
  attr :tag, :any, required: true

  def status_tag(%{tag: {:warning, _}} = assigns) do
    ~H"""
    <span
      data-role="row-tag"
      class="shrink-0 whitespace-nowrap rounded-field bg-warning px-2 py-0.5 text-xs font-semibold text-warning-content"
    >
      {elem(@tag, 1)}
    </span>
    """
  end

  def status_tag(%{tag: {:error, _}} = assigns) do
    ~H"""
    <span
      data-role="row-tag"
      class="inline-flex shrink-0 items-center gap-1 whitespace-nowrap text-xs font-semibold text-base-content"
    >
      <span class="hero-exclamation-circle size-4 text-error" aria-hidden="true" />
      {elem(@tag, 1)}
    </span>
    """
  end

  def status_tag(assigns) do
    ~H"""
    <span data-role="row-tag" class="shrink-0 whitespace-nowrap text-xs font-medium text-base-content">
      {elem(@tag, 1)}
    </span>
    """
  end

  attr :view, :map, required: true
  attr :agent, :map, required: true
  attr :can_manage?, :boolean, required: true

  defp row_action(%{view: %{action: :starting}} = assigns) do
    ~H"""
    <button
      type="button"
      data-role="row-action"
      class="btn btn-sm w-20 shrink-0"
      disabled
      aria-label={"#{@agent.name} is starting"}
    >
      <span class="loading loading-dots loading-xs" aria-hidden="true" />
    </button>
    """
  end

  # Log in opens the agent's detail page, where the login steps live (stage
  # 6). It never links to the login page the host reported: that page ends in
  # a code meant to be typed back into the CLI, which Burrow must not relay,
  # so it would be a dead end.
  defp row_action(%{view: %{action: :log_in}} = assigns) do
    ~H"""
    <.link
      :if={@can_manage?}
      patch={~p"/control/#{@agent.slug}"}
      data-role="row-action"
      class="btn btn-primary btn-sm w-20 shrink-0"
    >
      Log in
    </.link>
    <button
      :if={!@can_manage?}
      type="button"
      data-role="row-action"
      class="btn btn-primary btn-sm w-20 shrink-0"
      disabled
    >
      Log in
    </button>
    """
  end

  defp row_action(%{view: %{action: :start}} = assigns) do
    ~H"""
    <button
      type="button"
      data-role="row-action"
      phx-click="native_start"
      phx-value-agent_id={@agent.agent.id}
      class="btn btn-primary btn-sm w-20 shrink-0"
      disabled={!@can_manage?}
    >
      Start
    </button>
    """
  end

  defp row_action(%{view: %{action: :restart}} = assigns) do
    ~H"""
    <button
      type="button"
      data-role="row-action"
      phx-click="native_restart"
      phx-value-agent_id={@agent.agent.id}
      class="btn btn-outline btn-sm w-20 shrink-0"
      disabled={!@can_manage?}
    >
      Restart
    </button>
    """
  end
end
