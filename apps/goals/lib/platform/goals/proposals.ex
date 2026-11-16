defmodule Platform.Goals.Proposals do
  @moduledoc """
  How a goal comes to exist (task 01a1dfc1-7625, Goals 5/8): a person starts
  a New goal conversation with the install's lead agent, the agent records a
  PROPOSAL, and the person's own confirmation creates the goal.

  This module holds the implementation; `Platform.Goals` exposes each public
  function as a thin delegate that answers `{:error, :goals_disabled}` first
  while the switch is off. Nothing here checks the switch.

  Privacy is decided in `visible_proposals/1`: a user sees the rows addressed
  to them, an agent the rows it is having, anyone else nothing. Every read
  of a proposal starts from it, so a root admin, another member of the org
  and another agent get `{:error, :not_found}`, the same value as a missing
  or malformed id.

  Who may do what, of those who see a row:
    * the addressed person reads the conversation, writes in it, confirms
      and cancels; the row's agent gets `{:error, :forbidden}` for those;
    * only the row's agent records the proposal (`propose_goal/3`); the
      person gets `{:error, :forbidden}`.

  No function here lets an agent create a goal: `confirm_proposal/3` refuses
  agents and calls `Platform.Goals.create_goal/2` as the person.

  Signals to the agent go through `Platform.Goals.Signals.deliver/4` and
  carry identifiers only, never the person's words, a title or a setting.
  Every write broadcasts `{:goal_proposal_changed, id}` on
  `"goals:proposal:<id>"` (`Platform.PubSub`): the id only.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Goals
  alias Platform.Goals.{Clock, Goal, Limits, Proposal, Signals, Sources, Stop}
  alias Platform.Repo

  @goal_keys ~w(title why unit target_value source_key source_settings agent_mode rhythm
                rhythm_weekday outreach kind)
  @settings %{
    "stops" => "stops",
    "source_key" => "source",
    "agent_mode" => "agent_mode",
    "rhythm" => "rhythm",
    "outreach" => "outreach"
  }
  @stop_keys ~w(label target_value due_on caption theme criteria)a
  @conversation_limit 200

  # ── the read rule ─────────────────────────────────────────────────────────

  @doc "An Ecto query of exactly the proposals `actor` sees."
  @spec visible_proposals(term()) :: Ecto.Query.t()
  def visible_proposals(%User{id: id}) when is_binary(id),
    do: from(p in Proposal, where: p.user_id == ^id)

  def visible_proposals(%Agent{id: id}) when is_binary(id),
    do: from(p in Proposal, where: p.agent_id == ^id)

  def visible_proposals(_actor), do: from(p in Proposal, where: false)

  # ── reads ─────────────────────────────────────────────────────────────────

  @doc "The holder of the `agents_leader` role."
  def lead_agent(%User{id: id}) when is_binary(id), do: resolve_lead()
  def lead_agent(_actor), do: {:error, :not_found}

  @doc "The user's open, unexpired proposal, or nil."
  def current_proposal(%User{id: id} = user) when is_binary(id) do
    {:ok, Repo.one(from(p in live(user), order_by: [desc: p.inserted_at], limit: 1))}
  end

  def current_proposal(_actor), do: {:ok, nil}

  @doc "A proposal the actor sees (any status)."
  def get_proposal(actor, proposal_id) do
    with {:ok, id} <- cast_id(proposal_id) do
      case Repo.one(from(p in visible_proposals(actor), where: p.id == ^id, preload: [:user])) do
        %Proposal{} = proposal -> {:ok, proposal}
        nil -> {:error, :not_found}
      end
    end
  end

  @doc "The actor's open, unexpired proposals, oldest first."
  def list_proposals(actor) do
    {:ok, Repo.all(from(p in live(actor), order_by: [asc: p.inserted_at, asc: p.id]))}
  end

  @doc """
  The opening message and the top-level messages after it in the DM, oldest
  first, at most #{@conversation_limit}; the person's and the agent's
  messages only (core's system notices are left out). The addressed user
  only.
  """
  def conversation(actor, proposal_id) do
    with {:ok, proposal} <- addressed(actor, proposal_id) do
      space_id = proposal.space_id

      first =
        case Chat.get_message(proposal.first_message_id) do
          %{space_id: ^space_id, deleted_at: nil} = msg -> [msg]
          _ -> []
        end

      rest =
        Chat.list_messages(proposal.space_id,
          after_id: proposal.first_message_id,
          order: :asc,
          top_level_only: true,
          limit: @conversation_limit - length(first)
        )

      # Only the person's and the agent's words: core's system notices (a
      # reply-failure line, authored by the space's system participant) are
      # not the agent speaking.
      {:ok, for(msg <- first ++ rest, said?(msg), do: message_view(msg))}
    end
  end

  defp said?(msg),
    do: msg.author_participant_type in ["user", "agent"] and msg.content_type != "system"

  defp message_view(msg) do
    %{
      id: msg.id,
      from: if(msg.author_participant_type == "user", do: :person, else: :agent),
      content: msg.content,
      at: msg.inserted_at
    }
  end

  # ── the person's writes ───────────────────────────────────────────────────

  @doc """
  Starts a New goal conversation with the lead agent: posts `text` as the
  person in their DM and records an open proposal. The agent is never named
  by the caller.
  """
  def start_goal_conversation(%User{id: user_id} = user, text) when is_binary(user_id) do
    with {:ok, text} <- message_text(text) do
      now = Clock.now()

      result =
        tx(fn ->
          expire_stale(user, now)

          with :ok <- no_open_proposal(user),
               {:ok, agent} <- resolve_lead(),
               {:ok, org_id} <- pick_org(user),
               {:ok, space} <- Chat.find_or_create_dm(user_id, "agent", agent.id),
               {:ok, msg} <- post_as_person(space.id, user_id, text),
               {:ok, proposal} <- insert_proposal(user, agent, org_id, space, msg, now) do
            {:ok, {proposal, agent}}
          end
        end)

      with {:ok, {proposal, agent}} <- result do
        prompt =
          "A person started a New goal conversation with you. Conversation id: #{proposal.id}. " <>
            "Read it with goal_proposal_get, talk with them in your direct conversation, and " <>
            "record what you settle with goal_propose. Nothing is created until they press Create goal."

        {:ok, store_delivery(proposal, Signals.deliver(agent, "goals.new_goal", prompt, event()))}
      end
    end
  end

  def start_goal_conversation(_actor, _text), do: {:error, :not_found}

  @doc "Posts the person's message in the conversation's DM (status open or confirmed)."
  def say_in_conversation(actor, proposal_id, text) do
    with {:ok, proposal} <- addressed(actor, proposal_id),
         :ok <- check_sayable(proposal),
         {:ok, text} <- message_text(text),
         {:ok, msg} <- post_as_person(proposal.space_id, actor.id, text) do
      broadcast(proposal.id)
      {:ok, msg}
    end
  end

  @doc """
  The person confirms the proposal at `revision`, the revision their screen
  last showed. Creates the goal AS THE PERSON, with the proposal's agent as
  coach and kind personal, in one transaction; at most one goal per proposal.
  """
  def confirm_proposal(actor, proposal_id, revision) do
    with {:ok, proposal} <- addressed(actor, proposal_id) do
      result =
        tx(fn ->
          with {:ok, row} <- lock_live(proposal.id),
               :ok <- check_ready(row),
               :ok <- check_revision(row, revision),
               :ok <- claim(row, revision),
               {:ok, goal} <- Goals.create_goal(actor, goal_attrs(row)),
               {:ok, _stops} <- maybe_put_stops(actor, goal, row.draft["stops"]) do
            row
            |> Ecto.Changeset.change(
              status: "confirmed",
              confirmed_at: Clock.now(),
              goal_id: goal.id
            )
            |> Repo.update()
            |> case do
              {:ok, row} -> {:ok, %{goal: goal, proposal: row}}
              error -> error
            end
          end
        end)

      with {:ok, %{goal: goal, proposal: row}} <- result do
        prompt =
          "The person confirmed the goal from conversation #{row.id}. Goal id: #{goal.id}. " <>
            "You are its coach. Tell them in your direct conversation that you are researching, " <>
            "then record each finding with goal_takeaway_add. A finding needs at least one source."

        delivery = Signals.deliver(load_agent(row.agent_id), "goals.research", prompt, event())
        {:ok, %{goal: goal, proposal: store_delivery(row, delivery)}}
      end
    end
  end

  @doc "The person cancels their open proposal."
  def cancel_proposal(actor, proposal_id) do
    with {:ok, proposal} <- addressed(actor, proposal_id) do
      tx(fn ->
        with {:ok, row} <- lock_live(proposal.id) do
          row |> Ecto.Changeset.change(status: "cancelled") |> Repo.update()
        end
      end)
      |> tap(&broadcast_ok/1)
    end
  end

  @doc "Subscribes the caller to `{:goal_proposal_changed, id}` for a proposal it sees."
  def subscribe_proposal(actor, proposal_id) do
    with {:ok, proposal} <- get_proposal(actor, proposal_id) do
      Phoenix.PubSub.subscribe(Platform.PubSub, topic(proposal.id))
    end
  end

  # ── the agent's write ─────────────────────────────────────────────────────

  @doc """
  Records what the agent and the person settled. Only the agent the
  conversation is with, while it is open. Absent keys are left alone.
  """
  def propose_goal(actor, proposal_id, attrs) when is_map(attrs) do
    with {:ok, proposal} <- get_proposal(actor, proposal_id),
         :ok <- check_proposer(actor, proposal) do
      tx(fn ->
        with {:ok, row} <- lock_live(proposal.id),
             attrs = stringify(attrs),
             :ok <- check_source(attrs),
             {:ok, goal_draft} <- validate_goal_fields(row, attrs),
             {:ok, stops} <- validate_stops(attrs),
             {:ok, replies} <- validate_replies(row, attrs),
             {:ok, ready} <- validate_ready_flag(row, attrs) do
          draft = row.draft |> Map.merge(goal_draft) |> Map.merge(stops)

          with :ok <- check_complete(ready, draft) do
            row
            |> Ecto.Changeset.change(
              draft: draft,
              replies: replies,
              settled: settle(row.settled, attrs),
              ready: ready,
              revision: row.revision + 1
            )
            |> Repo.update()
          end
        end
      end)
      |> tap(&broadcast_ok/1)
    end
  end

  def propose_goal(_actor, _proposal_id, _attrs), do: {:error, :not_found}

  # ── internals ─────────────────────────────────────────────────────────────

  defp resolve_lead do
    with id when is_binary(id) <-
           Platform.Roles.agent_id_for_role(Chat.Sidebar.agents_leader_role()),
         %Agent{} = agent <- load_agent(id) do
      {:ok, agent}
    else
      _ -> {:error, :no_lead_agent}
    end
  end

  defp load_agent(id), do: Repo.one(from(a in Agent, where: a.id == ^id))

  defp live(actor) do
    now = Clock.now()
    from(p in visible_proposals(actor), where: p.status == "open" and p.expires_at > ^now)
  end

  # The addressed person only; the row's agent sees it but may not act here.
  defp addressed(actor, proposal_id) do
    with {:ok, %Proposal{user_id: user_id} = proposal} <- get_proposal(actor, proposal_id) do
      case actor do
        %User{id: ^user_id} -> {:ok, proposal}
        _ -> {:error, :forbidden}
      end
    end
  end

  defp check_proposer(%Agent{id: id}, %Proposal{agent_id: id}), do: :ok
  defp check_proposer(_actor, _proposal), do: {:error, :forbidden}

  defp check_sayable(%Proposal{status: "confirmed"}), do: :ok

  defp check_sayable(%Proposal{status: "open", expires_at: expires_at}) do
    if DateTime.compare(expires_at, Clock.now()) == :gt,
      do: :ok,
      else: {:error, :proposal_closed}
  end

  defp check_sayable(_proposal), do: {:error, :proposal_closed}

  defp lock_live(id) do
    now = Clock.now()

    case Repo.one(from(p in Proposal, where: p.id == ^id, lock: "FOR UPDATE")) do
      %Proposal{status: "open"} = row ->
        if DateTime.compare(row.expires_at, now) == :gt,
          do: {:ok, row},
          else: {:error, :proposal_closed}

      _ ->
        {:error, :proposal_closed}
    end
  end

  defp check_ready(%Proposal{ready: true}), do: :ok
  defp check_ready(_row), do: {:error, :proposal_not_ready}

  defp check_revision(%Proposal{revision: revision}, revision) when is_integer(revision), do: :ok
  defp check_revision(_row, _revision), do: {:error, :proposal_changed}

  defp claim(row, revision) do
    {count, _} =
      Repo.update_all(
        from(p in Proposal,
          where: p.id == ^row.id and p.status == "open" and p.revision == ^revision
        ),
        set: [status: "confirmed", confirmed_at: Clock.now()]
      )

    if count == 1, do: :ok, else: {:error, :proposal_closed}
  end

  defp goal_attrs(row) do
    row.draft
    |> Map.take(@goal_keys)
    |> Map.merge(%{
      "org_id" => row.org_id,
      "coach_agent_id" => row.agent_id,
      "kind" => "personal"
    })
  end

  defp maybe_put_stops(actor, goal, [_ | _] = stops), do: Goals.put_stops(actor, goal.id, stops)
  defp maybe_put_stops(_actor, _goal, _stops), do: {:ok, []}

  defp message_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    length = String.length(trimmed)

    if length >= 1 and length <= Limits.max_opening_chars(),
      do: {:ok, trimmed},
      else: {:error, :text_required}
  end

  defp message_text(_text), do: {:error, :text_required}

  defp post_as_person(space_id, user_id, text) do
    with {:ok, participant} <- Chat.SpaceAccess.authorize_writer(space_id, {:user, user_id}) do
      Chat.post_message(%{
        space_id: space_id,
        participant_id: participant.id,
        content_type: "text",
        content: text
      })
    end
  end

  defp expire_stale(%User{id: id}, now) do
    Repo.update_all(
      from(p in Proposal,
        where: p.user_id == ^id and p.status == "open" and p.expires_at <= ^now
      ),
      set: [status: "expired", updated_at: now]
    )
  end

  defp no_open_proposal(%User{id: id}) do
    if Repo.exists?(from(p in Proposal, where: p.user_id == ^id and p.status == "open")),
      do: {:error, :conversation_open},
      else: :ok
  end

  # A non-external membership in a non-archived org; a tenant-tier org before
  # the root org, earliest membership first.
  defp pick_org(user) do
    user
    |> Platform.Tenancy.list_user_memberships()
    |> Enum.filter(&(&1.external == false and match?(%{archived_at: nil}, &1.org)))
    |> Enum.sort(&earlier_choice?/2)
    |> case do
      [membership | _] -> {:ok, membership.org_id}
      [] -> {:error, :no_org}
    end
  end

  defp earlier_choice?(a, b) do
    rank_a = tier_rank(a.org)
    rank_b = tier_rank(b.org)

    if rank_a == rank_b,
      do: compare_time(a.inserted_at, b.inserted_at) != :gt,
      else: rank_a < rank_b
  end

  defp tier_rank(org), do: if(Platform.Tenancy.tier(org) == :tenant, do: 0, else: 1)

  defp compare_time(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  defp compare_time(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)
  defp compare_time(_a, _b), do: :eq

  defp insert_proposal(user, agent, org_id, space, msg, now) do
    expires_at = DateTime.add(now, Limits.proposal_expiry_days() * 86_400, :second)

    %Proposal{user_id: user.id, agent_id: agent.id, org_id: org_id, space_id: space.id}
    |> Proposal.changeset(%{first_message_id: msg.id, expires_at: expires_at})
    |> Repo.insert()
    |> case do
      {:ok, proposal} ->
        {:ok, proposal}

      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :user_id),
          do: {:error, :conversation_open},
          else: {:error, changeset}
    end
  end

  defp store_delivery(proposal, delivery) do
    {:ok, proposal} = proposal |> Ecto.Changeset.change(delivery: delivery) |> Repo.update()
    broadcast(proposal.id)
    proposal
  end

  defp event, do: [trigger_kind: "event_topic"]

  defp stringify(attrs), do: Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

  defp check_source(%{"source_key" => key}) when not is_nil(key) do
    case Sources.fetch(key) do
      {:ok, _} -> :ok
      :error -> {:error, :unknown_source}
    end
  end

  defp check_source(_attrs), do: :ok

  # Member 1's Goal changeset is the one list of allowed values. Only the
  # keys this call gives are judged, so a partial draft is not refused for
  # what is still to be settled.
  defp validate_goal_fields(row, attrs) do
    given = Map.take(attrs, @goal_keys)
    merged = row.draft |> Map.take(@goal_keys) |> Map.merge(given)

    changeset =
      Goal.changeset(%Goal{org_id: row.org_id, owner_user_id: row.user_id}, merged)

    errors =
      Enum.filter(changeset.errors, fn {field, _} -> to_string(field) in Map.keys(given) end)

    if errors == [] do
      {:ok,
       Map.new(given, fn {key, _} ->
         {key, json_value(Ecto.Changeset.get_field(changeset, String.to_existing_atom(key)))}
       end)}
    else
      {:error, %{changeset | errors: errors, valid?: false}}
    end
  end

  defp validate_stops(%{"stops" => stops}) when is_list(stops) do
    if length(stops) > Limits.max_stops() do
      {:error, proposal_error(:stops, "at most #{Limits.max_stops()} stops")}
    else
      stops
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, []}, fn {attrs, position}, {:ok, acc} ->
        case validate_stop(attrs, position) do
          {:ok, stop} -> {:cont, {:ok, [stop | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, stops} -> {:ok, %{"stops" => Enum.reverse(stops)}}
        error -> error
      end
    end
  end

  defp validate_stops(%{"stops" => _}), do: {:error, proposal_error(:stops, "must be a list")}
  defp validate_stops(_attrs), do: {:ok, %{}}

  # Member 1's Stop changeset judges each stop; `goal_id` does not exist yet.
  defp validate_stop(attrs, position) when is_map(attrs) do
    changeset = Stop.changeset(%Stop{position: position}, stringify(attrs))
    errors = Keyword.delete(changeset.errors, :goal_id)

    if errors == [] do
      {:ok,
       Map.new(@stop_keys, fn key ->
         {Atom.to_string(key), json_value(Ecto.Changeset.get_field(changeset, key))}
       end)}
    else
      {:error, %{changeset | errors: errors, valid?: false}}
    end
  end

  defp validate_stop(_attrs, _position),
    do: {:error, proposal_error(:stops, "each stop must be a map")}

  defp validate_replies(_row, %{"replies" => replies}) when is_list(replies) do
    max = Limits.max_reply_chars()

    trimmed =
      Enum.map(replies, fn
        reply when is_binary(reply) -> String.trim(reply)
        _ -> nil
      end)

    cond do
      length(trimmed) > Limits.max_quick_replies() ->
        {:error, proposal_error(:replies, "at most #{Limits.max_quick_replies()} replies")}

      Enum.all?(trimmed, &(is_binary(&1) and String.length(&1) in 1..max)) ->
        {:ok, trimmed}

      true ->
        {:error, proposal_error(:replies, "each reply is 1 to #{max} characters")}
    end
  end

  defp validate_replies(_row, %{"replies" => _}),
    do: {:error, proposal_error(:replies, "must be a list")}

  defp validate_replies(row, _attrs), do: {:ok, row.replies}

  defp validate_ready_flag(_row, %{"ready" => ready}) when is_boolean(ready), do: {:ok, ready}

  defp validate_ready_flag(_row, %{"ready" => _}),
    do: {:error, proposal_error(:ready, "must be true or false")}

  defp validate_ready_flag(row, _attrs), do: {:ok, row.ready}

  defp check_complete(false, _draft), do: :ok

  defp check_complete(true, draft) do
    if missing_for_ready(draft) == [], do: :ok, else: {:error, :proposal_incomplete}
  end

  @doc """
  The draft keys a ready proposal still lacks: title, agent_mode, rhythm,
  outreach, and rhythm_weekday for a weekly or biweekly rhythm. The one copy
  of the rule; `goal_propose` names them in its refusal.
  """
  @spec missing_for_ready(map()) :: [String.t()]
  def missing_for_ready(draft) when is_map(draft) do
    needed =
      ~w(title agent_mode rhythm outreach) ++
        if(draft["rhythm"] in ~w(weekly biweekly), do: ["rhythm_weekday"], else: [])

    Enum.reject(needed, &present?(draft[&1]))
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)

  defp settle(settled, attrs) do
    stamp = DateTime.to_iso8601(Clock.now())

    Enum.reduce(@settings, settled, fn {key, setting}, acc ->
      if Map.has_key?(attrs, key), do: Map.put_new(acc, setting, stamp), else: acc
    end)
  end

  defp proposal_error(field, message) do
    %Proposal{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
  end

  defp json_value(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_value(value), do: value

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp topic(id), do: "goals:proposal:#{id}"

  defp broadcast(id),
    do: Phoenix.PubSub.broadcast(Platform.PubSub, topic(id), {:goal_proposal_changed, id})

  defp broadcast_ok({:ok, %Proposal{id: id}}), do: broadcast(id)
  defp broadcast_ok(_result), do: :ok

  defp tx(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:ok, value} -> value
             {:error, reason} -> Repo.rollback(reason)
           end
         end) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end
end
