defmodule Platform.Agents.Burrow do
  @moduledoc """
  The install's own native agent, "Burrow" (task 01a17b10; task 01a19505): the
  first agent a new install's owner connects, whatever its provider, and the
  one that walks them through finishing setup.

  ## Creation: `ensure/2`, from `/setup/connect-ai` only

  Burrow is created when the owner connects their first AI on
  `/setup/connect-ai` (`PlatformWeb.ConnectAiLive`), on the provider they
  choose. Nothing creates it at boot or at login.

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

  Burrow holds every role in `Platform.Roles.Role.valid_keys/0` that no other
  agent holds (`default_roles/0` is that roster, derived, never a second
  list), so all of the install's role work, from historian curation and the
  meeting roles to the architect gate and the scheduled sweeps, runs from the
  first run. `ensure/2` fills them through `fill_unheld_roles/1`, and existing
  installs got the same fill once from the data migration
  `burrow_holds_unheld_roles`. A role another agent holds is never taken;
  `Platform.Roles.assign_role/2` does not replace a pinned role either.
  Re-running `ensure/2` changes nothing. The owner can hand any role to a
  specialist in the Control Center.

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
  alias Platform.Roles

  @name "Burrow"
  @slug "burrow"

  @doc """
  The roles `ensure/2` gives Burrow when no agent holds them: the whole
  roster, `Platform.Roles.Role.valid_keys/0`.
  """
  @spec default_roles() :: [String.t()]
  def default_roles, do: Platform.Roles.Role.valid_keys()

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
  """
  @spec ensure(binary(), String.t()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure(owner_id, harness) when is_binary(owner_id) and harness in ~w(claude_code codex) do
    owner_id
    |> ensure_agent(harness)
    |> fill_after_ensure()
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

  defp fill_after_ensure({:ok, %Agent{} = agent} = ok) do
    _taken = fill_unheld_roles(agent)
    ok
  end

  defp fill_after_ensure(other), do: other

  @doc """
  Give `agent` every role in `default_roles/0` that no agent holds, through
  `Platform.Roles.assign_role/2`. Returns the role keys it took.

  It never takes a role another agent holds (one agent per role), and a role
  lost to a concurrent insert is logged and left with its winner. A second
  run takes nothing and writes nothing.
  """
  @spec fill_unheld_roles(Agent.t()) :: [String.t()]
  def fill_unheld_roles(%Agent{id: agent_id}) do
    for role <- default_roles(),
        is_nil(Roles.agent_id_for_role(role)),
        taken?(role, agent_id),
        do: role
  end

  defp taken?(role, agent_id) do
    case Roles.assign_role(role, agent_id) do
      {:ok, _assignment} ->
        true

      {:error, reason} ->
        # Lost a race for the role: whoever holds it now keeps it.
        Logger.warning("[Burrow] role #{role} not assigned: #{inspect(reason)}")
        false
    end
  end

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

  @roles_marker "## Roles you hold (as of your last start)"
  @guidance_marker "## Splitting roles off"

  @role_guidance """
  #{@guidance_marker}

  You hold every role on this install that no other agent holds, so all of this work runs from day one: the team's memory, meeting notes, triage, design direction, security scans, architecture review, the agents goal, experiments and the weekly chores.

  That includes gates and scheduled jobs. You are the architect on every plan submit, so your verdict gates planning, and you run the designer's pre-plan design direction. You also run the janitor's weekly chore drain, the scientist's experiments and the architect's weekly sweep. Splitting those off is a common first move.

  Your role list under "Roles you hold" is from your last start. A role handed to another agent since then still shows there until you restart, so confirm in Control Center, or ask the owner, before you act on it.

  Why the owner might hand a role to a dedicated agent:

  - It can run a different model or tools, picked for that one kind of work.
  - It keeps its context focused on one kind of work, instead of sharing yours with everything else.
  - It works at the same time as you, so neither of you waits for the other.

  Which role first, and one at a time: start with the architect or the security guard. They exist to check work independently, and while you hold them you are reviewing your own plans. After that, pick the role whose work gains most from a different model or tools.

  How: offer to open the character builder in Control Center (`/control?create=1&cls=<class>`), set to the class that fits the role: Builder for the architect, security guard or janitor; Scribe for the historian or meeting scribe; Producer for triage, the meeting producer or the agents leader; Scout for the scientist. The `cls` value is the class name in lower case, such as `builder`. For the designer, let the owner pick. Once the agent exists, they use "Hand to a specialist" on that role's row in the roles panel. For an external agent, the role picker on the external-agent form works too, and it offers the roles you hold. Either way the role moves from you to them in one step. Neither the character builder nor native agent creation has a role field, so don't tell the owner to pick a role there.

  When: raise this yourself at most once; after that, explain it only when asked. A sensible moment is after you have been running here for about a week (the day count is under "Roles you hold"), and never in the middle of another task. Before you raise it, look through your direct conversation with the owner for an earlier explanation of yours; if you find one, wait to be asked. Whenever the owner asks what you can do, or asks about roles, explain it.
  """

  @doc "The heading of `roles_section/1`."
  @spec roles_marker() :: String.t()
  def roles_marker, do: @roles_marker

  @doc "The heading of `role_guidance/0`."
  @spec guidance_marker() :: String.t()
  def guidance_marker, do: @guidance_marker

  @doc """
  Why and how to split roles off to a specialist, for Burrow's instructions
  file. Generated at start (`start_blocks/1`), never stored.
  """
  @spec role_guidance() :: String.t()
  def role_guidance, do: @role_guidance

  @doc """
  The blocks `NativeAgents.start_files/1` adds to Burrow's instructions file
  through `Platform.Agents.Manners.ensure/2`, as `{marker, text}`: the roles
  section for `agent`, then the guidance. Read from the database on every
  call, never stored, so the stored file's version does not move.
  """
  @spec start_blocks(Agent.t()) :: [{String.t(), String.t()}]
  def start_blocks(%Agent{} = agent),
    do: [{@roles_marker, roles_section(agent)}, {@guidance_marker, @role_guidance}]

  @doc "`roles_section/1` for the Burrow agent, or \"\" when there is none."
  @spec roles_section() :: String.t()
  def roles_section do
    case get() do
      %Agent{} = agent -> roles_section(agent)
      nil -> ""
    end
  end

  @doc """
  The roles `agent` holds, each with its plain line (`Platform.Roles.plain_line/1`)
  and its size as kinds of work (the role's bundle), the roles other agents
  hold with that agent's name, and how many days `agent` has been on the
  install. A snapshot taken at start.
  """
  @spec roles_section(Agent.t()) :: String.t()
  def roles_section(%Agent{} = agent) do
    held = Roles.roles_for(agent.id)
    held_keys = MapSet.new(held, & &1.key)
    names = Map.new(Roles.list_roles(), &{&1.key, &1.name})

    held_lines =
      case held do
        [] -> ["- none"]
        roles -> Enum.map(roles, &held_line/1)
      end

    other_lines =
      case Enum.reject(Roles.assigned_agents(), &MapSet.member?(held_keys, &1.role_key)) do
        [] -> ["- none"]
        rows -> Enum.map(rows, &"- #{Map.get(names, &1.role_key, &1.role_key)}: #{&1.agent_name}")
      end

    """
    #{@roles_marker}

    You have been running on this install for #{days(agent)}.

    You hold:

    #{Enum.join(held_lines, "\n")}

    Held by other agents:

    #{Enum.join(other_lines, "\n")}
    """
  end

  defp held_line(role) do
    kinds =
      case length(Roles.bundle_for(role.key)) do
        1 -> "1 kind of work"
        n -> "#{n} kinds of work"
      end

    "- #{role.name}: #{Roles.plain_line(role.key)} (#{kinds})"
  end

  defp days(%Agent{inserted_at: %DateTime{} = at}) do
    case DateTime.diff(DateTime.utc_now(), at, :day) do
      1 -> "1 day"
      n -> "#{max(n, 0)} days"
    end
  end

  defp days(_agent), do: "0 days"

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
      You hold every role on this install that no other agent holds; see "Roles you hold" and "Splitting roles off" near the end of this file.

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
      """
  end
end
