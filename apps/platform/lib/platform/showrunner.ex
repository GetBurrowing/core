defmodule Platform.Showrunner do
  @moduledoc """
  The How to Computer showrunner (task 01a1eaf6): a core role whose six
  responsibilities run the weekly loop, pitch -> research -> run sheet ->
  logistics -> record -> post -> retro, on one episode board per week.

  `provision/1` is the one way to switch it on for an install. Ids are given
  at run time (`mix platform.showrunner.provision`) and never committed.
  """

  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Providers.Showrunner, as: Provider
  alias Platform.Roles
  alias Platform.Roles.Seeds
  alias Platform.Showrunner.Config
  alias Platform.Showrunner.SocialBundle

  @role "showrunner"
  @changed_topic "responsibilities:changed"
  @social_warning "the showrunner's runtime has no effective `social` tools: post_show and " <>
                    "retro will park on a Needs-you item until the social tool bundle is added " <>
                    "to its runtime"

  @typedoc "What `provision/1` did and found."
  @type report :: %{
          agent_id: String.t(),
          role: :assigned | :unchanged | :reassigned,
          responsibilities: [%{key: String.t(), trigger_config: map()}],
          social_bundle: :present | {:absent, SocialBundle.absence()},
          warnings: [String.t()]
        }

  @doc "The role key."
  @spec role() :: String.t()
  def role, do: @role

  @doc "The six responsibility keys, in the weekly loop's order."
  @spec keys() :: [String.t()]
  def keys, do: Enum.map(Provider.handlers(), & &1.key())

  @doc """
  Switches the showrunner on for one agent and one show space. Idempotent.

  Attrs (map or keyword, atom or string keys): `agent_id`, `space_id`,
  `escalate_user_id` (required), `project_id` (required for the recording
  room) and `host_user_ids` (optional; the calendars a recording is proposed
  on). `reassign: true` moves the role from another agent; without it a role
  held by someone else is refused.

  It:

    * makes sure the `showrunner` role and its six-key bundle exist;
    * assigns the role to the agent (one agent per role);
    * makes the agent a participant of the space;
    * registers the six responsibility rows and writes their `trigger_config`
      ids through `Platform.Showrunner.Config.to_trigger/2`, which merges into
      the row's current config: an operator-set cadence (`expression`) is
      kept, never reset to the default;
    * reports whether the agent's runtime can reach the `social` tool
      bundle (`Platform.Showrunner.SocialBundle`), with a warning when not.

  Returns `{:ok, report}` or `{:error, reason}`.
  """
  @spec provision(map() | keyword()) :: {:ok, report()} | {:error, term()}
  def provision(attrs) when is_list(attrs), do: provision(Map.new(attrs))

  def provision(attrs) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, agent} <- agent(attrs["agent_id"]),
         {:ok, space_id} <- space(attrs["space_id"]),
         {:ok, ids} <- ids(attrs),
         :ok <- Seeds.seed_defaults(only_keys: [@role]),
         {:ok, role} <- assign(agent, attrs["reassign"] == true),
         :ok <- join(space_id, agent.id),
         {:ok, rows} <- configure(ids) do
      Phoenix.PubSub.broadcast(
        Platform.PubSub,
        @changed_topic,
        {:responsibilities_changed, :cron}
      )

      social = SocialBundle.status(agent)

      {:ok,
       %{
         agent_id: agent.id,
         role: role,
         responsibilities: Enum.map(rows, &%{key: &1.key, trigger_config: &1.trigger_config}),
         social_bundle: social,
         warnings: if(social == :present, do: [], else: [@social_warning])
       }}
    end
  end

  def provision(_attrs), do: {:error, :attrs_must_be_a_map}

  # ── internals ──

  defp agent(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Agent{} = agent <- Repo.get(Agent, id) do
      {:ok, agent}
    else
      _ -> {:error, {:not_found, :agent_id}}
    end
  end

  defp agent(_), do: {:error, {:missing, :agent_id}}

  defp space(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %{} <- Chat.get_space(id) do
      {:ok, id}
    else
      _ -> {:error, {:not_found, :space_id}}
    end
  end

  defp space(_), do: {:error, {:missing, :space_id}}

  defp ids(%{"escalate_user_id" => user_id} = attrs) when is_binary(user_id) do
    {:ok,
     attrs
     |> Map.take(~w(space_id project_id escalate_user_id host_user_ids))
     |> Map.reject(fn {_k, v} -> is_nil(v) end)}
  end

  defp ids(_attrs), do: {:error, {:missing, :escalate_user_id}}

  defp assign(agent, reassign?) do
    case Roles.agent_id_for_role(@role) do
      id when id == agent.id ->
        {:ok, :unchanged}

      nil ->
        with {:ok, _} <- Roles.assign_role(@role, agent.id), do: {:ok, :assigned}

      _other when reassign? ->
        :ok = Roles.unassign_role(@role)
        with {:ok, _} <- Roles.assign_role(@role, agent.id), do: {:ok, :reassigned}

      other ->
        {:error, {:role_held_by, other}}
    end
  end

  defp join(space_id, agent_id) do
    case Chat.get_agent_participant(space_id, agent_id) do
      %{} ->
        :ok

      nil ->
        case Chat.add_participant(space_id, %{
               participant_type: "agent",
               participant_id: agent_id,
               joined_at: DateTime.utc_now()
             }) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:join_failed, reason}}
        end
    end
  end

  defp configure(ids) do
    Provider.handlers()
    |> Enum.flat_map(& &1.register())
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, acc} ->
      with {:ok, row} <- Responsibilities.upsert_by_key(spec),
           {:ok, config} <- Config.to_trigger(row.trigger_config || %{}, ids),
           {:ok, row} <- Responsibilities.update_responsibility(row, %{trigger_config: config}) do
        {:cont, {:ok, acc ++ [row]}}
      else
        {:error, reason} -> {:halt, {:error, {spec.key, reason}}}
      end
    end)
  end
end
