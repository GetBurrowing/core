defmodule Platform.SuperAgents do
  @moduledoc """
  What the `doctor` and `relationship_steward` roles share: their escalation
  human, the one way to put a decision to that human, and the one way an
  operator switches either role on.

  Both roles are seeded UNASSIGNED (`Platform.Roles.Seeds`). Until an agent
  holds the role, the Responsibilities Router resolves no assignee and every
  fire is `{:ok, :unfilled}`: assignment is the enable signal.

  ## Where the escalation human lives

  `escalate_user_id` in the role's config row's `trigger_config`, stamped
  `"operator_set" => true` so the boot-time re-registration keeps it (the
  `Platform.Designer` / `Platform.Showrunner.Config` pattern). Ids are written
  at run time by `provision/3`, never committed.

  ## How a decision reaches the human

  `escalate/4` posts ONE message from the agent in its DM with the escalation
  human, and ONE `chat_mention` inbox row pointing at it. A question that
  already has an open (undismissed) row is not asked again, so a cron that
  sees the same fault every half hour asks once. With no escalation human
  configured there is nobody to ask: it logs and returns
  `{:skipped, :no_escalate_user}`. Never raises.

  ## Switching a role on

  `provision/3` is a plain function so it runs on a release node through
  `bin/platform rpc` (Mix is not in a release). It seeds the role if boot has
  not, assigns the agent (refusing a role held by someone else unless
  `reassign: true`), and writes the escalation human into the config row.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Inbox
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.Responsibility
  alias Platform.Roles
  alias Platform.Roles.Seeds

  @changed_topic "responsibilities:changed"

  @typedoc "The handler module whose `register/0` declares the role's config row."
  @type config_handler :: module()

  @doc """
  The escalation human on `key`'s row, or nil when unset or malformed. Accepts
  a key, a row or a `trigger_config` map. Never raises.
  """
  @spec escalate_user_id(String.t() | Responsibility.t() | map() | nil) :: String.t() | nil
  def escalate_user_id(key) when is_binary(key) do
    case Responsibilities.get_by_key(key) do
      %Responsibility{} = row -> escalate_user_id(row)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def escalate_user_id(%Responsibility{trigger_config: config}), do: escalate_user_id(config)

  def escalate_user_id(%{} = config) do
    case Map.get(config, "escalate_user_id") do
      id when is_binary(id) -> if Platform.UUID.valid?(id), do: id, else: nil
      _ -> nil
    end
  end

  def escalate_user_id(_), do: nil

  @doc """
  The DM between `agent_id` and `user_id` and the agent's participant in it:
  `{:ok, %{space_id, participant_id}}` or `{:error, reason}`.
  """
  @spec dm(String.t(), String.t()) ::
          {:ok, %{space_id: String.t(), participant_id: String.t()}} | {:error, term()}
  def dm(agent_id, user_id) when is_binary(agent_id) and is_binary(user_id) do
    with {:ok, dm} <- Chat.find_or_create_agent_dm(agent_id, user_id),
         %{id: participant_id} <- Chat.get_agent_participant(dm.id, agent_id) do
      {:ok, %{space_id: dm.id, participant_id: participant_id}}
    else
      nil -> {:error, :agent_not_in_dm}
      {:error, _} = error -> error
    end
  rescue
    error -> {:error, {:dm_failed, Exception.message(error)}}
  end

  def dm(_agent_id, _user_id), do: {:error, :missing_ids}

  @doc """
  Puts ONE decision to `user_id` on behalf of `agent_id`: a DM message and one
  inbox row titled `"<prefix><question>"`. `detail` is the message body under
  the question. Asked once while an open row for the same title exists.

  Returns `{:ok, :asked}`, `{:ok, :already_open}`, `{:skipped, reason}` or
  `{:error, reason}`. Never raises.
  """
  @spec escalate(String.t(), String.t() | nil, String.t(), keyword()) ::
          {:ok, :asked | :already_open} | {:skipped, atom()} | {:error, term()}
  def escalate(agent_id, user_id, question, opts \\ [])

  def escalate(_agent_id, nil, question, _opts) do
    Logger.warning("[super_agents] nobody to ask (no escalate_user_id): #{question}")
    {:skipped, :no_escalate_user}
  end

  def escalate(agent_id, user_id, question, opts)
      when is_binary(agent_id) and is_binary(user_id) and is_binary(question) do
    prefix = Keyword.get(opts, :prefix, "Needs you: ")
    title = String.slice(prefix <> question, 0, 250)

    if open?(user_id, title) do
      {:ok, :already_open}
    else
      with {:ok, %{space_id: space_id, participant_id: participant_id}} <- dm(agent_id, user_id),
           {:ok, message} <-
             Chat.post_message(%{
               space_id: space_id,
               participant_id: participant_id,
               content_type: "text",
               content: content(question, Keyword.get(opts, :detail)),
               metadata: %{
                 "source" => Keyword.get(opts, :source, "super_agent"),
                 "skip_mention_scan" => true
               }
             }),
           {:ok, _item} <- inbox(user_id, space_id, message, title) do
        {:ok, :asked}
      end
    end
  rescue
    error ->
      Logger.warning("[super_agents] escalation raised: #{Exception.message(error)}")
      {:error, :escalation_failed}
  end

  def escalate(_agent_id, _user_id, _question, _opts), do: {:error, :invalid_args}

  @doc "True when `user_id` has an open inbox row titled exactly `title`."
  @spec open?(String.t(), String.t()) :: boolean()
  def open?(user_id, title) when is_binary(user_id) and is_binary(title) do
    Repo.exists?(
      from(i in Platform.Inbox.Item,
        where: i.user_id == ^user_id and is_nil(i.dismissed_at) and i.title == ^title
      )
    )
  end

  def open?(_user_id, _title), do: false

  @doc """
  Switches `role` on for one agent. Idempotent.

  `config_handler` is the handler whose row carries the role's config.
  Attrs (map or keyword, atom or string keys):

    * `agent_id` (required) — the agent to hold the role;
    * `escalate_user_id` (required) — the one human decisions go to;
    * `reassign: true` — move the role from another agent; without it a role
      held by someone else is refused.

  Returns `{:ok, %{agent_id, role, escalate_user_id}}` or `{:error, reason}`.
  Writes nothing when a required id is missing or unknown.
  """
  @spec provision(String.t(), config_handler(), map() | keyword()) ::
          {:ok, map()} | {:error, term()}
  def provision(role, config_handler, attrs) when is_list(attrs),
    do: provision(role, config_handler, Map.new(attrs))

  def provision(role, config_handler, attrs)
      when is_binary(role) and is_atom(config_handler) and is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, agent} <- agent(attrs["agent_id"]),
         {:ok, user_id} <- user(attrs["escalate_user_id"]),
         :ok <- Seeds.seed_defaults(only_keys: [role]),
         {:ok, assignment} <- assign(role, agent, attrs["reassign"] == true),
         {:ok, _row} <- configure(config_handler, user_id) do
      Phoenix.PubSub.broadcast(Platform.PubSub, @changed_topic, {:responsibilities_changed, :all})
      {:ok, %{agent_id: agent.id, role: assignment, escalate_user_id: user_id}}
    end
  end

  def provision(_role, _config_handler, _attrs), do: {:error, :attrs_must_be_a_map}

  @doc """
  An external runtime's output as a string-keyed map: a map as given, or a
  JSON object in a string (a fenced ```json block is unwrapped). Anything
  else is `{:error, :not_an_object}`.
  """
  @spec decode(term()) :: {:ok, map()} | {:error, :not_an_object}
  def decode(output) when is_map(output) and not is_struct(output) do
    case output do
      %{"text" => text} when is_binary(text) and map_size(output) == 1 -> decode(text)
      _ -> {:ok, Map.new(output, fn {k, v} -> {to_string(k), v} end)}
    end
  end

  def decode(output) when is_binary(output) do
    text =
      case Regex.run(~r/```(?:json)?\s*(\{.*\})\s*```/s, output) do
        [_, json] -> json
        _ -> String.trim(output)
      end

    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> {:error, :not_an_object}
    end
  end

  def decode(_output), do: {:error, :not_an_object}

  # ── internals ──

  defp content(question, detail) when is_binary(detail) and detail != "",
    do: "Needs you: #{question}\n\n#{detail}"

  defp content(question, _detail), do: "Needs you: #{question}"

  defp inbox(user_id, space_id, message, title) do
    space = Chat.get_space(space_id)

    Inbox.emit(%{
      user_id: user_id,
      kind: "chat_mention",
      source_type: "chat_message",
      source_id: message.id,
      title: title,
      body: String.slice(message.content || "", 0, 200),
      url: space && "/chat/#{Chat.space_path_segment(space)}?message=#{message.id}"
    })
  end

  defp agent(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %Agent{} = agent <- Repo.get(Agent, id) do
      {:ok, agent}
    else
      _ -> {:error, {:not_found, :agent_id}}
    end
  end

  defp agent(_), do: {:error, {:missing, :agent_id}}

  defp user(id) when is_binary(id) do
    with true <- Platform.UUID.valid?(id),
         %{} <- Accounts.get_user(id) do
      {:ok, id}
    else
      _ -> {:error, {:not_found, :escalate_user_id}}
    end
  end

  defp user(_), do: {:error, {:missing, :escalate_user_id}}

  defp assign(role, agent, reassign?) do
    case Roles.agent_id_for_role(role) do
      id when id == agent.id ->
        {:ok, :unchanged}

      nil ->
        with {:ok, _} <- Roles.assign_role(role, agent.id), do: {:ok, :assigned}

      _other when reassign? ->
        :ok = Roles.unassign_role(role)
        with {:ok, _} <- Roles.assign_role(role, agent.id), do: {:ok, :reassigned}

      other ->
        {:error, {:role_held_by, other}}
    end
  end

  # Registers the config row if boot has not, then merges the escalation user
  # into its config. The declared `expression` is kept; `operator_set` makes
  # the boot re-registration keep it all.
  defp configure(config_handler, user_id) do
    [spec] = config_handler.register()

    row =
      case Responsibilities.get_by_key(spec.key) do
        %Responsibility{} = row -> {:ok, row}
        nil -> Responsibilities.upsert_by_key(spec)
      end

    with {:ok, row} <- row do
      config =
        (row.trigger_config || %{})
        |> Map.put("escalate_user_id", user_id)
        |> Map.put("operator_set", true)

      if config == row.trigger_config,
        do: {:ok, row},
        else: Responsibilities.update_responsibility(row, %{trigger_config: config})
    end
  end
end
