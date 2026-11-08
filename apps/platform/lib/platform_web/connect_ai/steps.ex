defmodule PlatformWeb.ConnectAi.Steps do
  @moduledoc """
  The Connect AI sign-in steps (task 01a1b365's #106 card), shared by
  `/setup/connect-ai` (`PlatformWeb.ConnectAiLive`, the Burrow agent) and the
  per-agent panel (`PlatformWeb.ConnectAi.Panel`, task 01a1b84b): the Claude
  card's state machine and the markup of both providers' numbered steps.

  Every DOM id is `<prefix>-...`, `prefix` defaulting to `"connect-ai"`, so
  `/setup/connect-ai` keeps its ids. `target` is the `phx-target` of the
  steps' events: nil (the page itself) or a component's `@myself`.

  ## The Claude card's state

  `link`: :idle (no sign-in link asked for yet), :loading, :ready or
  :unavailable. `status`: :idle, :connecting, `{:failed, :bad_code |
  :no_subscription | :server}` or :connected. `login` is a submit's
  `%{account, plan}`. Never the code.

  The pending login is bound to the process that starts it
  (`Platform.AgentHost.Reconciler`), so the caller runs `start/4` and
  `finish_submit/5` from its own LiveView process, after the render that
  shows the "waiting" line: a LiveView with `send(self(), ...)`, a component
  with `send_update/3` (which runs in the LiveView's process too).

  The pasted code is wrapped in a `Platform.AgentHost.LoginCode` by
  `submit/2` at once and handed back in the action to schedule; it is never
  put in the state, logged or rendered. The code form is `phx-submit` only
  and its field never has a value; the `ConnectAiCode` hook does the Show
  toggle and clears the field on `connect-ai-clear-code`.
  """
  use Phoenix.Component

  alias Platform.AgentHost
  alias Platform.AgentHost.LoginCode

  @device_url "https://auth.openai.com/codex/device"

  @claude_idle %{url: nil, link: :idle, opened?: false, status: :idle, login: nil}

  @type claude :: %{
          url: String.t() | nil,
          link: :idle | :loading | :ready | :unavailable,
          opened?: boolean(),
          status: :idle | :connecting | :connected | {:failed, atom()},
          login: map() | nil
        }

  @typedoc "Work the caller runs from its own process after this render."
  @type action :: nil | :claude_login_start | {:claude_submit, LoginCode.t()}

  @doc "The Claude card before anything happened."
  @spec idle() :: claude()
  def idle, do: @claude_idle

  @doc "A sign-in link is being asked for (the caller schedules `:claude_login_start`)."
  @spec loading(claude()) :: claude()
  def loading(claude), do: %{claude | link: :loading}

  @doc "The owner opened the sign-in link: step 2 opens."
  @spec opened(claude()) :: claude()
  def opened(claude) do
    if claude.link == :ready,
      do: %{claude | opened?: true, status: idle_unless_failed(claude.status)},
      else: claude
  end

  @doc """
  The code form's submit. The raw `"code"` param goes no further than
  `LoginCode.new/1`; a shaped code comes back wrapped, as the action to run.
  """
  @spec submit(claude(), map()) :: {claude(), action()}
  def submit(claude, params) do
    if step_two_active?(claude) and claude.status != :connecting do
      case LoginCode.new(Map.get(params, "code")) do
        {:ok, code} -> {%{claude | status: :connecting}, {:claude_submit, code}}
        {:error, :bad_code} -> {%{claude | status: {:failed, :bad_code}}, nil}
      end
    else
      {claude, nil}
    end
  end

  @doc "Step 1's Try again: ask for a fresh link when none could be had."
  @spec retry_link(claude()) :: {claude(), action()}
  def retry_link(claude) do
    if claude.link == :unavailable,
      do: {loading(claude), :claude_login_start},
      else: {claude, nil}
  end

  @doc "Start `agent`'s Claude login as `actor`, from the caller's process."
  @spec start(map(), Platform.Agents.Agent.t(), claude()) :: claude()
  def start(actor, agent, claude) do
    case AgentHost.claude_login_start(actor, agent, login_opts()) do
      {:ok, url} -> %{claude | url: url, link: :ready}
      {:error, _reason} -> %{claude | url: nil, link: :unavailable}
    end
  end

  @doc """
  Hand the wrapped `code` to `agent`'s pending login, as `actor`, from the
  caller's process. A failure ended the pending login, so it asks for a
  fresh link (`:claude_login_start`) for "Open Claude sign-in again".
  """
  @spec finish_submit(map(), Platform.Agents.Agent.t(), claude(), LoginCode.t()) ::
          {claude(), action()}
  def finish_submit(actor, agent, claude, %LoginCode{} = code) do
    case AgentHost.claude_login_submit(actor, agent, code, login_opts()) do
      {:ok, login} ->
        {%{claude | status: :connected, login: login}, nil}

      {:error, reason} ->
        claude = %{
          claude
          | status: {:failed, submit_failure(reason)},
            opened?: false,
            link: :loading,
            url: nil
        }

        {claude, :claude_login_start}
    end
  end

  # `claude_login_timeout_ms:` in ConnectAiLive's config shortens the wait on
  # the agent host (tests); otherwise `AgentHost`'s own defaults apply.
  defp login_opts do
    config = Application.get_env(:platform, PlatformWeb.ConnectAiLive, [])

    case Keyword.get(config, :claude_login_timeout_ms) do
      ms when is_integer(ms) and ms > 0 -> [timeout: ms]
      _ -> []
    end
  end

  defp submit_failure(reason) when reason in [:bad_code, :no_session], do: :bad_code
  defp submit_failure(:no_subscription), do: :no_subscription
  defp submit_failure(_reason), do: :server

  defp idle_unless_failed({:failed, _} = status), do: status
  defp idle_unless_failed(_status), do: :idle

  @doc "True once step 2 (paste the code) is open."
  @spec step_two_active?(claude()) :: boolean()
  def step_two_active?(%{opened?: true}), do: true
  def step_two_active?(%{status: {:failed, _}}), do: true
  def step_two_active?(%{status: :connecting}), do: true
  def step_two_active?(_claude), do: false

  @doc "What the Claude card says when a sign-in fails, by reason."
  def claude_failure_text(:bad_code),
    do:
      "That code didn't work. Codes expire after a few minutes. Open Claude sign-in again and paste the new code."

  def claude_failure_text(:no_subscription),
    do: "This account doesn't have Claude Pro or Max. Sign in with the account that does."

  def claude_failure_text(:server),
    do:
      "Your server didn't answer. Try again in a minute; if it keeps happening, ask Burrow support."

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

  @doc false
  def device_code(%{kind: :device_code, code: code}) when is_binary(code), do: code
  def device_code(_), do: nil

  # The URL the host read from `codex login --device-auth`, else OpenAI's
  # measured device page, so step 1 works before the code has arrived.
  @doc false
  def device_href(%{kind: :device_code, url: href}) when is_binary(href), do: href
  def device_href(_), do: @device_url

  # ── Markup ──────────────────────────────────────────────────────────

  attr(:n, :integer, required: true)

  def step_rail(assigns) do
    ~H"""
    <div class="flex w-12 shrink-0 justify-center bg-base-200 pt-4" aria-hidden="true">
      <span class="flex size-7 items-center justify-center rounded-full border border-edge bg-base-100 text-sm font-semibold text-base-content">
        {@n}
      </span>
    </div>
    """
  end

  attr(:prefix, :string, default: "connect-ai")
  attr(:login, :any, required: true)
  attr(:running?, :boolean, required: true)
  attr(:agent_name, :string, required: true)
  attr(:show_status?, :boolean, default: true)

  @doc "ChatGPT (Codex): open OpenAI's sign-in page, then enter the code the host read."
  def codex_card(assigns) do
    ~H"""
    <ol
      id={"#{@prefix}-codex-card"}
      class="divide-y divide-edge overflow-hidden rounded-box border border-edge bg-base-100"
    >
      <li id={"#{@prefix}-codex-step-1"} class="flex">
        <.step_rail n={1} />
        <div class="min-w-0 flex-1 space-y-2 p-4">
          <p class="text-base font-medium text-base-content">Sign in to ChatGPT.</p>
          <a
            id={"#{@prefix}-codex-open"}
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
      <li id={"#{@prefix}-codex-step-2"} class="flex">
        <.step_rail n={2} />
        <div class="min-w-0 flex-1 space-y-2 p-4">
          <p class="text-base font-medium text-base-content">Enter this code there:</p>
          <div
            id={"#{@prefix}-code-callout"}
            class="flex items-center gap-2 rounded-box border border-info/40 bg-info/10 p-4 text-base-content"
          >
            <%= if code = device_code(@login) do %>
              <span
                id={"#{@prefix}-code"}
                class="min-w-0 flex-1 font-mono text-sm tracking-widest"
              >
                {code}
              </span>
              <button
                type="button"
                id={"#{@prefix}-code-copy"}
                phx-hook="CopyToClipboard"
                data-clipboard-text={code}
                class="btn btn-ghost btn-sm min-h-11 shrink-0"
              >
                Copy
              </button>
            <% else %>
              <span id={"#{@prefix}-code-pending"} class="flex-1 text-sm text-base-content">
                Getting a fresh code...
              </span>
            <% end %>
          </div>
          <p class="text-sm text-subtle">
            A code lasts 15 minutes. A new one appears here by itself if it runs out.
          </p>
          <.status_line
            :if={@show_status?}
            prefix={@prefix}
            running?={@running?}
            agent_name={@agent_name}
          />
        </div>
      </li>
    </ol>
    """
  end

  attr(:prefix, :string, default: "connect-ai")
  attr(:target, :any, default: nil)
  attr(:claude, :map, required: true)

  @doc "Claude Pro or Max: open Claude's sign-in page, then paste the code it shows."
  def claude_card(%{claude: %{status: :connected}} = assigns) do
    ~H"""
    <div id={"#{@prefix}-claude-card"} class="rounded-box border border-edge bg-base-100">
      <.claude_connected prefix={@prefix} target={@target} login={@claude.login} class="p-4" />
    </div>
    """
  end

  def claude_card(assigns) do
    assigns =
      assigns
      |> assign(:active?, step_two_active?(assigns.claude))
      |> assign(:connecting?, assigns.claude.status == :connecting)
      |> assign(:failed, failed_reason(assigns.claude.status))

    ~H"""
    <ol
      id={"#{@prefix}-claude-card"}
      class="divide-y divide-edge overflow-hidden rounded-box border border-edge bg-base-100"
    >
      <li id={"#{@prefix}-claude-step-1"} class="flex">
        <.step_rail n={1} />
        <div class="min-w-0 flex-1 space-y-2 p-4">
          <p class="text-base font-medium text-base-content">Sign in to Claude</p>
          <p class="text-sm text-base-content">
            Opens claude.ai in a new tab. Sign in with the account that has your Pro or Max plan.
          </p>
          <%= cond do %>
            <% @claude.opened? and @claude.link == :ready -> %>
              <p
                id={"#{@prefix}-claude-opened"}
                class="flex flex-wrap items-center gap-x-2 text-sm text-base-content"
              >
                <span class="hero-check size-4 shrink-0" /> Opened in a new tab
                <a
                  id={"#{@prefix}-claude-open-again"}
                  href={@claude.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  phx-click="claude_opened"
                  phx-target={@target}
                  class="inline-flex min-h-11 items-center underline underline-offset-2"
                >
                  Open it again
                </a>
              </p>
            <% @claude.link == :ready -> %>
              <a
                id={"#{@prefix}-claude-open"}
                href={@claude.url}
                target="_blank"
                rel="noopener noreferrer"
                phx-click="claude_opened"
                phx-target={@target}
                class="btn btn-primary min-h-11"
              >
                Open Claude sign-in ↗
              </a>
            <% @claude.link == :unavailable -> %>
              <p
                id={"#{@prefix}-claude-link-error"}
                class="flex items-start gap-2 text-sm text-error"
              >
                <span class="hero-exclamation-circle mt-0.5 size-4 shrink-0" />
                <span>{claude_failure_text(:server)}</span>
              </p>
              <button
                id={"#{@prefix}-claude-retry-link"}
                type="button"
                phx-click="claude_retry_link"
                phx-target={@target}
                class="btn btn-outline min-h-11"
              >
                Try again
              </button>
            <% true -> %>
              <span
                id={"#{@prefix}-claude-open-pending"}
                class="btn btn-primary btn-disabled min-h-11"
                aria-disabled="true"
              >
                Open Claude sign-in ↗
              </span>
          <% end %>
        </div>
      </li>
      <li id={"#{@prefix}-claude-step-2"} class={["flex", !@active? && "opacity-60"]}>
        <.step_rail n={2} />
        <div class="min-w-0 flex-1 space-y-2 p-4">
          <p class="text-base font-medium text-base-content">Paste the code Claude shows you</p>
          <p :if={!@active?} id={"#{@prefix}-claude-locked"} class="text-sm text-base-content">
            Do step 1 first.
          </p>
          <%!-- phx-submit only: no phx-change, so no keystroke reaches the
               server. The field never has a `value`; ConnectAiCode does the
               show toggle and clears it, in the browser. --%>
          <form
            id={"#{@prefix}-claude-form"}
            phx-submit="claude_submit"
            phx-target={@target}
            phx-hook="ConnectAiCode"
            autocomplete="off"
            class="space-y-2"
          >
            <div class="flex flex-wrap gap-2">
              <label class="input input-bordered flex min-h-11 min-w-0 flex-1 basis-48 items-center gap-2">
                <span class="sr-only">Code from Claude</span>
                <input
                  id={"#{@prefix}-claude-code"}
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
                  id={"#{@prefix}-claude-code-toggle"}
                  type="button"
                  data-code-toggle
                  aria-controls={"#{@prefix}-claude-code"}
                  aria-pressed="false"
                  class="btn btn-ghost btn-xs shrink-0"
                  disabled={!@active? or @connecting?}
                >
                  Show
                </button>
              </label>
              <button
                id={"#{@prefix}-claude-connect"}
                type="submit"
                class="btn btn-primary min-h-11"
                disabled={!@active? or @connecting?}
              >
                Connect
              </button>
            </div>
            <p id={"#{@prefix}-claude-reassurance"} class="text-sm text-base-content">
              The code goes straight to your Burrow's assistant on your server. Burrow doesn't keep it.
            </p>
          </form>
          <p
            :if={@active? and @claude.status == :idle}
            id={"#{@prefix}-claude-waiting"}
            class="flex items-center gap-2 text-sm text-info"
          >
            <span class="hero-arrow-path size-4 shrink-0 animate-spin" /> Waiting for the code…
          </p>
          <p
            :if={@connecting?}
            id={"#{@prefix}-claude-connecting"}
            class="flex items-center gap-2 text-sm text-info"
          >
            <span class="hero-arrow-path size-4 shrink-0 animate-spin" /> Connecting…
          </p>
          <p
            :if={@failed}
            id={"#{@prefix}-claude-error"}
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

  attr(:prefix, :string, default: "connect-ai")
  attr(:target, :any, default: nil)
  attr(:login, :any, required: true)
  attr(:class, :string, default: nil)
  attr(:disconnect?, :boolean, default: true)

  @doc "The Claude connected line, with Disconnect (Claude only: ChatGPT has no host logout)."
  def claude_connected(assigns) do
    ~H"""
    <div
      id={"#{@prefix}-claude-connected"}
      class={["flex flex-wrap items-center gap-x-3 gap-y-1", @class]}
    >
      <p class="flex items-center gap-2 text-base">
        <span class="hero-check-circle size-5 shrink-0 text-success" />
        <span class="font-medium text-success">{claude_connected_text(@login)}</span>
      </p>
      <button
        :if={@disconnect?}
        id={"#{@prefix}-claude-disconnect"}
        type="button"
        phx-click="claude_disconnect"
        phx-target={@target}
        class="btn btn-ghost btn-sm min-h-11"
      >
        Disconnect
      </button>
    </div>
    """
  end

  attr(:prefix, :string, default: "connect-ai")
  attr(:running?, :boolean, required: true)
  attr(:agent_name, :string, required: true)

  def status_line(assigns) do
    ~H"""
    <p
      :if={!@running?}
      id={"#{@prefix}-status"}
      class="flex items-center gap-2 text-base text-base-content"
    >
      <span class="hero-arrow-path size-5 shrink-0 animate-spin text-info" />
      <span class="font-medium text-info">Waiting for sign-in...</span>
    </p>
    <p
      :if={@running?}
      id={"#{@prefix}-status"}
      class="flex items-center gap-2 text-base text-base-content"
    >
      <span class="hero-check-circle size-5 shrink-0 text-neutral" />
      {@agent_name} is connected.
    </p>
    """
  end
end
