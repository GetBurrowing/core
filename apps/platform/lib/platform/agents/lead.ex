defmodule Platform.Agents.Lead do
  @moduledoc """
  The install's lead agent (task 01a1b6de): the agent that holds the
  existing `agents_leader` role, keeps everyone pointed at the install's
  goals and says what is in the way. No new role: `Platform.Agents.Burrow`
  pins `agents_leader` on every install (`Burrow.default_roles/0`), so the
  lead is Burrow unless the owner has given the role to another agent.

  ## The name, one config point

  `name/0` is what the owner reads as `{Lead}` (on `/setup/goals` today; on
  the heartbeat and inbox asks in later stages). It is

      config :platform, Platform.Agents.Lead, name: "..."

  when set, else the display name of the agent holding `agents_leader`,
  else `Burrow.name/0`. The default is the lead agent's own name, because
  the owner meets that agent on `/setup/connect-ai`; a role name chosen
  later goes in that one config key.

  ## Goals at setup

  `save_setup_goals/1` writes the owner's goals onto the space
  `AgentsGoalHeartbeat.agents_space/0` reads, or, when no space carries a
  goal yet, onto the default team channel (`DefaultSpace.team_channel/0`)
  with `leader_agent_id` set to the lead. Storage is `chat_spaces.goals`
  through `Sidebar.save_goals/3`, the same row the chat goal editor writes.
  """

  alias Platform.Agents.{Agent, Burrow}
  alias Platform.Chat.{DefaultSpace, Sidebar, Space}
  alias Platform.Repo
  alias Platform.Responsibilities.Handlers.AgentsGoalHeartbeat
  alias Platform.Roles

  import Ecto.Query

  @doc "What the owner reads as `{Lead}`; see the moduledoc."
  @spec name() :: String.t()
  def name do
    case Keyword.get(Application.get_env(:platform, __MODULE__, []), :name) do
      configured when is_binary(configured) and configured != "" ->
        configured

      _ ->
        case agent() do
          %Agent{name: agent_name} when is_binary(agent_name) and agent_name != "" -> agent_name
          _ -> Burrow.name()
        end
    end
  end

  @doc "The agent holding `agents_leader`, else the Burrow agent, else nil."
  @spec agent() :: Agent.t() | nil
  def agent do
    case Roles.agent_id_for_role(Sidebar.agents_leader_role()) do
      id when is_binary(id) ->
        Repo.one(from(a in Agent, where: a.id == ^id, limit: 1)) || Burrow.get()

      _ ->
        Burrow.get()
    end
  end

  @doc "The install's goals as stored (`[]` when none is set)."
  @spec goals() :: [String.t()]
  def goals do
    case AgentsGoalHeartbeat.agents_space() do
      %Space{goals: [_ | _] = goals} -> goals
      %Space{goal: goal} when is_binary(goal) and goal != "" -> [goal]
      _ -> []
    end
  end

  @doc """
  Save the owner's setup goals. Blank entries are dropped; with none left
  nothing is written and `{:ok, :skipped}` comes back. More than
  `Space.max_goals/0` is refused whole with `{:error, changeset}`.
  """
  @spec save_setup_goals([String.t()]) ::
          {:ok, Space.t()} | {:ok, :skipped} | {:error, term()}
  def save_setup_goals(goals) when is_list(goals) do
    if Enum.all?(goals, &(not is_binary(&1) or String.trim(&1) == "")) do
      {:ok, :skipped}
    else
      with {:ok, space} <- target_space() do
        leader_id = with %Agent{id: id} <- agent(), do: id
        Sidebar.save_goals(space, goals, leader_agent_id: leader_id)
      end
    end
  end

  defp target_space do
    case AgentsGoalHeartbeat.agents_space() do
      %Space{} = space -> {:ok, space}
      nil -> DefaultSpace.team_channel()
    end
  end
end
