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
  alias Platform.Showrunner.Board
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
        {:responsibilities_changed, :all}
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

  @doc """
  Answers a Needs-you item on an episode board: the click on one of
  `Platform.Chat.Canvas.Kinds.NeedsYou`'s option buttons, whose action value
  is `"<item id>:<option>"`.

  Only the show's producer answers: the configured `escalate_user_id`, or one
  of its `host_user_ids`. The topic pick goes through
  `ShowrunnerResearchBrief.pick_topic/3` (title, rail to Research, the brief
  fired); any other item is resolved with the option. Either way the item's
  open inbox row is dismissed. The board is written as the assigned agent.

  `{:ok, canvas}`, or `{:error, reason}`: `:not_a_board`, `:bad_value`,
  `:not_producer`, `{:unknown_needs_you, id}`, `{:invalid_choice, id, option}`
  and anything the board read or write refuses. `opts[:fire]` is passed to
  the topic pick. Never raises.
  """
  @spec answer(Platform.Chat.Canvas.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, Platform.Chat.Canvas.t()} | {:error, term()}
  def answer(canvas, value, user_id, opts \\ [])

  def answer(%Platform.Chat.Canvas{} = canvas, value, user_id, opts) when is_binary(value) do
    with true <- Board.board?(canvas) || {:error, :not_a_board},
         [item_id, option] when item_id != "" and option != "" <-
           String.split(value, ":", parts: 2),
         {:ok, ctx, config} <- context_for(canvas.space_id),
         true <- producer?(config, user_id) || {:error, :not_producer},
         {:ok, episode, document} <- Board.read(canvas),
         %{} = item <-
           Enum.find(episode.needs_you, &(&1.id == item_id)) ||
             {:error, {:unknown_needs_you, item_id}},
         {:ok, canvas} <- resolve(ctx, canvas, document, episode, item, option, opts) do
      Board.clear_escalation(ctx, item.question)
      {:ok, canvas}
    else
      [_ | _] -> {:error, :bad_value}
      {:error, _} = error -> error
      other -> {:error, other}
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  end

  def answer(_canvas, _value, _user_id, _opts), do: {:error, :bad_value}

  defp resolve(ctx, canvas, document, episode, item, option, opts) do
    if item.id == Platform.Responsibilities.Handlers.ShowrunnerWeeklyPitch.pick_id() do
      if option in item.options,
        do:
          Platform.Responsibilities.Handlers.ShowrunnerResearchBrief.pick_topic(
            canvas,
            option,
            opts
          ),
        else: {:error, {:invalid_choice, item.id, option}}
    else
      with {:ok, episode} <-
             Platform.Showrunner.Episode.resolve_needs_you(episode, item.id, option) do
        Board.write(ctx, canvas, document, episode)
      end
    end
  end

  # The acting context of the showrunner row configured for this space.
  defp context_for(space_id) do
    keys()
    |> Enum.map(&Responsibilities.get_by_key/1)
    |> Enum.find(&(&1 && Config.read(&1).space_id == space_id))
    |> case do
      nil -> {:error, :no_space_configured}
      row -> Platform.Showrunner.Runtime.context(row)
    end
  end

  defp producer?(_config, nil), do: false

  defp producer?(config, user_id),
    do: user_id == config.escalate_user_id or user_id in (config.host_user_ids || [])

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
