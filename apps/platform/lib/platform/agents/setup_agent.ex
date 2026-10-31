defmodule Platform.Agents.SetupAgent do
  @moduledoc """
  The "Setup" native agent a new install's owner connects on
  `/setup/connect-ai` (`PlatformWeb.ConnectAiLive`, task 01a10315 stage 5),
  and the "Getting started" space it opens once it is connected.

  ## One agent, the harness the person picks

  `ensure/2` creates, or reuses, ONE native agent named "Setup" (slug
  `setup`) through `NativeAgents.create/2`, and starts it. The harness follows
  the option chosen: ChatGPT (Codex) runs `codex`, which logs in with Codex's
  own device login (`Platform.Agents.NativeLogin.login_view/1`); an API key and
  a Claude Pro or Max subscription run `claude_code`. Choosing a different
  option before the agent is connected switches the harness
  (`NativeAgents.set_harness/2`); once it is connected the agent is left alone.

  Burrow never relays a Claude login (task 01a17b10): nothing here takes a
  login code, and the Claude subscription path is a terminal step on the
  server (`os_user/1` names the account to log in as).

  ## After connect: "Getting started"

  `ensure_getting_started/2` runs on the first observation of the agent
  `running`, and is idempotent, keyed on the agent id:

    * the space's slug is `getting-started-<last 12 hex of the agent id>`, so
      a second call finds it, and a concurrent insert loses on the slug's
      unique index;
    * the admin and the agent are added once each;
    * the kickoff message is posted once: the call that flips the space's
      `metadata["setup_kickoff"]` from absent to set, in one UPDATE, is the
      only one that posts.
  """

  import Ecto.Query

  require Logger

  alias Platform.AgentHost
  alias Platform.Agents.{Agent, AgentRuntime, NativeAgents}
  alias Platform.Chat
  alias Platform.Chat.{Participant, Space}
  alias Platform.Repo
  alias Platform.Tenancy

  @name "Setup"
  @slug "setup"
  @space_name "Getting started"

  @doc "The agent's display name."
  def name, do: @name

  @doc "The Getting started space's display name."
  def space_name, do: @space_name

  @doc "The harness each connect option runs."
  @spec harness_for(atom()) :: String.t()
  def harness_for(:codex), do: "codex"
  def harness_for(:api_key), do: "claude_code"
  def harness_for(:claude_subscription), do: "claude_code"

  @doc "The Setup agent (a native agent with slug `setup`), or nil."
  @spec get() :: Agent.t() | nil
  def get do
    Enum.find_value(NativeAgents.list(), fn %{agent: a} -> a.slug == @slug && a end)
  end

  @doc "The Setup agent's runtime harness, or nil."
  @spec harness(Agent.t() | nil) :: String.t() | nil
  def harness(nil), do: nil

  def harness(%Agent{} = agent) do
    case NativeAgents.get_managed_runtime(agent) do
      %AgentRuntime{harness: harness} -> harness
      nil -> nil
    end
  end

  @doc "True when the Setup agent exists and the agent host reports it running."
  @spec connected?() :: boolean()
  def connected?, do: running?(get())

  @doc "True when `agent` is observed running."
  @spec running?(Agent.t() | nil) :: boolean()
  def running?(nil), do: false
  def running?(%Agent{} = agent), do: match?(%{state: :running}, AgentHost.status(agent))

  @doc """
  Create or reuse the Setup agent owned by `owner_id`, running `harness`, and
  start it. A Setup agent that is already running keeps its harness.
  Returns `{:ok, agent}` or `{:error, reason}`.
  """
  @spec ensure(binary(), String.t()) :: {:ok, Agent.t()} | {:error, term()}
  def ensure(owner_id, harness) when is_binary(owner_id) and harness in ~w(claude_code codex) do
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
          %Agent{} = agent -> ensure(owner_id, harness_or(agent, harness))
          nil -> {:error, reason}
        end
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

  @doc "The Getting started space's slug for `agent`."
  @spec space_slug(Agent.t()) :: String.t()
  def space_slug(%Agent{id: id}), do: "getting-started-" <> String.slice(id, -12, 12)

  @doc "The Getting started space for `agent`, or nil."
  @spec getting_started_space(Agent.t()) :: Space.t() | nil
  def getting_started_space(%Agent{} = agent), do: Repo.get_by(Space, slug: space_slug(agent))

  @doc """
  Create the "Getting started" space for `agent` with `user` (the admin) and
  the agent, and post the kickoff once. Idempotent; see the moduledoc.
  Returns `{:ok, space}` or `{:error, reason}`.
  """
  @spec ensure_getting_started(Agent.t(), %{id: binary()}) :: {:ok, Space.t()} | {:error, term()}
  def ensure_getting_started(%Agent{} = agent, %{id: user_id} = user) when is_binary(user_id) do
    with {:ok, space} <- ensure_space(agent),
         :ok <- ensure_participant(space, "user", user_id, display_name(user)),
         :ok <- ensure_participant(space, "agent", agent.id, agent.name),
         :ok <- maybe_kickoff(space, agent) do
      {:ok, space}
    end
  end

  defp display_name(user), do: Map.get(user, :name) || Map.get(user, :email) || "Owner"

  defp ensure_space(agent) do
    case getting_started_space(agent) do
      %Space{} = space ->
        {:ok, space}

      nil ->
        attrs = %{
          name: @space_name,
          slug: space_slug(agent),
          kind: "channel",
          org_id: root_org_id(),
          description: "Where #{agent.name} helps you finish setting up Burrow.",
          metadata: %{"setup_agent_id" => agent.id}
        }

        case Chat.create_space(attrs) do
          {:ok, space} ->
            {:ok, space}

          {:error, reason} ->
            case getting_started_space(agent) do
              %Space{} = space -> {:ok, space}
              nil -> {:error, reason}
            end
        end
    end
  end

  defp root_org_id do
    case Tenancy.get_root_org() do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp ensure_participant(space, type, id, display_name) do
    if Repo.exists?(
         from(p in Participant,
           where:
             p.space_id == ^space.id and p.participant_type == ^type and p.participant_id == ^id
         )
       ) do
      :ok
    else
      case Chat.add_participant(space.id, %{
             participant_type: type,
             participant_id: id,
             display_name: display_name,
             joined_at: DateTime.utc_now()
           }) do
        {:ok, _} -> :ok
        # A concurrent call added it first.
        {:error, %Ecto.Changeset{}} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # The one call whose UPDATE flips the claim posts; every other call sees 0 rows.
  defp maybe_kickoff(space, agent) do
    claim =
      from(s in Space,
        where: s.id == ^space.id and not fragment("? \\? 'setup_kickoff'", s.metadata),
        update: [
          set: [
            metadata:
              fragment(
                "COALESCE(?, '{}'::jsonb) || jsonb_build_object('setup_kickoff', ?::text)",
                s.metadata,
                ^agent.id
              )
          ]
        ]
      )

    case Repo.update_all(claim, []) do
      {1, _} -> post_kickoff(space, agent)
      {0, _} -> :ok
    end
  end

  defp post_kickoff(space, agent) do
    with {:ok, participant} <- system_participant(space),
         {:ok, _message} <-
           Chat.post_message(%{
             space_id: space.id,
             participant_id: participant.id,
             content_type: "text",
             content: kickoff_text(agent.name),
             metadata: %{"source" => "setup_kickoff", "setup_agent_id" => agent.id}
           }) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("[SetupAgent] kickoff not posted in space=#{space.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp system_participant(space) do
    id = Platform.UUID.deterministic("setup_kickoff:#{space.id}")

    case Repo.get_by(Participant,
           space_id: space.id,
           participant_type: "system",
           participant_id: id
         ) do
      %Participant{} = participant ->
        {:ok, participant}

      nil ->
        Chat.add_participant(space.id, %{
          participant_type: "system",
          participant_id: id,
          display_name: "Burrow",
          attention_mode: "mention",
          joined_at: DateTime.utc_now()
        })
    end
  end

  @doc "The kickoff message the space opens with."
  @spec kickoff_text(String.t()) :: String.t()
  def kickoff_text(name) do
    "@[#{name}] you're connected. Please walk the owner through finishing setup: " <>
      "which tools and accounts to connect (integrations), and creating a first space " <>
      "for their work. Keep it short and plain, one step at a time. When a step needs " <>
      "their consent, send them the link or button in Burrow and wait for them."
  end
end
