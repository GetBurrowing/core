defmodule PlatformWeb.ConnectAiLive do
  @moduledoc """
  `/setup/connect-ai`: "Connect your AI", the first screen a new install's
  owner sees after the hand-over's "Open Burrow" (task 01a10315 stage 5;
  design canvas 01a13c97-98c6-7000-91f3-96b8ccfe8af4, screen 3).

  The owner picks the subscription their agent uses, and the screen connects
  ONE native agent named Burrow (`Platform.Agents.Burrow`) with it, on the
  provider chosen here (task 01a19505). Both subscriptions are one card of two
  numbered steps (task 01a1b365; design canvas
  01a1b366-20c1-7000-955d-92234ae5dc57):

    * **ChatGPT (Codex)**: Codex's own device login. Step 1 opens OpenAI's
      sign-in page in a new tab; step 2 shows the one-time code the agent host
      read from `codex login --device-auth` (`NativeLogin.login_view/1`). The
      screen subscribes to agent-host state, so it turns to "connected" by
      itself: the person never comes back to press a button.
    * **Claude Pro or Max**: the owner's own Claude sign-in, for their own
      agent on this install. Choosing it starts the agent's own `claude auth
      login` on the agent host (`AgentHost.claude_login_start/3`), so step 1
      is one click on a plain link to Anthropic's page, in a new tab. Step 2
      takes the code that page shows: a `phx-submit`-only form (no keystroke
      reaches the server) whose masked field never has a `value`. The `code`
      param (filtered from logs by `:filter_parameters`) is wrapped in a
      `Platform.AgentHost.LoginCode` at once and never assigned, the field is
      cleared in the browser (`ConnectAiCode` hook), and
      `AgentHost.claude_login_submit/4` hands it to the pending login.
      The pending login is bound to the process that started it, so start and
      submit both run in this view's own process, each after the screen has
      rendered its "waiting" line (`send(self(), ...)`). Every submit ends the
      pending login, so a failure fetches a fresh sign-in link. An agent with
      a saved API key stays on the key (`NativeLogin.login_view/2` answers
      `:api_key`).
    * **API key**: not one of the choices; a quiet "Have an API key instead?"
      link under them shows the form. An Anthropic API key is saved through
      `Platform.Agents.NativeLogin.put_api_key/3` exactly as the agent's
      Control Center pane does. The field has no `value` and the key never
      enters an assign; `api_key_shape/1` refuses anything else.

  No provider page is ever framed (no iframe anywhere); sign-in opens in a new
  tab (`target="_blank" rel="noopener noreferrer"`). An event this page does
  not handle is refused, and only its name is logged.

  The option order is `config :platform, PlatformWeb.ConnectAiLive,
  provider_order:` (the experiment surface; default ChatGPT first). An
  `:api_key` entry is accepted and ignored for the choices.
  `claude_login_timeout_ms:` there shortens the waits on the agent host.

  While Burrow runs on the install's starter allowance
  (`Burrow.Starter.active?/1`) this page still shows the choices with none
  selected, and a link back to the conversation, and does NOT start anything
  on mount: only an
  explicit choice (`select`, `save_api_key`) calls `Burrow.ensure/2`, which
  retires the starter. Opening the page from the conversation must not swap
  Burrow off the allowance by itself.

  When the agent is first seen running,
  `Burrow.GettingStarted.ensure_getting_started/2`
  opens the "Getting started" space (once per agent) and the screen offers
  "Go to Getting started" as its next step.

  ## Authorization — defence in depth

  The route sits in the `:admin` live_session (`ModuleGate` maps this view to
  the `:admin` module), and the mount re-checks `Tenancy.root_admin?/1`, as
  the first user of a new install is (the bootstrap-admin fallback in
  `Platform.Tenancy`). `AgentHost` checks `NativeAgents.can_manage?/2` again
  on every Claude login call.
  """
  use PlatformWeb, :live_view

  require Logger

  alias Platform.AgentHost
  alias Platform.AgentHost.LoginCode
  alias Platform.Agents.{Burrow, NativeLogin}
  alias Platform.Agents.Burrow.{GettingStarted, Starter}
  alias Platform.Tenancy

  @default_order [:codex, :api_key, :claude_subscription]
  @choices [:codex, :claude_subscription]
  @device_url "https://auth.openai.com/codex/device"

  @labels %{
    codex: "ChatGPT (Codex)",
    api_key: "API key",
    claude_subscription: "Claude Pro or Max"
  }

  # The Claude card's state. `link`: :idle (no sign-in link asked for yet),
  # :loading, :ready or :unavailable. `status`: :idle, :connecting,
  # {:failed, :bad_code | :no_subscription | :server} or :connected. `login`
  # is a submit's `%{account, plan}`. Never the code.
  @claude_idle %{url: nil, link: :idle, opened?: false, status: :idle, login: nil}

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

  @doc "The subscriptions offered as choices, in `provider_order/0`: never `:api_key`."
  @spec choices() :: [atom()]
  def choices, do: Enum.filter(provider_order(), &(&1 in @choices))

  @doc "An option's label."
  def label(option), do: Map.fetch!(@labels, option)

  @impl true
  def mount(_params, session, socket) do
    user = socket.assigns[:current_user_record]

    if Tenancy.root_admin?(user) do
      order = choices()
      agent = Burrow.get()
      if connected?(socket), do: AgentHost.subscribe()

      socket =
        socket
        |> assign(:page_title, "Connect your AI")
        |> assign(:order, order)
        |> assign(:selected, initial_selection(agent, order))
        |> assign(:agent, agent)
        |> assign(:key_error, nil)
        |> assign(:key_saved?, false)
        |> assign(:claude, @claude_idle)
        |> assign(:space, nil)
        |> assign(:passkey_url, passkey_url(session))
        |> refresh()

      {:ok, maybe_start_selected(socket)}
    else
      {:ok, redirect(socket, to: "/access-denied?module=admin")}
    end
  end

  # Stage 6 round 2: an owner who arrived through the hand-over link signed
  # in with pocket-id's one-time code and has no passkey yet. pocket-id has no
  # "add a passkey, then return" page (its add-passkey screen always ends on
  # its own /settings/account), so the hand-over lands HERE and this card
  # links to that page in a new tab, the only place a passkey for the
  # sign-in host can be created.
  @doc false
  def passkey_url(%{"signed_in_with_link" => true}) do
    case Application.get_env(:platform, :oidc, [])[:issuer] do
      issuer when is_binary(issuer) and issuer != "" ->
        String.trim_trailing(issuer, "/") <> "/settings/account"

      _ ->
        nil
    end
  end

  def passkey_url(_session), do: nil

  # An existing Burrow agent decides the option shown first; otherwise the
  # first choice. A Claude Code agent with a saved key shows the key, which
  # wins over a subscription.
  defp initial_selection(nil, order), do: hd(order)

  # On the starter allowance nothing is selected: a pre-checked radio would
  # swallow the owner's click on it (no change event), and nothing may start.
  defp initial_selection(agent, order) do
    if Starter.active?(agent), do: nil, else: selection_for_harness(agent, order)
  end

  defp selection_for_harness(agent, order) do
    case Burrow.harness(agent) do
      "codex" ->
        :codex

      "claude_code" ->
        if NativeLogin.api_key_set?(agent), do: :api_key, else: :claude_subscription

      _ ->
        hd(order)
    end
  end

  # Both subscriptions start the agent when shown on a connected mount: Codex
  # for its code, Claude for its sign-in link. An API key waits for the key.
  defp maybe_start_selected(%{assigns: %{selected: option}} = socket)
       when option in @choices do
    if connected?(socket),
      do: socket |> ensure_agent(option) |> maybe_start_claude(),
      else: socket
  end

  defp maybe_start_selected(socket), do: socket

  defp ensure_agent(socket, option) do
    user = socket.assigns.current_user_record

    case Burrow.ensure(user.id, Burrow.harness_for(option)) do
      {:ok, agent} -> socket |> assign(:agent, agent) |> refresh()
      {:error, _reason} -> assign(socket, :failure, :not_created)
    end
  end

  # Ask for a Claude sign-in link when the Claude card is showing, the agent
  # is not running and no link has been asked for. The start itself runs in
  # `handle_info(:claude_login_start, _)`, in this process (the pending login
  # is bound to it), after this render.
  defp maybe_start_claude(
         %{
           assigns: %{
             selected: :claude_subscription,
             running?: false,
             login: %{kind: :claude_subscription},
             claude: %{link: :idle} = claude
           }
         } = socket
       ) do
    send(self(), :claude_login_start)
    assign(socket, :claude, %{claude | link: :loading})
  end

  defp maybe_start_claude(socket), do: socket

  @impl true
  def handle_event("select", %{"provider" => provider}, socket) do
    case Enum.find(socket.assigns.order, &(Atom.to_string(&1) == provider)) do
      nil ->
        {:noreply, socket}

      option ->
        socket =
          socket
          |> assign(:selected, option)
          |> assign(:key_error, nil)
          |> assign(:claude, @claude_idle)
          |> ensure_agent(option)
          |> maybe_start_claude()

        {:noreply, socket}
    end
  end

  def handle_event("show_api_key", _params, socket) do
    {:noreply, socket |> assign(:selected, :api_key) |> assign(:key_error, nil)}
  end

  def handle_event("save_api_key", params, socket) do
    value = get_in(params, ["api_key", "value"])
    user = socket.assigns.current_user_record

    # Refuse a non-key before creating anything.
    with :ok <- NativeLogin.api_key_shape(trim(value)),
         {:ok, agent} <- Burrow.ensure(user.id, "claude_code"),
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

  def handle_event("claude_opened", _params, socket) do
    claude = socket.assigns.claude

    claude =
      if claude.link == :ready,
        do: %{claude | opened?: true, status: idle_unless_failed(claude.status)},
        else: claude

    {:noreply, assign(socket, :claude, claude)}
  end

  # The pasted code. It is wrapped at once and handed to the submit in a
  # message (a LoginCode prints as `#LoginCode<redacted>`); the raw param goes
  # no further than `LoginCode.new/1` and is never assigned, logged or
  # rendered. The field is cleared in the browser whatever happens.
  def handle_event("claude_submit", params, socket) do
    claude = socket.assigns.claude
    socket = push_event(socket, "connect-ai-clear-code", %{})

    if claude_step_two_active?(claude) and claude.status != :connecting do
      case LoginCode.new(Map.get(params, "code")) do
        {:ok, code} ->
          send(self(), {:claude_submit, code})
          {:noreply, assign(socket, :claude, %{claude | status: :connecting})}

        {:error, :bad_code} ->
          {:noreply, assign(socket, :claude, %{claude | status: {:failed, :bad_code}})}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("claude_retry_link", _params, socket) do
    claude = socket.assigns.claude

    if claude.link == :unavailable do
      send(self(), :claude_login_start)
      {:noreply, assign(socket, :claude, %{claude | link: :loading})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("claude_disconnect", _params, %{assigns: %{agent: %{} = agent}} = socket) do
    case AgentHost.claude_logout(socket.assigns.current_user_record, agent) do
      :ok ->
        {:noreply,
         socket
         |> assign(:claude, @claude_idle)
         |> refresh()
         |> maybe_start_claude()}

      {:error, _reason} ->
        claude = socket.assigns.claude
        {:noreply, assign(socket, :claude, %{claude | status: {:failed, :server}})}
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

  # Any event this page does not handle is refused here, and only its NAME is
  # logged (the control_center_live.ex pattern). Without this clause an
  # unknown event crashed the view, and the crash report printed the event's
  # params verbatim, `:filter_parameters` notwithstanding: a Claude code sent
  # to a made-up event would have landed in the log.
  def handle_event(event, _params, socket) do
    Logger.warning("[ConnectAiLive] refused unknown event #{inspect(event)}")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_host_status, _event}, socket) do
    {:noreply,
     socket
     |> assign(:agent, socket.assigns.agent || Burrow.get())
     |> refresh()
     |> maybe_start_claude()}
  end

  def handle_info(
        :claude_login_start,
        %{assigns: %{selected: :claude_subscription, agent: %{} = agent}} = socket
      ) do
    claude = socket.assigns.claude

    claude =
      case AgentHost.claude_login_start(socket.assigns.current_user_record, agent, login_opts()) do
        {:ok, url} -> %{claude | url: url, link: :ready}
        {:error, _reason} -> %{claude | url: nil, link: :unavailable}
      end

    {:noreply, assign(socket, :claude, claude)}
  end

  def handle_info(
        {:claude_submit, %LoginCode{} = code},
        %{assigns: %{selected: :claude_subscription, agent: %{} = agent}} = socket
      ) do
    claude = socket.assigns.claude

    case AgentHost.claude_login_submit(
           socket.assigns.current_user_record,
           agent,
           code,
           login_opts()
         ) do
      {:ok, login} ->
        claude = %{claude | status: :connected, login: login}
        {:noreply, socket |> assign(:claude, claude) |> refresh()}

      {:error, reason} ->
        # The submit ended the pending login: fetch a fresh link for "Open
        # Claude sign-in again".
        send(self(), :claude_login_start)

        claude = %{
          claude
          | status: {:failed, submit_failure(reason)},
            opened?: false,
            link: :loading,
            url: nil
        }

        {:noreply, assign(socket, :claude, claude)}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # `claude_login_timeout_ms:` in this module's config shortens the wait on
  # the agent host (tests); otherwise `AgentHost`'s own defaults apply.
  defp login_opts do
    case Keyword.get(Application.get_env(:platform, __MODULE__, []), :claude_login_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> [timeout: ms]
      _ -> []
    end
  end

  defp submit_failure(reason) when reason in [:bad_code, :no_session], do: :bad_code
  defp submit_failure(:no_subscription), do: :no_subscription
  defp submit_failure(_reason), do: :server

  defp idle_unless_failed({:failed, _} = status), do: status
  defp idle_unless_failed(_status), do: :idle

  defp claude_step_two_active?(%{opened?: true}), do: true
  defp claude_step_two_active?(%{status: {:failed, _}}), do: true
  defp claude_step_two_active?(%{status: :connecting}), do: true
  defp claude_step_two_active?(_claude), do: false

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
    |> assign(:login, agent && NativeLogin.login_view(agent, socket.assigns.claude.login))
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
        # Seat Burrow in Help & feedback once it runs (task 01a1b678 stage 3).
        # A no-op on an install without that channel.
        _ = Platform.Sharing.HelpChannel.ensure_agent(agent)

        case GettingStarted.ensure_getting_started(agent, socket.assigns.current_user_record) do
          {:ok, space} -> assign(socket, :space, space)
          {:error, _} -> socket
        end

      _space ->
        socket
    end
  end

  defp maybe_getting_started(socket, _agent, _running?), do: socket

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:agent_name, (assigns.agent && assigns.agent.name) || Burrow.name())
      |> assign(:starter?, Starter.active?(assigns.agent))

    assigns =
      assign(
        assigns,
        :done?,
        assigns.running? and not is_nil(assigns.space) and not assigns.starter?
      )

    ~H"""
    <div class="h-full overflow-y-auto bg-base-100">
      <div class="mx-auto w-full max-w-[560px] px-4 pt-10 pb-[calc(2.5rem+env(safe-area-inset-bottom))]">
        <div
          :if={@passkey_url}
          id="connect-ai-passkey"
          class="mb-6 space-y-2 rounded-box border border-edge p-4"
        >
          <p class="flex items-center gap-2 text-base font-semibold text-base-content">
            <span class="hero-finger-print size-5 shrink-0" /> Sign in faster next time
          </p>
          <p class="text-sm text-subtle">
            Use Face ID, Touch ID or your device unlock to sign in next time.
          </p>
          <a
            id="connect-ai-passkey-link"
            href={@passkey_url}
            target="_blank"
            rel="noopener noreferrer"
            class="btn btn-outline min-h-11"
          >
            Set up Face ID or device unlock
          </a>
        </div>
        <div :if={@done?} id="connect-ai-connected" class="space-y-4">
          <h1 class="text-2xl font-semibold text-base-content">Your AI is connected</h1>
          <p id="connect-ai-status" class="flex items-center gap-2 text-base text-base-content">
            <span class="hero-check-circle size-5 shrink-0 text-neutral" />
            {@agent_name} is connected.
          </p>
          <.claude_connected
            :if={@selected == :claude_subscription and match?(%{kind: :claude_subscription}, @login)}
            login={@login}
          />
          <p
            :if={@selected == :codex}
            id="connect-ai-codex-connected"
            class="flex items-center gap-2 text-base"
          >
            <span class="hero-check-circle size-5 shrink-0 text-success" />
            <span class="font-medium text-success">Connected to ChatGPT</span>
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
          <.link
            :if={@starter? and @space}
            id="connect-ai-back-to-getting-started"
            navigate={~p"/chat/#{@space.slug}"}
            class="text-sm text-base-content underline underline-offset-2 hover:no-underline"
          >
            Back to Getting started
          </.link>

          <div class="space-y-2">
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
            <button
              :if={@selected != :api_key}
              id="connect-ai-api-key-link"
              type="button"
              phx-click="show_api_key"
              class="min-h-11 cursor-pointer text-sm text-base-content underline underline-offset-2 hover:no-underline"
            >
              Have an API key instead?
            </button>
          </div>

          <.failure_block :if={@failure} failure={@failure} agent_name={@agent_name} />

          <section :if={@selected == :codex} id="provider-panel-codex" class="space-y-4">
            <ol
              id="connect-ai-codex-card"
              class="divide-y divide-edge overflow-hidden rounded-box border border-edge bg-base-100"
            >
              <li id="connect-ai-codex-step-1" class="flex">
                <.step_rail n={1} />
                <div class="min-w-0 flex-1 space-y-2 p-4">
                  <p class="text-base font-medium text-base-content">Sign in to ChatGPT.</p>
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
                </div>
              </li>
              <li id="connect-ai-codex-step-2" class="flex">
                <.step_rail n={2} />
                <div class="min-w-0 flex-1 space-y-2 p-4">
                  <p class="text-base font-medium text-base-content">Enter this code there:</p>
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
                  <.status_line :if={is_nil(@failure)} running?={@running?} agent_name={@agent_name} />
                </div>
              </li>
            </ol>
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
              <p class="text-xs text-subtle">Stored encrypted.</p>
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
            class="space-y-4"
          >
            <div class="space-y-1">
              <h2
                id="connect-ai-claude-heading"
                class="text-base font-semibold text-base-content"
              >
                Connect your Claude subscription
              </h2>
              <p id="connect-ai-claude-subhead" class="text-base text-base-content">
                Use your Claude Pro or Max plan. No API key needed.
              </p>
            </div>
            <%= case @login do %>
              <% %{kind: :claude_subscription} -> %>
                <.claude_card claude={@claude} />
              <% :api_key -> %>
                <p id="connect-ai-claude-uses-key" class="text-base text-base-content">
                  {@agent_name} is using the API key you saved, so it doesn't need your Claude plan.
                </p>
              <% :subscription_terminal_only -> %>
                <p id="connect-ai-claude-operator" class="text-base text-base-content">
                  Someone who manages Burrow needs to connect Claude Pro or Max for you.
                </p>
              <% _ -> %>
                <p id="connect-ai-claude-preparing" class="text-sm text-subtle">
                  Getting {@agent_name} ready...
                </p>
            <% end %>
          </section>
        </div>
      </div>
    </div>
    """
  end

  attr(:n, :integer, required: true)

  defp step_rail(assigns) do
    ~H"""
    <div class="flex w-12 shrink-0 justify-center bg-base-200 pt-4" aria-hidden="true">
      <span class="flex size-7 items-center justify-center rounded-full border border-edge bg-base-100 text-sm font-semibold text-base-content">
        {@n}
      </span>
    </div>
    """
  end

  attr(:claude, :map, required: true)

  defp claude_card(%{claude: %{status: :connected}} = assigns) do
    ~H"""
    <div id="connect-ai-claude-card" class="rounded-box border border-edge bg-base-100">
      <.claude_connected login={@claude.login} class="p-4" />
    </div>
    """
  end

  defp claude_card(assigns) do
    assigns =
      assigns
      |> assign(:active?, claude_step_two_active?(assigns.claude))
      |> assign(:connecting?, assigns.claude.status == :connecting)
      |> assign(:failed, failed_reason(assigns.claude.status))

    ~H"""
    <ol
      id="connect-ai-claude-card"
      class="divide-y divide-edge overflow-hidden rounded-box border border-edge bg-base-100"
    >
      <li id="connect-ai-claude-step-1" class="flex">
        <.step_rail n={1} />
        <div class="min-w-0 flex-1 space-y-2 p-4">
          <p class="text-base font-medium text-base-content">Sign in to Claude</p>
          <p class="text-sm text-base-content">
            Opens claude.ai in a new tab. Sign in with the account that has your Pro or Max plan.
          </p>
          <%= cond do %>
            <% @claude.opened? and @claude.link == :ready -> %>
              <p
                id="connect-ai-claude-opened"
                class="flex flex-wrap items-center gap-x-2 text-sm text-base-content"
              >
                <span class="hero-check size-4 shrink-0" /> Opened in a new tab
                <a
                  id="connect-ai-claude-open-again"
                  href={@claude.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  phx-click="claude_opened"
                  class="inline-flex min-h-11 items-center underline underline-offset-2"
                >
                  Open it again
                </a>
              </p>
            <% @claude.link == :ready -> %>
              <a
                id="connect-ai-claude-open"
                href={@claude.url}
                target="_blank"
                rel="noopener noreferrer"
                phx-click="claude_opened"
                class="btn btn-primary min-h-11"
              >
                Open Claude sign-in ↗
              </a>
            <% @claude.link == :unavailable -> %>
              <p id="connect-ai-claude-link-error" class="flex items-start gap-2 text-sm text-error">
                <span class="hero-exclamation-circle mt-0.5 size-4 shrink-0" />
                <span>{claude_failure_text(:server)}</span>
              </p>
              <button
                id="connect-ai-claude-retry-link"
                type="button"
                phx-click="claude_retry_link"
                class="btn btn-outline min-h-11"
              >
                Try again
              </button>
            <% true -> %>
              <span
                id="connect-ai-claude-open-pending"
                class="btn btn-primary btn-disabled min-h-11"
                aria-disabled="true"
              >
                Open Claude sign-in ↗
              </span>
          <% end %>
        </div>
      </li>
      <li id="connect-ai-claude-step-2" class={["flex", !@active? && "opacity-60"]}>
        <.step_rail n={2} />
        <div class="min-w-0 flex-1 space-y-2 p-4">
          <p class="text-base font-medium text-base-content">Paste the code Claude shows you</p>
          <p :if={!@active?} id="connect-ai-claude-locked" class="text-sm text-base-content">
            Do step 1 first.
          </p>
          <%!-- phx-submit only: no phx-change, so no keystroke reaches the
               server. The field never has a `value`; ConnectAiCode does the
               show toggle and clears it, in the browser. --%>
          <form
            id="connect-ai-claude-form"
            phx-submit="claude_submit"
            phx-hook="ConnectAiCode"
            autocomplete="off"
            class="space-y-2"
          >
            <div class="flex flex-wrap gap-2">
              <label class="input input-bordered flex min-h-11 min-w-0 flex-1 basis-48 items-center gap-2">
                <span class="sr-only">Code from Claude</span>
                <input
                  id="connect-ai-claude-code"
                  type="password"
                  name="code"
                  autocomplete="off"
                  autocapitalize="off"
                  autocorrect="off"
                  spellcheck="false"
                  class="min-w-0 grow font-mono"
                  disabled={!@active? or @connecting?}
                  required
                />
                <button
                  id="connect-ai-claude-code-toggle"
                  type="button"
                  data-code-toggle
                  aria-controls="connect-ai-claude-code"
                  aria-pressed="false"
                  class="btn btn-ghost btn-xs shrink-0"
                  disabled={!@active? or @connecting?}
                >
                  Show
                </button>
              </label>
              <button
                id="connect-ai-claude-connect"
                type="submit"
                class="btn btn-primary min-h-11"
                disabled={!@active? or @connecting?}
              >
                Connect
              </button>
            </div>
            <p id="connect-ai-claude-reassurance" class="text-sm text-base-content">
              The code goes straight to your Burrow and is not kept.
            </p>
          </form>
          <p
            :if={@active? and @claude.status == :idle}
            id="connect-ai-claude-waiting"
            class="flex items-center gap-2 text-sm text-info"
          >
            <span class="hero-arrow-path size-4 shrink-0 animate-spin" /> Waiting for the code…
          </p>
          <p
            :if={@connecting?}
            id="connect-ai-claude-connecting"
            class="flex items-center gap-2 text-sm text-info"
          >
            <span class="hero-arrow-path size-4 shrink-0 animate-spin" /> Connecting…
          </p>
          <p
            :if={@failed}
            id="connect-ai-claude-error"
            data-reason={@failed}
            class="flex items-start gap-2 text-sm text-error"
          >
            <span class="hero-exclamation-circle mt-0.5 size-4 shrink-0" />
            <span>{claude_failure_text(@failed)}</span>
          </p>
        </div>
      </li>
    </ol>
    """
  end

  attr(:login, :map, required: true)
  attr(:class, :string, default: nil)

  defp claude_connected(assigns) do
    ~H"""
    <div
      id="connect-ai-claude-connected"
      class={["flex flex-wrap items-center gap-x-3 gap-y-1", @class]}
    >
      <p class="flex items-center gap-2 text-base">
        <span class="hero-check-circle size-5 shrink-0 text-success" />
        <span class="font-medium text-success">{claude_connected_text(@login)}</span>
      </p>
      <button
        id="connect-ai-claude-disconnect"
        type="button"
        phx-click="claude_disconnect"
        class="btn btn-ghost btn-sm min-h-11"
      >
        Disconnect
      </button>
    </div>
    """
  end

  attr(:running?, :boolean, required: true)
  attr(:agent_name, :string, required: true)

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

  attr(:failure, :any, required: true)
  attr(:agent_name, :string, required: true)

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
    do: "Burrow isn't answering right now, so your AI can't connect yet."

  def failure_text(:not_created, _name), do: "Your AI couldn't be set up. Try again."

  def failure_text({:crashed, _detail}, name),
    do: "#{name} stopped unexpectedly while starting."

  @doc "What the Claude card says when a sign-in fails, by reason."
  def claude_failure_text(:bad_code),
    do:
      "That code didn't work. Codes expire after a few minutes. Open Claude sign-in again and paste the new code."

  def claude_failure_text(:no_subscription),
    do: "This account doesn't have Claude Pro or Max. Sign in with the account that does."

  def claude_failure_text(:server),
    do: "Burrow didn't answer. Try again in a minute. If it keeps happening, ask Burrow support."

  @doc "The Claude card's connected line: the account and plan when a submit returned them."
  def claude_connected_text(%{account: account} = login) when is_binary(account) do
    case plan_label(Map.get(login, :plan)) do
      nil -> "Connected as #{account}"
      plan -> "Connected as #{account} · #{plan}"
    end
  end

  def claude_connected_text(_login), do: "Connected to Claude"

  defp plan_label(plan) when is_binary(plan) and plan != "",
    do: "Claude " <> String.capitalize(plan)

  defp plan_label(_plan), do: nil

  defp failed_reason({:failed, reason}), do: reason
  defp failed_reason(_status), do: nil

  defp device_code(%{kind: :device_code, code: code}) when is_binary(code), do: code
  defp device_code(_), do: nil

  # The URL the host read from `codex login --device-auth`, else OpenAI's
  # measured device page, so step 1 works before the code has arrived.
  defp device_href(%{kind: :device_code, url: href}) when is_binary(href), do: href
  defp device_href(_), do: @device_url
end
