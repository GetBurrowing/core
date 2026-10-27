defmodule PlatformWeb.ControlCenter.NativeLogin do
  @moduledoc """
  Logging a native agent in, and its read-only "Recent output", on the
  agent's detail pane (task 01a10322 stage 6).

  ## What the login steps offer, and why there is no paste field

  The design canvas (01a10325-8f2d-7001-b858-b92639451ceb, "Login steps")
  drew a subscription login whose last step the person finishes in Burrow.
  Claude Code's subscription login only finishes when its code is typed back
  into the CLI, and Anthropic's terms forbid a third party relaying that code.
  So the subscription row here says it is **not available yet**, and the way
  to log in is an Anthropic API key (`Platform.Agents.NativeLogin`). There is
  NO paste field and no event that accepts a login code (a deviation from the
  canvas, listed in the stage 6 notes).

  Copy kept from the canvas: the heading "Log <Name> in to Claude", the API
  key heading "Use an Anthropic API key", the field label "API key", the
  success line "<Name> is logged in to Claude." The privacy line on the key
  path is "Stored encrypted in this install's vault."; the canvas's "Suite
  never sees your Claude token." belonged to the subscription path and is not
  shown, because that path is not offered.

  ## Who sees what

  Only `NativeAgents.can_manage?/2` users get the key form, Remove and
  "Recent output"; everyone else sees the state and "Someone who manages
  <Name> can log it in.". That is an affordance only:
  `PlatformWeb.ControlCenter.NativeAgentEvents` refuses each event for a
  non-manager whatever the page shows.

  The key is never rendered: the field has no `value`, and nothing about the
  key is ever put in an assign.

  ## Operator login mode (task 01a17b10 stage 1)

  When the install runs native agents in operator mode
  (`Platform.Agents.NativeLogin.login_mode/0`), the login steps show the
  attach-command TEMPLATE (placeholders only) in place of the API key field:
  a person with access to the server attaches to the agent's pane and logs in
  to Claude Code there, typing the code into Claude Code's own prompt. Burrow
  shows no login page, takes no code and has no key form in this mode.

  Pure rendering: no socket, no DB.
  """
  use Phoenix.Component

  alias Platform.Agents.NativeLogin, as: Login

  @doc "What a non-manager sees in place of the login controls."
  def locked_message(name), do: "Someone who manages #{name} can log it in."

  @doc "The success line, verbatim from the canvas."
  def logged_in_message(name), do: "#{name} is logged in to Claude."

  @doc "What operator mode says the operator does, under the attach command."
  def operator_code_line,
    do: "Type the login code into Claude Code's own prompt there. Burrow never sees it."

  @doc "The subscription row's state."
  def subscription_unavailable, do: "Not available yet"

  attr :agent, :map, required: true
  attr :can_manage?, :boolean, required: true
  attr :key_set?, :boolean, required: true
  # NativeLogin.step/3: :needs_key | :key_refused | :needs_operator
  attr :step, :atom, required: true
  # NativeLogin.login_mode/0
  attr :mode, :atom, default: :api_key

  @doc """
  The login steps. Shown in place of "Agent files" while the agent waits for
  a login (observed `needs_login`).
  """
  def panel(%{mode: :operator} = assigns) do
    assigns = assign(assigns, :command, Login.attach_command_template())

    ~H"""
    <section
      id="native-login"
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
      data-step={@step}
      data-mode="operator"
    >
      <h2 class="text-[22px] font-semibold leading-7 text-base-content">
        Log {@agent.name} in to Claude
      </h2>
      <p class="mt-1 max-w-prose text-sm text-base-content">
        This install logs agents in at their own terminal. {@agent.name} is waiting at
        Claude Code's login for someone with access to this server.
      </p>

      <div :if={@can_manage?} id="native-login-operator" class="mt-4 min-w-0">
        <h3 class="text-sm font-semibold text-base-content">Attach to {@agent.name}'s terminal</h3>
        <p class="mt-1 text-sm text-subtle">
          On the server, fill in the placeholders and run:
        </p>
        <pre
          id="native-login-attach-command"
          class="mt-2 overflow-x-auto whitespace-pre-wrap break-words rounded-box bg-neutral p-3 font-mono text-xs leading-5 text-neutral-content"
        >{@command}</pre>
        <p id="native-login-operator-code" class="mt-2 text-sm text-base-content">
          {operator_code_line()}
        </p>
      </div>
      <p :if={!@can_manage?} id="native-login-locked" class="mt-4 text-sm text-subtle">
        {locked_message(@agent.name)}
      </p>
    </section>
    """
  end

  def panel(assigns) do
    ~H"""
    <section
      id="native-login"
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
      data-step={@step}
    >
      <h2 class="text-[22px] font-semibold leading-7 text-base-content">
        Log {@agent.name} in to Claude
      </h2>
      <p class="mt-1 max-w-prose text-sm text-base-content">
        {@agent.name} runs Claude Code on this server. Logging in with a Claude subscription
        is not available yet, so {@agent.name} uses an Anthropic API key. You do this once.
      </p>

      <p
        :if={@step == :key_refused}
        id="native-login-key-refused"
        class="mt-4 rounded-box bg-error/10 px-4 py-3 text-sm text-base-content"
      >
        <span class="hero-exclamation-circle mr-1 inline-block h-4 w-4 align-text-bottom text-error" />
        {@agent.name} is still waiting for a login although a key is saved. Check the key and
        save it again.
      </p>

      <ol class="mt-5 space-y-5">
        <li id="native-login-subscription" class="flex items-start gap-3">
          <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-base-200 text-xs font-semibold text-subtle">
            1
          </span>
          <div class="min-w-0">
            <p class="flex flex-wrap items-center gap-2 text-sm font-semibold text-subtle">
              Claude subscription
              <span class="rounded-field bg-base-200 px-2 py-0.5 text-xs font-medium text-base-content">
                {subscription_unavailable()}
              </span>
            </p>
            <p class="mt-0.5 text-sm text-subtle">
              Burrow can't log an agent in to a Claude subscription yet.
            </p>
          </div>
        </li>

        <li class="flex items-start gap-3">
          <span class="flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-base-content text-xs font-semibold text-base-100">
            2
          </span>
          <div class="min-w-0 flex-1">
            <h3 class="text-sm font-semibold text-base-content">Use an Anthropic API key</h3>
            <.key_form :if={@can_manage?} agent={@agent} key_set?={@key_set?} />
            <p :if={!@can_manage?} id="native-login-locked" class="mt-1 text-sm text-subtle">
              {locked_message(@agent.name)}
            </p>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  attr :agent, :map, required: true
  attr :can_manage?, :boolean, required: true
  attr :key_set?, :boolean, required: true
  # NativeLogin.step/3
  attr :step, :atom, required: true
  # NativeLogin.login_mode/0
  attr :mode, :atom, default: :api_key

  @doc """
  The compact "Claude login" card shown under "Agent files" when the agent is
  not waiting for a login: whether a key is saved, waiting while the agent
  starts with it, and the logged-in line.
  """
  def summary(%{mode: :operator} = assigns) do
    ~H"""
    <section
      id="native-login-summary"
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
      data-step={@step}
      data-mode="operator"
    >
      <h2 class="text-lg font-semibold text-base-content">Claude login</h2>
      <p :if={@step == :logged_in} id="native-login-success" class="mt-1 text-sm text-base-content">
        <span class="hero-check-circle mr-1 inline-block h-4 w-4 align-text-bottom" />
        {logged_in_message(@agent.name)}
      </p>
      <p :if={@step == :waiting} id="native-login-waiting" class="mt-1 text-sm text-base-content">
        Waiting for {@agent.name} to start.
      </p>
      <p class="mt-1 text-sm text-subtle">
        {@agent.name} logs in at its own terminal, by someone with access to this server.
        No API key is used.
      </p>
    </section>
    """
  end

  def summary(assigns) do
    ~H"""
    <section
      id="native-login-summary"
      class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm"
      data-step={@step}
    >
      <h2 class="text-lg font-semibold text-base-content">Claude login</h2>
      <p :if={@step == :logged_in} id="native-login-success" class="mt-1 text-sm text-base-content">
        <span class="hero-check-circle mr-1 inline-block h-4 w-4 align-text-bottom" />
        {logged_in_message(@agent.name)}
      </p>
      <p :if={@step == :waiting} id="native-login-waiting" class="mt-1 text-sm text-base-content">
        Waiting for {@agent.name} to start with the API key.
      </p>
      <p
        :if={@step not in [:logged_in, :waiting]}
        class="mt-1 text-sm text-subtle"
      >
        {if @key_set?,
          do: "#{@agent.name} logs in with the Anthropic API key saved here.",
          else: "No API key saved. #{@agent.name} will ask for a login when it starts."}
      </p>
      <p class="mt-1 text-sm text-subtle">
        Claude subscription login: {String.downcase(subscription_unavailable())}.
      </p>

      <details :if={@can_manage?} class="mt-3">
        <summary class="cursor-pointer text-sm font-medium text-base-content">
          {if @key_set?, do: "Replace the API key", else: "Use an Anthropic API key"}
        </summary>
        <.key_form agent={@agent} key_set?={@key_set?} />
      </details>
      <p :if={!@can_manage?} class="mt-3 text-sm text-subtle">
        {locked_message(@agent.name)}
      </p>
    </section>
    """
  end

  attr :agent, :map, required: true
  attr :key_set?, :boolean, required: true

  defp key_form(assigns) do
    ~H"""
    <form
      id="native-api-key-form"
      phx-submit="native_api_key_save"
      autocomplete="off"
      class="mt-2 max-w-md space-y-2"
    >
      <input type="hidden" name="agent_id" value={@agent.id} />
      <label class="form-control w-full">
        <span class="mb-1 text-sm font-medium text-base-content">API key</span>
        <%!-- No `value`, ever: the key is never sent back to the page. --%>
        <input
          id="native-api-key-input"
          type="password"
          name="api_key[value]"
          autocomplete="off"
          spellcheck="false"
          placeholder={
            if @key_set?, do: "A key is saved. Paste a new one to replace it.", else: "sk-ant-…"
          }
          class="input input-bordered w-full font-mono"
          required
        />
      </label>
      <p class="text-xs text-subtle">Stored encrypted in this install's vault.</p>
      <div class="flex flex-wrap gap-2">
        <button id="native-api-key-save" type="submit" class="btn btn-primary btn-sm">
          Save key and restart
        </button>
        <button
          :if={@key_set?}
          id="native-api-key-remove"
          type="button"
          phx-click="native_api_key_remove"
          phx-value-agent_id={@agent.id}
          data-confirm="Remove the saved API key? The agent stops being able to reply until it has a new one."
          class="btn btn-ghost btn-sm"
        >
          Remove key
        </button>
      </div>
    </form>
    """
  end

  attr :agent, :map, required: true
  # nil (not loaded) | %{lines: [...], hidden: nil | :login} | {:error, reason}
  attr :output, :any, default: nil

  @doc """
  "Logs" with the read-only "Recent output" disclosure. Rendered for
  `can_manage?/2` users only (the caller decides). It has no input: the pane
  text is shown in a `<pre>`, and a login screen is withheld whole.
  """
  def logs(assigns) do
    ~H"""
    <section id="native-logs" class="rounded-3xl border border-edge bg-base-100 p-5 shadow-sm">
      <h2 class="text-lg font-semibold text-base-content">Logs</h2>
      <details id="native-recent-output" class="mt-2" open={not is_nil(@output)}>
        <summary class="cursor-pointer text-sm font-medium text-base-content">Recent output</summary>
        <p class="mt-1 text-xs text-subtle">
          What {@agent.name}'s terminal shows, for debugging. Read only. Login screens are never shown.
        </p>
        <button
          id="native-recent-output-load"
          type="button"
          phx-click="native_recent_output"
          phx-value-agent_id={@agent.id}
          class="btn btn-sm mt-2"
        >
          {if is_nil(@output), do: "Show recent output", else: "Refresh"}
        </button>
        <%= case @output do %>
          <% %{hidden: :login} -> %>
            <p id="native-recent-output-hidden" class="mt-3 text-sm text-base-content">
              {@agent.name} is showing a login screen, so its output is hidden.
            </p>
          <% %{lines: []} -> %>
            <p class="mt-3 text-sm text-subtle">Nothing to show.</p>
          <% %{lines: lines} -> %>
            <pre
              id="native-recent-output-text"
              class="mt-3 max-h-96 overflow-auto rounded-box bg-neutral p-3 font-mono text-xs leading-5 text-neutral-content"
            >{Enum.join(lines, "\n")}</pre>
          <% {:error, reason} -> %>
            <p class="mt-3 text-sm text-base-content">
              Could not read the output: {error_text(reason)}.
            </p>
          <% _ -> %>
        <% end %>
      </details>
    </section>
    """
  end

  defp error_text(:not_connected), do: "no agent host is connected"
  defp error_text(:timeout), do: "the agent host did not answer in time"
  defp error_text(_), do: "something went wrong"
end
