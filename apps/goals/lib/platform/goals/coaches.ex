defmodule Platform.Goals.Coaches do
  @moduledoc """
  Who may coach a person's goal (task 01a1eab7 stage 1).

  ONE predicate. An agent is an eligible coach for `user` when it is
  `status == "active"` and `accepts_chat == true`, it has an external
  runtime whose effective tools include the Goals lead tools (the public
  `Platform.Goals.Proposals.check_lead_tools/1`, task 01a1eab6, not a second
  bundle check), and the user may talk to it
  (`Platform.Chat.external_dm_permitted?/3`, the gate core's
  `find_or_create_dm/4` enforces).

  An agent with no external runtime holds no tools at all, so it is not
  offered: `check_lead_tools/1` answers `:ok` for it only to keep the
  lead-agent start's older `"no_runtime"` delivery path, which a picked
  coach does not take.

  `list_eligible/1`, `eligible?/2` and `fetch_eligible/2` all read through
  `eligible_agents/2`, so the list a screen shows and the check a write
  makes cannot drift. Every refusal is `{:error, :lead_missing_goals_tools}`,
  the atom 01a1eab6's start uses for a lead without the tools, whatever
  the reason (unknown id, malformed id, inactive, no bundle, not
  permitted), so the answer cannot be used to probe for agents.

  Reads go through core's public functions only (`Platform.Chat`,
  `Platform.Roles`, `Platform.Agents.ColorPalette`); this module holds no
  query of core's schema.
  """

  alias Platform.Accounts.User
  alias Platform.Agents.{Agent, ColorPalette}
  alias Platform.Chat
  alias Platform.Goals.Proposals

  @refusal {:error, :lead_missing_goals_tools}

  @type coach :: %{
          id: binary(),
          name: String.t() | nil,
          slot: String.t(),
          avatar_url: String.t() | nil,
          model_label: String.t() | nil,
          role_label: String.t() | nil
        }

  @doc "The agents `user` may pick as a coach, ordered by name then id."
  @spec list_eligible(term()) :: [coach()]
  def list_eligible(%User{id: id} = user) when is_binary(id),
    do: user |> eligible_agents(nil) |> Enum.map(&view/1)

  def list_eligible(_actor), do: []

  @doc "Whether `agent_or_id` passes exactly the predicate `list_eligible/1` lists by."
  @spec eligible?(term(), term()) :: boolean()
  def eligible?(user, agent_or_id), do: match?({:ok, _}, fetch_eligible(user, agent_or_id))

  @doc """
  The eligible agent named by `agent_or_id`, re-read from core (a passed
  struct's fields are never trusted), or the one refusal.
  """
  @spec fetch_eligible(term(), term()) :: {:ok, Agent.t()} | {:error, :lead_missing_goals_tools}
  def fetch_eligible(user, %Agent{id: id}), do: fetch_eligible(user, id)

  def fetch_eligible(%User{id: user_id} = user, id) when is_binary(user_id) and is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         [%Agent{} = agent] <- eligible_agents(user, id) do
      {:ok, agent}
    else
      _ -> @refusal
    end
  end

  def fetch_eligible(_user, _agent_or_id), do: @refusal

  @doc """
  The coach a picker preselects: the `agents_leader` holder when it is in
  `eligible`, else the first of `eligible`, else nil.
  """
  @spec default_id(term(), [coach()]) :: binary() | nil
  def default_id(_user, eligible) when is_list(eligible) do
    leader = Platform.Roles.agent_id_for_role(Chat.Sidebar.agents_leader_role())

    cond do
      is_binary(leader) and Enum.any?(eligible, &(&1.id == leader)) -> leader
      match?([_ | _], eligible) -> hd(eligible).id
      true -> nil
    end
  end

  # ── the predicate ─────────────────────────────────────────────────────────

  # `only` narrows the candidates to one id BEFORE the runtime check (so a
  # single check costs one runtime read); the predicate is the same.
  defp eligible_agents(%User{id: user_id}, only) do
    Chat.list_agents_for_picker()
    |> Enum.filter(&(is_nil(only) or &1.id == only))
    |> Enum.filter(&candidate?(&1, user_id))
    |> Enum.filter(&holds_goals_tools?/1)
    |> Enum.sort_by(&{&1.name || "", &1.id})
  end

  defp candidate?(%Agent{} = agent, user_id) do
    agent.status == "active" and agent.accepts_chat == true and
      Chat.external_dm_permitted?(user_id, "agent", agent.id)
  end

  defp holds_goals_tools?(%Agent{runtime_type: "external", runtime_id: runtime_id} = agent)
       when is_binary(runtime_id),
       do: Proposals.check_lead_tools(agent) == :ok

  defp holds_goals_tools?(_agent), do: false

  # ── the view ──────────────────────────────────────────────────────────────

  defp view(%Agent{} = agent) do
    %{
      id: agent.id,
      name: agent.name,
      slot: ColorPalette.slot_for(agent.color),
      avatar_url: agent.avatar_url,
      model_label: model_label(agent),
      role_label: role_label(agent)
    }
  end

  # The first role the agent holds, ordered by key (`Platform.Roles.roles_for/1`).
  defp role_label(%Agent{id: id}) do
    case Platform.Roles.roles_for(id) do
      [role | _] -> role.name
      [] -> nil
    end
  end

  @families [
    {"opus", "Opus"},
    {"sonnet", "Sonnet"},
    {"haiku", "Haiku"},
    {"claude", "Claude"},
    {"gpt", "GPT"},
    {"llama", "Llama"},
    {"gemini", "Gemini"},
    {"mistral", "Mistral"},
    {"qwen", "Qwen"}
  ]

  @doc false
  @spec model_label(Agent.t()) :: String.t() | nil
  def model_label(%Agent{} = agent) do
    case model_name(agent) do
      nil ->
        nil

      model ->
        down = String.downcase(model)

        Enum.find_value(@families, fn {needle, label} ->
          if String.contains?(down, needle), do: label
        end)
    end
  end

  defp model_name(%Agent{model: model}) when is_binary(model) and model != "", do: model

  defp model_name(%Agent{model_config: %{"primary" => primary}})
       when is_binary(primary) and primary != "",
       do: primary

  defp model_name(_agent), do: nil
end
