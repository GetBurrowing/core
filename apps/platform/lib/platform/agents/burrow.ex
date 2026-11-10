defmodule Platform.Agents.Burrow do
  @moduledoc """
  The install's own native agent, "Burrow" (task 01a17b10; task 01a19505): the
  first agent a new install's owner connects, whatever its provider, and the
  one that walks them through finishing setup.

  ## Creation: `ensure/2`, from `/setup/connect-ai` only

  Burrow is created when the owner connects their first AI on
  `/setup/connect-ai` (`PlatformWeb.ConnectAiLive`), on the provider they
  choose. Nothing creates it at boot. The one other path is the starter
  allowance (`ensure_starter/1`, `Platform.Agents.Burrow.Starter`): on an
  install configured with a starter key, the first hand-over sign-in creates
  it on that key, and the owner's later choice on `/setup/connect-ai` goes
  through `ensure/2`, which retires the starter.

  `ensure/2` creates, or reuses, the ONE native agent named "Burrow" (slug
  `burrow`) and starts it. The harness follows the connect option
  (`harness_for/1`): ChatGPT (Codex) runs `codex`; an API key and a Claude Pro
  or Max subscription run `claude_code`. A Burrow that is already running keeps
  its harness; one that is not running and runs a different harness is
  stopped, switched (`NativeAgents.set_harness/2`) and started, which also
  covers an unconnected Burrow left by older code that created it at boot.
  Whatever the harness, its instructions file carries the role and the setup
  guide (`identity_template/2`).

  Creation goes through `Platform.Agents.NativeAgents.create/2` and so through
  `Platform.Federation.provision_agent_runtime/3`: on an empty install Burrow
  is the first external agent and takes `metadata.first_agent_grant`. There is
  no second grant path.

  The "Getting started" space it opens once connected lives in
  `Platform.Agents.Burrow.GettingStarted`.

  ## Default roles

  `ensure/2` pins Burrow to each of `default_roles/0` (`historian`,
  `meeting_scribe`, `meeting_producer`, `triage_officer`) that NO agent holds,
  through `Platform.Roles.assign_role/2`, so historian curation (org-page
  writes, starting with `org/page/identity.md` in the setup guide) and the
  meeting roles work from the first run (task 01a19aa4 stage 2). A role
  another agent already holds is never taken; `assign_role/2` does not
  replace a pinned role either. Re-running `ensure/2` changes nothing. The
  owner can change the roles later in the Control Center.

  ## Owner and admins

  The owner is `Platform.Accounts.install_owner/0` (the earliest non-archived
  root-org admin); admins are `Platform.Accounts.install_admins/0`. `admins_section/0` reads them from the database
  each time and renders name and principal id (the user id). `start_files/1`
  in `NativeAgents` appends that section to Burrow's instructions file, so
  every `agent.start` carries the current list and a removed admin is gone at
  the next start. The section is generated, never stored.
  """

  require Logger

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Agents.Burrow.Starter
  alias Platform.Roles

  @name "Burrow"
  @slug "burrow"
  @default_roles ~w(historian meeting_scribe meeting_producer triage_officer)

  @doc "The roles `ensure/2` gives Burrow when no agent holds them."
  @spec default_roles() :: [String.t()]
  def default_roles, do: @default_roles

  @doc "The agent's display name."
  def name, do: @name

  @doc "The harness each connect option runs."
  @spec harness_for(atom()) :: String.t()
  def harness_for(:codex), do: "codex"
  def harness_for(:api_key), do: "claude_code"
  def harness_for(:claude_subscription), do: "claude_code"

  @doc "The Burrow agent's runtime harness, or nil."
  @spec harness(Agent.t() | nil) :: String.t() | nil
  def harness(nil), do: nil

  def harness(%Agent{} = agent) do
    case NativeAgents.get_managed_runtime(agent) do
      %AgentRuntime{harness: harness} -> harness
      nil -> nil
    end
  end

  @doc "True when the Burrow agent exists and the agent host reports it running."
  @spec connected?() :: boolean()
  def connected?, do: running?(get())

  @doc "True when `agent` is observed running."
  @spec running?(Agent.t() | nil) :: boolean()
  def running?(nil), do: false
  def running?(%Agent{} = agent), do: match?(%{state: :running}, AgentHost.status(agent))

  @doc """
  Create or reuse the Burrow agent owned by `owner_id`, running `harness`, and
  start it. A Burrow that is already running keeps its harness; one that is
  not running and runs a different harness is switched. Returns `{:ok, agent}`
  or `{:error, reason}`.

  This is the owner's own choice, so it also ends the starter allowance: a
  Burrow marked as running on the starter key (`Starter.active?/1`) is retired
  first, then stopped, moved to `harness` (a running one too) and started, so
  its next `agent.start` carries no starter key. That is why a running starter
  Burrow, unlike any other running Burrow, is restarted here.
  """
  @spec ensure(binary(), String.t()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure(owner_id, harness) when is_binary(owner_id) and harness in ~w(claude_code codex) do
    owner_id
    |> ensure_or_leave_starter(harness, get())
    |> assign_default_roles()
  end

  defp ensure_or_leave_starter(owner_id, harness, agent) do
    if Starter.active?(agent),
      do: leave_starter(agent, harness),
      else: ensure_agent(owner_id, harness)
  end

  @doc """
  Create Burrow on the starter key for `owner_id`, mark it, and start it.
  `{:ok, agent}` for the one that exists when any Burrow already does (nothing
  is changed), `{:error, :no_starter_key}` without a configured key.
  """
  @spec ensure_starter(binary()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure_starter(owner_id) when is_binary(owner_id) do
    with true <- Starter.configured?() || {:error, :no_starter_key},
         nil <- get() do
      # The mark goes on before the first start, so that start carries the key.
      with {:ok, agent, _runtime} <-
             NativeAgents.create(owner_id, %{name: @name, harness: harness_for(:api_key)}),
           {:ok, agent} <- Starter.activate(agent),
           {:ok, agent} <- start(agent) do
        assign_default_roles({:ok, agent})
      else
        # Lost a race with another sign-in: the winner's Burrow is ours.
        {:error, reason} -> existing_or_error(reason)
      end
    else
      %Agent{} = agent -> {:ok, agent}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_or_error(reason) do
    case get() do
      %Agent{} = agent -> {:ok, agent}
      nil -> {:error, reason}
    end
  end

  defp leave_starter(agent, harness) do
    {:ok, _} = Starter.retire(agent)
    _ = AgentHost.stop_agent(agent)

    case NativeAgents.set_harness(agent, harness) do
      {:ok, _runtime} -> start(agent)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_agent(owner_id, harness) do
    case get() do
      nil ->
        create(owner_id, harness)

      %Agent{} = agent ->
        cond do
          running?(agent) ->
            {:ok, agent}

          harness(agent) == harness ->
            start(agent)

          true ->
            switch(agent, harness)
        end
    end
  end

  defp create(owner_id, harness) do
    case NativeAgents.create(owner_id, %{name: @name, harness: harness}) do
      {:ok, agent, _runtime} ->
        start(agent)

      {:error, reason} ->
        # Lost a race with another tab: the agent the winner made is ours too.
        case get() do
          %Agent{} = agent -> ensure_agent(owner_id, harness_or(agent, harness))
          nil -> {:error, reason}
        end
    end
  end

  # Only roles no agent holds: never take a role from another agent.
  defp assign_default_roles({:ok, %Agent{id: agent_id}} = ok) do
    for role <- @default_roles, is_nil(Roles.agent_id_for_role(role)) do
      case Roles.assign_role(role, agent_id) do
        {:ok, _assignment} ->
          :ok

        {:error, reason} ->
          # Lost a race for the role: whoever holds it now keeps it.
          Logger.warning("[Burrow] role #{role} not assigned: #{inspect(reason)}")
      end
    end

    ok
  end

  defp assign_default_roles(other), do: other

  defp harness_or(agent, fallback), do: harness(agent) || fallback

  defp switch(agent, harness) do
    _ = AgentHost.stop_agent(agent)

    case NativeAgents.set_harness(agent, harness) do
      {:ok, _runtime} -> start(agent)
      {:error, reason} -> {:error, reason}
    end
  end

  defp start(agent) do
    # Not connected to a host is not an error here: the screen says so, and
    # the reconciler starts the agent when the host joins.
    _ = AgentHost.start_agent(agent)
    {:ok, agent}
  end

  @doc """
  The OS account the agent host runs `agent` as: `agent-<last 12 hex of its
  id>` (services/agent-host/src/ids.ts `userName`; the tail, because the head
  of a UUIDv7 is a clock).
  """
  @spec os_user(Agent.t()) :: String.t()
  def os_user(%Agent{id: id}), do: "agent-" <> String.slice(id, -12, 12)

  @doc "The Burrow agent (a native agent with slug `burrow`), or nil."
  @spec get() :: Agent.t() | nil
  def get do
    Enum.find_value(NativeAgents.list(), fn %{agent: a} -> a.slug == @slug && a end)
  end

  @doc "True when `agent` is the Burrow agent."
  def burrow?(%Agent{slug: @slug} = agent), do: NativeAgents.managed?(agent)
  def burrow?(_), do: false

  @doc "Root-org admins as `%{id, name}`; see `Platform.Accounts.install_admins/0`."
  defdelegate admins, to: Platform.Accounts, as: :install_admins

  @doc "The install owner; see `Platform.Accounts.install_owner/0`."
  defdelegate owner, to: Platform.Accounts, as: :install_owner

  @doc "The generated owner / admins section appended to Burrow's instructions file."
  @spec admins_section() :: String.t()
  def admins_section do
    admins = admins()

    owner_line =
      case admins do
        [o | _] -> "- Owner: #{o.name} (principal #{o.id})"
        [] -> "- Owner: none"
      end

    admin_lines =
      case admins do
        [] -> ["- none"]
        list -> Enum.map(list, &"- #{&1.name} (principal #{&1.id})")
      end

    """

    ## Owner and admins (generated at start)

    #{owner_line}

    Admins of this install:

    #{Enum.join(admin_lines, "\n")}
    """
  end

  @doc """
  Burrow's instructions file (`CLAUDE.md` or `AGENTS.md`) for `harness`: the
  shared native-agent identity, its role and bundles, and the setup guide.
  """
  @spec identity_template(String.t(), String.t()) :: String.t()
  def identity_template(name, harness) do
    NativeAgents.identity_template(name, harness) <>
      """

      ## Your role

      You are the orchestrator and infra desk for this install, and the one agent
      for everyone on it: you work for every member. You plan and route work, keep
      the machine and its services healthy, and answer for the install's state to
      its owner and admins (listed at the end of this file).

      ## Bundles you use

      - `task` and `plan`: read tasks, draft and submit plans, and create projects
        (`project_create`).
      - `messaging` and `space`: talk to people and agents in spaces.
      - `memory`: keep durable notes about this install and, while you hold the
        historian role, the org's pages such as `org/page/identity.md`.
      - `context_read`: read shared context.
      - `admin`: install administration, when your tool profile includes it.

      Use only what your profile gives you.

      ## Helping your owner finish setup

      You are the first agent on a new install, and your owner may not be technical.
      In the "Getting started" space, help them finish setting up, one step at a time:

      1. Get to know them and why they want Burrow. Ask probing questions, one at a
         time and in plain words: who they and their org are, what they do and why,
         who is involved, and what they want to achieve with Burrow. Shape each
         question to their last answer. People come to Burrow for very different
         reasons; if they seem unsure, offer a few example uses, then follow their
         lead.
      2. Write what you learned to org memory with your memory tools, starting with
         `org/page/identity.md`, the page every agent reads when it starts. Read it
         back to them and fix anything they correct.
      3. Create a first project named for that work. Propose a short name, confirm
         it with them, then call `project_create`. Say that meetings and tasks live
         inside a project. If `project_create` is not among your tools, send them to
         the "New Project" button on /tasks and wait for them to finish.
      4. Help them create a first space for real work in that project, and say what
         it is for.
      5. Offer to shape how you work for them: your focus, your habits, and what you
         should remember. Save what they want remembered to memory as you go. Your
         instructions file is edited by the owner on your config page in Burrow
         (/control/burrow/config); give them the link and say what to add there.

      If your "Your allowance" section (at the end of this file) says you are running
      on a starter allowance, then in this first conversation ask the owner once, in
      plain words, whether they already use ChatGPT or Claude. If they do, say that
      until they connect it you run on a limited starter allowance Burrow provides, and
      give them the link /setup/connect-ai, where connecting their own plan swaps you
      over. If they do not, carry on and do not ask again.

      If anyone (owner or member) says they want to start a project, help them create one the same way.

      Burrow is where their team chats, meets, plans and tracks work, and where that
      work and what they know stay. Never suggest they need a separate chat or work tool, and never name one (Slack, Teams, a task tracker) as something to set up alongside Burrow.
      Bringing their data in, such as importing from a file store, is welcome.
      Offer to connect another service (email, calendar, files) only when a goal
      they described needs it, and say plainly that a connection rarely works as
      well as doing the work in Burrow itself. Work they move into Burrow can
      replace outside services they pay for.

      Mention adding another agent only when their aims call for it, such as a group pooling several people's AI subscriptions; it is not a normal next step.

      Use plain words, not technical ones. Never ask them to open a terminal. When a
      step needs their consent or a sign-in, give them the link or button in Burrow
      and wait for them to finish it; never do it for them.

      ## Channels started from a first goal

      A new member's first goal opens a channel with you in it, named after the goal
      as a placeholder. You can tell such a channel because `space_get_context` shows
      `origin: "first_run_goal"` for it, and the goal message carries metadata source
      `first_run_goal`.

      1. When you receive the first message in such a channel, reply to the goal.
         In that same first reply, propose ONE short channel name: plain and
         descriptive, at most 5 words, no emoji, no puns. Say the current name is a
         placeholder and ask whether they want to use yours.
      2. If the member accepts, call `space_rename` with the name you proposed. If
         they give a different name, call `space_rename` with theirs.
      3. If they ignore the suggestion, do not ask again.
      4. Never rename a channel nobody agreed to rename.

      ## The Help & feedback channel

      You watch the "Help & feedback" channel: posts there come to you without a
      mention. Answer what you can yourself, in plain words.

      When a post describes a real bug in Burrow, or asks for a concrete change to
      Burrow, call `feedback_submit` once, with `space_id` set to that channel's id.
      Write the report in your own words: what they expected, what happened, and the
      steps. Leave out names, emails and anything private. Then reply in the post's
      thread with the issue link from the result. If the result says `duplicate`,
      say it is already reported and give the same link.

      If `feedback_submit` refuses because help channel reports are off, say the
      install is not sharing bug reports with Burrow and an install admin can turn
      "Help channel bug reports" on in Settings. Do not retry.

      `sharing_list` shows what this install shares with Burrow and `sharing_set`
      turns one part on or off. Use them only when an install admin asks you to.
      """
  end
end
