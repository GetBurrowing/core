defmodule PlatformWeb.ConnectAiLive do
  @moduledoc """
  `/setup/connect-ai`: "Connect your AI", the first screen a new install's
  owner sees after the hand-over's "Open Burrow" (task 01a10315 stage 5;
  design canvas 01a13c97-98c6-7000-91f3-96b8ccfe8af4, screen 3).

  The owner picks the subscription their agent uses, and the screen connects
  ONE native agent named "Setup" (`Platform.Agents.SetupAgent`) with it:

    * **ChatGPT (Codex)**: Codex's own device login. Step 1 opens OpenAI's
      sign-in page in a new tab; step 2 shows the one-time code the agent host
      read from `codex login --device-auth` (`NativeLogin.login_view/1`). The
      screen subscribes to agent-host state, so it turns to "connected" by
      itself: the person never comes back to press a button.
    * **API key**: an Anthropic API key, saved through
      `Platform.Agents.NativeLogin.put_api_key/3` exactly as the agent's
      Control Center pane does. The field has no `value` and the key never
      enters an assign; `api_key_shape/1` refuses anything else.
    * **Claude Pro or Max**: needs a terminal today. Burrow never relays a
      Claude login (task 01a17b10): the panel recommends ChatGPT or an API key
      and shows, collapsed, the terminal steps on the server. There is no
      input in that panel and no event that takes a Claude code.

  No provider page is ever framed (no iframe anywhere); sign-in opens in a new
  tab (`target="_blank" rel="noopener noreferrer"`).

  The option order is `config :platform, PlatformWeb.ConnectAiLive,
  provider_order:` (the experiment surface; default ChatGPT first).

  When the agent is first seen running, `SetupAgent.ensure_getting_started/2`
  opens the "Getting started" space (once per agent) and the screen offers
  "Go to Getting started" as its next step.

  ## Authorization — defence in depth

  The route sits in the `:admin` live_session (`ModuleGate` maps this view to
  the `:admin` module), and the mount re-checks `Tenancy.root_admin?/1`, as
  the first user of a new install is (the bootstrap-admin fallback in
  `Platform.Tenancy`).
  """
  use PlatformWeb, :live_view

  alias Platform.AgentHost
  alias Platform.Agents.{NativeLogin, SetupAgent}
  alias Platform.Tenancy

  @default_order [:codex, :api_key, :claude_subscription]
  @device_url "https://auth.openai.com/codex/device"

  @labels %{
    codex: "ChatGPT (Codex)",
    api_key: "API key",
    claude_subscription: "Claude Pro or Max"
  }

  @doc "The configured option order, unknown entries dropped, missing ones appended."
  @spec provider_order() :: [atom()]
  def provider_order do
    configured =
      :platform
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:provider_order, @default_order)
      |> Enum.filter(&(&1 in @default_order))
      |> Enum.uniq()

    configured ++ (@default_order -- configured)
  end

  @doc "An option's label."
  def label(option), do: Map.fetch!(@labels, option)

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns[:current_user_record]

    if Tenancy.root_admin?(user) do
      order = provider_order()
      agent = SetupAgent.get()
      if connected?(socket), do: AgentHost.subscribe()

      socket =
        socket
        |> assign(:page_title, "Connect your AI")
        |> assign(:order, order)
        |> assign(:selected, initial_selection(agent, order))
        |> assign(:agent, agent)
        |> assign(:key_error, nil)
        |> assign(:key_saved?, false)
        |> assign(:space, nil)
        |> refresh()

      {:ok, maybe_start_selected(socket)}
    else
      {:ok, redirect(socket, to: "/access-denied?module=admin")}
    end
  end

  # An existing Setup agent decides the option shown first; otherwise the
  # first configured option.
  defp initial_selection(nil, order), do: hd(order)

  defp initial_selection(agent, order) do
    case SetupAgent.harness(agent) do
      "codex" -> :codex
      "claude_code" -> if :api_key in order, do: :api_key, else: hd(order)
      _ -> hd(order)
    end
  end

  # Codex shows its code as soon as the agent is up, so a connected mount on
  # the ChatGPT option starts it. The other options start it when chosen.
  defp maybe_start_selected(%{assigns: %{selected: :codex}} = socket) do
    if connected?(socket), do: ensure_agent(socket, :codex), else: socket
  end

  defp maybe_start_selected(socket), do: socket

  defp ensure_agent(socket, option) do
    user = socket.assigns.current_user_record

    case SetupAgent.ensure(user.id, SetupAgent.harness_for(option)) do
      {:ok, agent} -> socket |> assign(:agent, agent) |> refresh()
      {:error, _reason} -> assign(socket, :failure, :not_created)
    end
  end

  @impl true
  def handle_event("select", %{"provider" => provider}, socket) do
    case Enum.find(socket.assigns.order, &(Atom.to_string(&1) == provider)) do
      nil ->
        {:noreply, socket}

      option ->
        socket = socket |> assign(:selected, option) |> assign(:key_error, nil)
        # ChatGPT starts the agent for its code; Claude Pro or Max starts it so
        # the terminal steps can name its account. An API key waits for the key.
        socket =
          if option in [:codex, :claude_subscription],
            do: ensure_agent(socket, option),
            else: socket

        {:noreply, socket}
    end
  end

  def handle_event("save_api_key", params, socket) do
    value = get_in(params, ["api_key", "value"])
    user = socket.assigns.current_user_record

    # Refuse a non-key before creating anything.
    with :ok <- NativeLogin.api_key_shape(trim(value)),
         {:ok, agent} <- SetupAgent.ensure(user.id, "claude_code"),
         :ok <- NativeLogin.put_api_key(user.id, agent, value) do
      _ = AgentHost.restart_agent(agent)

      {:noreply,
       socket
       |> assign(:agent, agent)
       |> assign(:key_error, nil)
       |> assign(:key_saved?, true)
       |> refresh()}
    else
      {:error, :invalid_api_key} ->
        {:noreply,
         assign(
           socket,
           :key_error,
           "That is not an Anthropic API key. It starts with sk-ant- and has no spaces."
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, :key_error, "Could not save the API key. Try again.")}
    end
  end

  def handle_event("retry", _params, socket) do
    socket =
      case socket.assigns.agent do
        nil ->
          ensure_agent(socket, socket.assigns.selected)

        agent ->
          _ = AgentHost.restart_agent(agent)
          refresh(socket)
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_host_status, _event}, socket) do
    {:noreply, socket |> assign(:agent, socket.assigns.agent || SetupAgent.get()) |> refresh()}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # Everything the page shows about the agent, read fresh. On the first
  # observation of `running`, the Getting started space is ensured.
  defp refresh(socket) do
    agent = socket.assigns.agent
    observed = agent && AgentHost.status(agent)
    running? = match?(%{state: :running}, observed)

    socket
    |> assign(:observed, observed)
    |> assign(:host_connected?, AgentHost.connected?())
    |> assign(:running?, running?)
    |> assign(:login, agent && NativeLogin.login_view(agent))
    |> assign(:os_user, agent && SetupAgent.os_user(agent))
    |> assign(:failure, failure(agent, observed))
    |> maybe_getting_started(agent, running?)
  end

  defp failure(nil, _observed), do: if(AgentHost.connected?(), do: nil, else: :host_offline)

  defp failure(_agent, observed) do
    cond do
      not AgentHost.connected?() -> :host_offline
      match?(%{state: :crashed}, observed) -> {:crashed, observed[:detail]}
      true -> nil
    end
  end

  defp maybe_getting_started(socket, agent, true) do
    case socket.assigns[:space] do
      nil ->
        case SetupAgent.ensure_getting_started(agent, socket.assigns.current_user_record) do
          {:ok, space} -> assign(socket, :space, space)
          {:error, _} -> socket
        end

      _space ->
        socket
    end
  end

  defp maybe_getting_started(socket, _agent, _running?), do: socket

  defp ssh_host do
    URI.parse(PlatformWeb.Endpoint.url()).host
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:agent_name, (assigns.agent && assigns.agent.name) || SetupAgent.name())
      |> assign(:ssh_host, ssh_host())
      |> assign(:done?, assigns.running? and not is_nil(assigns.space))

    ~H"""
    <div class="h-full overflow-y-auto bg-base-100">
      <div class="mx-auto w-full max-w-[560px] px-4 pt-10 pb-[calc(2.5rem+env(safe-area-inset-bottom))]">
        <div :if={@done?} id="connect-ai-connected" class="space-y-4">
          <h1 class="text-2xl font-semibold text-base-content">Your AI is connected</h1>
          <p id="connect-ai-status" class="flex items-center gap-2 text-base text-base-content">
            <span class="hero-check-circle size-5 shrink-0 text-neutral" />
            {@agent_name} is connected.
          </p>
          <p class="text-base text-subtle">
            {@agent_name} is waiting for you in Getting started, to help you finish setting up.
          </p>
          <.link
            id="connect-ai-getting-started"
            navigate={~p"/chat/#{@space.slug}"}
            class="btn btn-primary min-h-11"
          >
            Go to Getting started
          </.link>
        </div>

        <div :if={!@done?} class="space-y-6">
          <h1 class="text-base font-semibold text-base-content">Which subscription do you use?</h1>

          <form id="connect-ai-options" phx-change="select" class="space-y-3">
            <label
              :for={option <- @order}
              id={"connect-ai-option-#{option}"}
              data-provider={option}
              class={[
                "flex min-h-11 cursor-pointer items-center gap-3 rounded-box border bg-base-100 p-4 text-base text-base-content",
                if(@selected == option,
                  do: "border-primary ring-2 ring-primary",
                  else: "border-edge"
                )
              ]}
            >
              <input
                type="radio"
                name="provider"
                value={option}
                checked={@selected == option}
                class="radio radio-primary"
              />
              <span>{label(option)}</span>
            </label>
          </form>

          <.failure_block :if={@failure} failure={@failure} agent_name={@agent_name} />

          <section :if={@selected == :codex} id="provider-panel-codex" class="space-y-4">
            <ol class="space-y-4">
              <li class="space-y-2">
                <p class="text-base text-base-content">1. Sign in to ChatGPT.</p>
                <a
                  id="connect-ai-codex-open"
                  href={device_href(@login)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="btn btn-primary min-h-11"
                >
                  Open ChatGPT sign-in
                </a>
                <p class="text-sm text-subtle">Opens in a new tab.</p>
              </li>
              <li class="space-y-2">
                <p class="text-base text-base-content">2. Enter this code there:</p>
                <div
                  id="connect-ai-code-callout"
                  class="flex items-center gap-2 rounded-box border border-info/40 bg-info/10 p-4 text-base-content"
                >
                  <%= if code = device_code(@login) do %>
                    <span
                      id="connect-ai-code"
                      class="min-w-0 flex-1 font-mono text-sm tracking-widest"
                    >
                      {code}
                    </span>
                    <button
                      type="button"
                      id="connect-ai-code-copy"
                      phx-hook="CopyToClipboard"
                      data-clipboard-text={code}
                      class="btn btn-ghost btn-sm min-h-11 shrink-0"
                    >
                      Copy
                    </button>
                  <% else %>
                    <span id="connect-ai-code-pending" class="flex-1 text-sm text-base-content">
                      Getting a fresh code...
                    </span>
                  <% end %>
                </div>
                <p class="text-sm text-subtle">
                  A code lasts 15 minutes. A new one appears here by itself if it runs out.
                </p>
              </li>
            </ol>
            <.status_line :if={is_nil(@failure)} running?={@running?} agent_name={@agent_name} />
          </section>

          <section :if={@selected == :api_key} id="provider-panel-api_key" class="space-y-3">
            <p class="text-base text-base-content">
              Paste an Anthropic API key. {@agent_name} uses it to run Claude Code.
            </p>
            <form
              id="connect-ai-api-key-form"
              phx-submit="save_api_key"
              autocomplete="off"
              class="space-y-2"
            >
              <label class="block">
                <span class="mb-1 block text-sm font-medium text-base-content">API key</span>
                <%!-- No `value`, ever: the key is never sent back to the page. --%>
                <input
                  id="connect-ai-api-key-input"
                  type="password"
                  name="api_key[value]"
                  autocomplete="off"
                  spellcheck="false"
                  class="input input-bordered w-full min-h-11 font-mono"
                  required
                />
              </label>
              <p :if={@key_error} id="connect-ai-api-key-error" class="text-sm text-error">
                {@key_error}
              </p>
              <p class="text-xs text-subtle">Stored encrypted in this install's vault.</p>
              <button id="connect-ai-api-key-save" type="submit" class="btn btn-primary min-h-11">
                Save and connect
              </button>
            </form>
            <.status_line
              :if={@key_saved? and is_nil(@failure)}
              running?={@running?}
              agent_name={@agent_name}
            />
          </section>

          <section
            :if={@selected == :claude_subscription}
            id="provider-panel-claude_subscription"
            class="space-y-3"
          >
            <p class="text-base text-base-content">
              Connecting a Claude Pro or Max subscription needs a terminal on this server today.
              Burrow can't do that sign-in for you.
            </p>
            <p class="text-base text-base-content">
              We recommend ChatGPT (Codex) or an API key instead: both connect right here.
            </p>
            <details id="connect-ai-claude-technical" class="group rounded-box border border-edge">
              <summary class="flex min-h-11 cursor-pointer items-center gap-2 px-3 text-sm font-medium text-base-content">
                <span class="hero-chevron-right size-4 transition-transform group-open:rotate-90" />
                For technical users
              </summary>
              <div class="space-y-2 border-t border-edge p-3">
                <p class="text-sm text-subtle">On your own computer, run these one at a time:</p>
                <pre
                  id="connect-ai-claude-steps"
                  class="overflow-x-auto rounded-box bg-base-200 p-3 font-mono text-sm text-base-content"
                >{claude_steps(@ssh_host, @os_user)}</pre>
                <p class="text-sm text-subtle">
                  Then follow Claude's own sign-in in your browser. Burrow never sees it.
                </p>
              </div>
            </details>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr :running?, :boolean, required: true
  attr :agent_name, :string, required: true

  defp status_line(assigns) do
    ~H"""
    <p
      :if={!@running?}
      id="connect-ai-status"
      class="flex items-center gap-2 text-base text-base-content"
    >
      <span class="hero-arrow-path size-5 shrink-0 animate-spin text-info" />
      <span class="font-medium text-info">Waiting for sign-in...</span>
    </p>
    <p
      :if={@running?}
      id="connect-ai-status"
      class="flex items-center gap-2 text-base text-base-content"
    >
      <span class="hero-check-circle size-5 shrink-0 text-neutral" />
      {@agent_name} is connected.
    </p>
    """
  end

  attr :failure, :any, required: true
  attr :agent_name, :string, required: true

  defp failure_block(assigns) do
    ~H"""
    <div
      id="connect-ai-failed"
      class="rounded-box border border-error/40 bg-error/10 p-4 text-base-content"
    >
      <p class="flex items-start gap-2 text-base">
        <span class="hero-exclamation-circle mt-0.5 size-5 shrink-0 text-error" />
        <span>{failure_text(@failure, @agent_name)}</span>
      </p>
      <button
        id="connect-ai-retry"
        type="button"
        phx-click="retry"
        class="btn btn-outline mt-3 min-h-11"
      >
        Retry
      </button>
    </div>
    """
  end

  @doc false
  def failure_text(:host_offline, _name),
    do: "This server's agent service isn't answering right now, so your AI can't connect yet."

  def failure_text(:not_created, _name), do: "Your AI couldn't be set up. Try again."

  def failure_text({:crashed, _detail}, name),
    do: "#{name} stopped unexpectedly while starting."

  defp device_code(%{kind: :device_code, code: code}) when is_binary(code), do: code
  defp device_code(_), do: nil

  # The URL the host read from `codex login --device-auth`, else OpenAI's
  # measured device page, so step 1 works before the code has arrived.
  defp device_href(%{kind: :device_code, url: href}) when is_binary(href), do: href
  defp device_href(_), do: @device_url

  defp claude_steps(host, os_user) do
    Enum.join(
      [
        "ssh root@#{host}",
        "sudo -iu #{os_user || "agent-<id>"}",
        "claude",
        "/login"
      ],
      "\n"
    )
  end
end
