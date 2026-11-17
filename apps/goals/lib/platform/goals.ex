defmodule Platform.Goals do
  @moduledoc """
  The Goals module's public context (ADR 0055 build-time module, task
  01a1dfc0).

  Every function except `enabled?/0` takes the ACTOR first, a
  `%Platform.Accounts.User{}` or a `%Platform.Agents.Agent{}` (anything else
  sees nothing), and answers `{:error, :goals_disabled}` before touching the
  database while `GOALS_ENABLED` is off. The actor is never read from attrs.

  Privacy is decided in the query (`Platform.Goals.Visibility`): a goal the
  actor cannot see and a goal that does not exist both answer
  `{:error, :not_found}`. A user without the `goals.use` permission sees no
  goal (`Visibility.may_use?/1`, read on every call), and the functions that
  act without loading a goal (`create_goal/2`, `list_sources/1` and the
  proposal functions) answer `{:error, :forbidden}` for them. Of those who can see a goal, the owner and the
  coach agent may change its settings and status, only the owner may open
  or close it, and everyone else only reads.

  A goal with kind "personal" has no grant at any instant: opening a
  personal goal makes it "shared" in the same transaction as the grant, and
  going back to "personal" is refused while any grant exists.
  """

  import Ecto.Query

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat.Participant
  alias Platform.Goals.{Entry, Goal, GoalTasks, Grant, Reading, Sources, Stop, Visibility}
  alias Platform.Repo
  alias Platform.Tenancy.OrgMembership

  @type actor :: User.t() | Agent.t() | term()
  @type audience :: {:user, binary()} | {:team, binary()} | {:space, binary()}

  @doc """
  Whether this install switched Goals on (`GOALS_ENABLED`, read at boot by
  `Platform.Goals.RuntimeConfig`). False until the application has started,
  and false whenever the variable is unset.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:goals, :enabled, false) == true

  @doc """
  Creates a goal owned by `user` in `attrs.org_id`, an org the user reads.
  Agents cannot create goals (`{:error, :not_found}`).
  """
  @spec create_goal(actor(), map()) :: {:ok, Goal.t()} | {:error, term()}
  def create_goal(actor, attrs) when is_map(attrs) do
    with :ok <- check_enabled(), :ok <- check_use(actor) do
      do_create_goal(actor, attrs)
    end
  end

  defp do_create_goal(%User{id: user_id} = user, attrs) when is_binary(user_id) do
    with {:ok, org_id} <- org_id_from(attrs),
         :ok <- check_org_visible(user, org_id) do
      %Goal{owner_user_id: user_id, org_id: org_id}
      |> Goal.changeset(attrs)
      |> Repo.insert()
    end
  end

  defp do_create_goal(_actor, _attrs), do: {:error, :not_found}

  defp org_id_from(attrs) do
    case Ecto.UUID.cast(Map.get(attrs, :org_id) || Map.get(attrs, "org_id")) do
      {:ok, org_id} -> {:ok, org_id}
      :error -> {:error, :org_not_visible}
    end
  end

  defp check_org_visible(user, org_id) do
    case Platform.Tenancy.visibility(user) do
      :root_all -> :ok
      {:orgs, ids} -> if org_id in ids, do: :ok, else: {:error, :org_not_visible}
      _ -> {:error, :org_not_visible}
    end
  end

  @doc "Exactly the goals `actor` sees, newest first."
  @spec list_goals(actor()) :: {:ok, [Goal.t()]} | {:error, :goals_disabled}
  def list_goals(actor) do
    with :ok <- check_enabled() do
      goals =
        actor
        |> Visibility.visible_goals()
        |> order_by([g], desc: g.inserted_at, desc: g.id)
        |> Repo.all()

      {:ok, goals}
    end
  end

  @doc """
  The goal `goal_id` if `actor` sees it. Unseen, missing and malformed ids
  all answer `{:error, :not_found}`.
  """
  @spec get_goal(actor(), term()) :: {:ok, Goal.t()} | {:error, :not_found | :goals_disabled}
  def get_goal(actor, goal_id) do
    with :ok <- check_enabled() do
      fetch_visible(actor, goal_id, false)
    end
  end

  @doc """
  Changes a goal's settings or status: the owner or the coach agent only.
  `coach_agent_id` is the owner's to change; `owner_user_id` and `org_id`
  never change. Back to kind "personal" is refused while any grant exists.
  """
  @spec update_goal(actor(), term(), map()) :: {:ok, Goal.t()} | {:error, term()}
  def update_goal(actor, goal_id, attrs) when is_map(attrs) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, visible_goal} <- fetch_visible(actor, goal_id, false),
             :ok <- lock_clock(actor, visible_goal),
             {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal),
             changeset = Goal.changeset(goal, editable_attrs(actor, goal, attrs)),
             :ok <- check_kind_change(changeset, goal) do
          with {:ok, updated} <- Repo.update(changeset) do
            Platform.Goals.Clock.sync(goal, updated, Platform.Goals.Clock.now())
            {:ok, updated}
          end
        end
      end)
    end
  end

  # The coach may not reassign the coach: only the owner casts it.
  defp editable_attrs(actor, goal, attrs) do
    if owner?(actor, goal), do: attrs, else: Map.drop(attrs, [:coach_agent_id, "coach_agent_id"])
  end

  defp check_kind_change(changeset, goal) do
    if Ecto.Changeset.get_change(changeset, :kind) == "personal" and has_grants?(goal),
      do: {:error, :has_audience},
      else: :ok
  end

  @doc """
  Opens a goal to an audience: `{:user, user_id}`, `{:team, org_id}` or
  `{:space, space_id}`. Owner only, idempotent. A personal goal becomes
  "shared" in the same transaction. The owner may open to any other existing
  user, to an org they hold a non-external membership in, and to a space
  they participate in; anything else is `{:error, :audience_not_available}`.
  """
  @spec open_goal(actor(), term(), audience()) :: {:ok, Goal.t()} | {:error, term()}
  def open_goal(actor, goal_id, audience) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_owner(actor, goal),
             {:ok, {type, column, id}} <- available_audience(goal, audience) do
          insert_grant(actor, goal, type, column, id)
        end
      end)
    end
  end

  # Runs inside open_goal/3's transaction, after the goal row is locked, so
  # two opens of one goal serialise and "personal" never has a grant.
  defp insert_grant(actor, goal, type, column, id) do
    grant_exists? =
      Repo.exists?(
        from(gr in Grant,
          where:
            gr.goal_id == ^goal.id and gr.audience_type == ^type and field(gr, ^column) == ^id
        )
      )

    with {:ok, goal} <- share(goal),
         {:ok, _grant} <- maybe_insert(grant_exists?, actor, goal, type, column, id) do
      {:ok, goal}
    end
  end

  defp share(%Goal{kind: "personal"} = goal),
    do: goal |> Ecto.Changeset.change(kind: "shared") |> Repo.update()

  defp share(goal), do: {:ok, goal}

  defp maybe_insert(true, _actor, _goal, _type, _column, _id), do: {:ok, :already_open}

  defp maybe_insert(false, actor, goal, type, column, id),
    do: actor |> grant_changeset(goal, type, column, id) |> Repo.insert()

  defp grant_changeset(actor, goal, type, column, id) do
    %Grant{goal_id: goal.id, granted_by_user_id: actor.id}
    |> Grant.changeset(%{:audience_type => type, column => id})
  end

  @doc """
  Closes one audience: deletes that grant. Owner only. Closing an audience
  that was not open answers `{:ok, goal}` unchanged; closing the last one
  leaves the goal "shared".
  """
  @spec close_goal(actor(), term(), audience()) :: {:ok, Goal.t()} | {:error, term()}
  def close_goal(actor, goal_id, audience) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_owner(actor, goal),
             {:ok, {type, column}} <- audience_column(audience) do
          case Ecto.UUID.cast(elem(audience, 1)) do
            {:ok, id} ->
              Repo.delete_all(
                from(gr in Grant,
                  where:
                    gr.goal_id == ^goal.id and gr.audience_type == ^type and
                      field(gr, ^column) == ^id
                )
              )

            :error ->
              :ok
          end

          {:ok, goal}
        end
      end)
    end
  end

  @doc """
  The goal's grants, oldest first: for the owner and the coach agent only;
  other viewers get `{:error, :forbidden}`.
  """
  @spec list_audience(actor(), term()) :: {:ok, [Grant.t()]} | {:error, term()}
  def list_audience(actor, goal_id) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false),
         :ok <- check_can_edit(actor, goal) do
      grants =
        Repo.all(
          from(gr in Grant,
            join: g in subquery(Visibility.visible_goals(actor)),
            on: g.id == gr.goal_id,
            where: gr.goal_id == ^goal.id,
            order_by: [asc: gr.inserted_at, asc: gr.id]
          )
        )

      {:ok, grants}
    end
  end

  @doc "Replaces the ordered journey atomically. Positions come from list order."
  def put_stops(actor, goal_id, stops) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal) do
          Repo.delete_all(from(s in Stop, where: s.goal_id == ^goal.id))

          result =
            stops
            |> Enum.with_index(1)
            |> Enum.reduce_while({:ok, []}, fn {attrs, position}, {:ok, acc} ->
              changeset =
                Stop.changeset(%Stop{goal_id: goal.id, position: position}, stop_attrs(attrs))

              case Repo.insert(changeset) do
                {:ok, stop} -> {:cont, {:ok, [stop | acc]}}
                {:error, changeset} -> {:halt, {:error, changeset}}
              end
            end)

          case result do
            {:ok, stops} -> {:ok, Enum.reverse(stops)}
            error -> error
          end
        end
      end)
    end
  end

  @doc "Changes an existing stop belonging to this visible goal."
  def update_stop(actor, goal_id, stop_id, attrs) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal),
             {:ok, id} <- cast_id(stop_id),
             %Stop{} = stop <-
               Repo.one(from(s in children(actor, Stop, goal.id), where: s.id == ^id)) do
          stop |> Stop.changeset(stop_attrs(attrs)) |> Repo.update()
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  @doc "Lists stops by position for anyone who sees the goal."
  def list_stops(actor, goal_id) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      {:ok, Repo.all(from(s in children(actor, Stop, goal.id), order_by: s.position))}
    end
  end

  @doc "Appends a notebook entry, with its author taken from the actor."
  def add_entry(actor, goal_id, attrs) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal),
             :ok <- Platform.Goals.Takeaways.check_cap(actor, goal, attrs) do
          actor
          |> authored_entry(goal)
          |> Entry.changeset(attrs)
          |> validate_entry_link(actor, goal, :takeaway_id, Entry)
          |> validate_entry_link(actor, goal, :stop_id, Stop)
          |> validate_entry_link(actor, goal, :reading_id, Reading)
          |> Repo.insert()
        end
      end)
    end
  end

  @doc "Lists newest notebook entries, optionally filtered by kind (limit 50, maximum 200)."
  def list_entries(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      query = children(actor, Entry, goal.id)

      query =
        case Keyword.get(opts, :kind) do
          nil -> query
          kinds -> from(e in query, where: e.kind in ^List.wrap(kinds))
        end

      limit = opts |> Keyword.get(:limit, 50) |> max(0) |> min(200)

      {:ok,
       Repo.all(from(e in query, order_by: [desc: e.occurred_at, desc: e.id], limit: ^limit))}
    end
  end

  @doc "Logs a manual or practice value for a logged source; owner and coach only."
  def log_reading(actor, goal_id, attrs) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal),
             {:ok, source} <- logged_source(goal),
             {:ok, population} <- source_call(fn -> source.population(goal) end, :population) do
          attrs = reading_attrs(attrs)

          authored_reading(actor, goal, population)
          |> Reading.changeset(attrs)
          |> Ecto.Changeset.validate_required([:origin, :details])
          |> Ecto.Changeset.validate_inclusion(:origin, ~w(manual practice))
          |> Repo.insert()
        else
          {:cannot_measure, _} -> {:error, :source_not_logged}
          error -> error
        end
      end)
    end
  end

  @doc "Measures and stores a fresh number, or reads a logged source; owner and coach only."
  def measure_goal(actor, goal_id) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal) do
          with_source(goal, fn source, description, population ->
            case description.kind do
              :logged -> number_result(actor, goal, description, population, [])
              :measured -> measure_reading(actor, goal, source, description, population)
            end
          end)
        end
      end)
    end
  end

  @doc "Extends Goals 2/8: the same reader includes first and accepts as_of to bound every reading by measured_at."
  def goal_number(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      with_source(goal, fn _source, description, population ->
        number_result(actor, goal, description, population, opts)
      end)
    end
  end

  @doc "Reads the hoped-for line using the shared number reader; never writes."
  def expected_pace(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      Platform.Goals.Retro.expected_pace(actor, goal, opts)
    end
  end

  @doc "Reads history across populations, newest first (default 50, maximum 200)."
  def list_readings(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      limit = opts |> Keyword.get(:limit, 50) |> max(0) |> min(200)
      {:ok, Repo.all(from(r in ordered_readings(actor, goal), limit: ^limit))}
    end
  end

  @doc "Describes registered sources while Goals is enabled."
  def list_sources(actor) do
    with :ok <- check_enabled(), :ok <- check_use(actor), do: {:ok, Sources.describe()}
  end

  # Goals 5/8 (task 01a1dfc1-7625): the New goal conversation. Thin delegates;
  # the rules live in `Platform.Goals.Proposals`.
  @doc "The install's lead agent (holder of `agents_leader`)."
  def lead_agent(user), do: proposals(:lead_agent, [user])

  @doc """
  Starts a New goal conversation with the lead agent. Answers
  `{:error, :lead_missing_goals_tools}`, writing nothing, when the lead's
  runtime lacks the Goals tools (`Platform.Goals.Proposals.check_lead_tools/1`).
  """
  def start_goal_conversation(user, text), do: proposals(:start_goal_conversation, [user, text])
  def current_proposal(user), do: proposals(:current_proposal, [user])
  def get_proposal(actor, id), do: proposals(:get_proposal, [actor, id])
  def list_proposals(actor), do: proposals(:list_proposals, [actor])
  def conversation(user, id), do: proposals(:conversation, [user, id])
  def say_in_conversation(user, id, text), do: proposals(:say_in_conversation, [user, id, text])
  @doc "The conversation's agent records the proposal; it creates nothing."
  def propose_goal(agent, id, attrs), do: proposals(:propose_goal, [agent, id, attrs])
  @doc "The person's own confirmation: creates the goal as the person."
  def confirm_proposal(user, id, rev), do: proposals(:confirm_proposal, [user, id, rev])
  def cancel_proposal(user, id), do: proposals(:cancel_proposal, [user, id])
  def subscribe_proposal(user, id), do: proposals(:subscribe_proposal, [user, id])

  @doc """
  Operator command (task 01a1eab6 stage 4): re-sends `goals.new_goal` for an
  open proposal after `20261117220000_move_goal_proposals_out_of_dms` moved
  it into its own space. No actor; see
  `Platform.Goals.Proposals.resend_start_signal/1` for the release-eval
  command and the errors, including `{:error, :lead_missing_goals_tools}`.
  """
  def resend_start_signal(proposal_id) do
    with :ok <- check_enabled(), do: Platform.Goals.Proposals.resend_start_signal(proposal_id)
  end

  # A proposal is not a goal, so `visible_goals/1` does not gate it: the
  # actor (the first argument) is checked here (task 01a1e229).
  defp proposals(fun, [actor | _] = args),
    do:
      with(
        :ok <- check_enabled(),
        :ok <- check_use(actor),
        do: apply(Platform.Goals.Proposals, fun, args)
      )

  @doc "Lists visible wake-ups; private briefing is restricted to owner and coach."
  def list_wake_ups(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      query = children(actor, Platform.Goals.WakeUp, goal.id)

      query =
        Enum.reduce([:kind, :status], query, fn key, q ->
          case Keyword.get(opts, key) do
            nil -> q
            value -> from(w in q, where: field(w, ^key) == ^value)
          end
        end)

      limit = opts |> Keyword.get(:limit, 20) |> max(0) |> min(100)
      rows = Repo.all(from(w in query, order_by: [desc: w.due_at, desc: w.id], limit: ^limit))

      {:ok,
       if(owner?(actor, goal) or coach?(actor, goal),
         do: rows,
         else: Enum.map(rows, &%{&1 | briefing: %{}})
       )}
    end
  end

  @doc "Reads a private wake-up briefing as its owner or coach."
  def get_wake_up(actor, wake_up_id) do
    with :ok <- check_enabled(),
         {:ok, id} <- cast_id(wake_up_id),
         %Platform.Goals.WakeUp{} = wake <-
           Repo.one(from(w in Platform.Goals.Clock.visible_wakes(actor), where: w.id == ^id)),
         {:ok, goal} <- fetch_visible(actor, wake.goal_id, false),
         :ok <- check_can_edit(actor, goal) do
      {:ok,
       %{
         wake_up: wake,
         briefing: wake.briefing,
         text: Platform.Goals.WakeUps.Briefing.text(wake.briefing)
       }}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  @doc "Reads the visible goal's clock."
  def clock_status(actor, goal_id) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      row = Platform.Goals.Clock.visible_clock(actor, goal.id)

      {:ok,
       if(row,
         do:
           row
           |> Map.take([
             :next_wake_at,
             :time_zone,
             :wake_hour,
             :last_woken_at,
             :stalled_at,
             :paced_at
           ])
           |> Map.put(
             :paced_every,
             if(row.paced_at, do: Platform.Goals.Limits.paced_every(goal.rhythm), else: nil)
           ),
         else: nil
       )}
    end
  end

  @doc "Restarts a stalled clock at the next regular slot."
  def restart_clock(actor, goal_id) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, visible_goal} <- fetch_visible(actor, goal_id, false),
             :ok <- lock_clock(actor, visible_goal),
             {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal) do
          case Platform.Goals.Clock.visible_clock(actor, goal.id) do
            nil -> {:ok, nil}
            clock -> Platform.Goals.Clock.reset(clock, goal, Platform.Goals.Clock.now())
          end
        end
      end)
    end
  end

  @doc "Closes a check-in atomically as its coach, recording exactly one outcome."
  def close_wake_up(actor, wake_up_id, outcome, attrs) do
    with :ok <- check_enabled() do
      result =
        in_transaction(fn ->
          with {:ok, _wake, goal} <- editable_wake(actor, wake_up_id),
               :ok <- lock_clock(actor, goal),
               {:ok, wake, goal} <- editable_wake(actor, wake_up_id),
               :ok <- check_open(wake),
               :ok <- check_wake_kind(wake, "check_in"),
               :ok <- known_outcome(outcome),
               :ok <- outcome_allowed(goal, outcome, attrs),
               :ok <- prediction_required(outcome, attrs),
               {:ok, entry_attrs} <- outcome_entry(outcome, attrs, wake),
               {:ok, ask} <- maybe_ask(actor, goal, wake, outcome, attrs),
               {:ok, tasks} <- maybe_tasks(actor, goal, outcome, attrs),
               entry_attrs = link_entry_attrs(entry_attrs, ask, tasks),
               {:ok, entry} <- add_entry(actor, goal.id, entry_attrs),
               :ok <- attach_outcome(actor, goal, wake, entry, ask, tasks),
               {:ok, closed} <- claim_close(wake, outcome, entry) do
            {:ok,
             %{
               wake_up: closed,
               entry: entry,
               ask: ask && %{ask | entry_id: entry.id},
               task: List.first(tasks),
               tasks: tasks
             }}
          end
        end)

      with {:ok, %{wake_up: wake, entry: entry, tasks: tasks}} <- result do
        Enum.each(tasks, &Platform.Tasks.maybe_start_planning_on_create/1)
        Platform.Goals.SpaceUpdates.publish(actor, wake.goal_id, wake, entry, tasks)
      end

      result
    end
  end

  @doc "Closes a retro using its stored verdicts and the existing wake-up claim."
  def close_retro(actor, wake_up_id, attrs) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, _wake, goal} <- editable_wake(actor, wake_up_id),
             :ok <- lock_clock(actor, goal),
             {:ok, wake, goal} <- editable_wake(actor, wake_up_id),
             :ok <- check_open(wake),
             :ok <- check_wake_kind(wake, "retro"),
             {:ok, entry_attrs} <-
               Platform.Goals.RetroChanges.entry_attrs(actor, goal, wake, attrs),
             {:ok, entry} <- add_entry(actor, goal.id, entry_attrs),
             {:ok, closed} <- claim_close(wake, "retro", entry) do
          {:ok, %{wake_up: closed, entry: entry}}
        end
      end)
    end
  end

  @doc "The owner accepts or keeps a retro's proposed change, once."
  def decide_retro_change(actor, goal_id, entry_id, decision) do
    with :ok <- check_enabled() do
      result =
        in_transaction(fn ->
          with {:ok, goal} <- fetch_visible(actor, goal_id, false),
               :ok <- lock_clock(actor, goal),
               {:ok, goal} <- fetch_visible(actor, goal_id, true),
               true <- owner?(actor, goal) || {:error, :forbidden},
               true <- decision in ["switch", "keep"] || {:error, :unknown_decision},
               {:ok, retro} <- Platform.Goals.RetroChanges.retro(actor, goal.id, entry_id),
               {kind, change} when not is_nil(change) <-
                 Platform.Goals.RetroChanges.proposal(retro),
               nil <- Platform.Goals.RetroChanges.decision(actor, goal.id, retro.id),
               {:ok, updated} <- apply_retro_decision(actor, goal, change["set"], decision),
               {:ok, entry} <-
                 add_entry(actor, goal.id, %{
                   kind: "ask",
                   occurred_at: Platform.Goals.Clock.now(),
                   title:
                     if(decision == "switch", do: "Switched: ", else: "Kept as is: ") <>
                       String.slice(change["summary"], 0, 190),
                   details: %{
                     "request" => "retro_change",
                     "decision" => decision,
                     "retro_entry_id" => retro.id,
                     "change" => kind,
                     "set" => change["set"],
                     "from" => Platform.Goals.RetroChanges.before_values(goal, change["set"])
                   }
                 }) do
            {:ok, %{decision: decision, goal: updated, entry: entry}}
          else
            {_, nil} -> {:error, :nothing_to_decide}
            %Entry{} -> {:error, :already_decided}
            error -> error
          end
        end)

      if match?({:ok, _}, result), do: refresh_brief(actor, {:entry, entry_id})
      result
    end
  end

  defp apply_retro_decision(actor, goal, set, "switch"), do: update_goal(actor, goal.id, set)
  defp apply_retro_decision(_actor, goal, _set, "keep"), do: {:ok, goal}

  @doc "Reads a retro and the owner's pending or recorded decision."
  def get_retro(actor, goal_id, entry_id) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      Platform.Goals.RetroChanges.describe(actor, goal, entry_id)
    end
  end

  @doc "Lists retro notebook entries, newest first."
  def list_retros(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      limit = opts |> Keyword.get(:limit, 20) |> max(0) |> min(100)

      {:ok,
       Repo.all(
         from(e in children(actor, Entry, goal.id),
           where: e.kind == "retro",
           order_by: [desc: e.occurred_at, desc: e.id],
           limit: ^limit,
           select: %{
             entry_id: e.id,
             title: e.title,
             occurred_at: e.occurred_at,
             stop_id: e.stop_id
           }
         )
       )}
    end
  end

  @doc "Derives action states from retro entries alone."
  def prediction_states(actor, goal_id) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      Platform.Goals.RetroChanges.states(actor, goal.id)
    end
  end

  defp check_wake_kind(%{kind: kind}, kind), do: :ok
  defp check_wake_kind(_, "retro"), do: {:error, :not_a_retro}
  defp check_wake_kind(_, "check_in"), do: {:error, :retro_wake_up}

  @doc "Lists the asks the actor may read, with their answer signals."
  def list_asks(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      q = children(actor, Platform.Goals.Ask, goal.id)
      q = if owner?(actor, goal) or coach?(actor, goal), do: q, else: addressed(q, actor)

      q =
        case Keyword.get(opts, :status) do
          nil -> q
          status -> from(a in q, where: a.status == ^status)
        end

      limit = opts |> Keyword.get(:limit, 50) |> max(0) |> min(200)

      {:ok,
       Repo.all(
         from(a in q,
           order_by: [desc: a.inserted_at, desc: a.id],
           limit: ^limit,
           preload: [:answers]
         )
       )}
    end
  end

  @doc """
  Returns visible, addressed, unanswered asks (default 50, maximum 200).
  The optional goal_id filter is applied before the limit, for the goal page's
  Up next card. The :infinity limit is reserved for daily brief preparation.
  """
  def list_my_asks(actor, opts \\ []) do
    with :ok <- check_enabled() do
      case actor do
        %User{id: id} ->
          now = Platform.Goals.Clock.now()

          limit =
            case Keyword.get(opts, :limit, 50) do
              :infinity -> nil
              value -> value |> max(0) |> min(200)
            end

          q =
            from(a in Platform.Goals.Ask,
              join: g in subquery(Visibility.visible_goals(actor)),
              on: g.id == a.goal_id,
              left_join: answer in Platform.Goals.AskAnswer,
              on: answer.ask_id == a.id and answer.user_id == ^id,
              where:
                ^id in a.addressed_user_ids and a.status == "open" and a.expires_at > ^now and
                  is_nil(answer.id),
              order_by: [desc: a.inserted_at, desc: a.id],
              preload: [:answers]
            )

          q =
            case Keyword.fetch(opts, :goal_id) do
              :error ->
                q

              {:ok, raw_id} ->
                case Ecto.UUID.cast(raw_id) do
                  {:ok, goal_id} -> from(a in q, where: a.goal_id == ^goal_id)
                  _ -> from(a in q, where: false)
                end
            end

          q = if is_nil(limit), do: q, else: from(a in q, limit: ^limit)
          {:ok, Repo.all(q)}

        _ ->
          {:ok, []}
      end
    end
  end

  @doc "Records an addressed user's answer; ignored may become a final answer once."
  def answer_ask(actor, ask_id, answer, details \\ %{}) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with %User{id: user_id} <- actor,
             {:ok, id} <- cast_id(ask_id),
             %Platform.Goals.Ask{} = ask <-
               Repo.one(
                 from(a in Platform.Goals.Ask,
                   join: g in subquery(Visibility.visible_goals(actor)),
                   on: g.id == a.goal_id,
                   where: a.id == ^id and ^user_id in a.addressed_user_ids
                 )
               ),
             {:ok, goal} <- fetch_visible(actor, ask.goal_id, false),
             :ok <- lock_clock(actor, goal),
             ask =
               Repo.one(
                 from(a in children(actor, Platform.Goals.Ask, goal.id),
                   where: a.id == ^id,
                   lock: "FOR UPDATE OF g0"
                 )
               ),
             old =
               Repo.one(
                 from(a in Platform.Goals.AskAnswer,
                   where: a.ask_id == ^ask.id and a.user_id == ^user_id
                 )
               ),
             :ok <- final_answer_check(old, answer),
             {:ok, _} <-
               Platform.Goals.AskAnswer.changeset(
                 old || %Platform.Goals.AskAnswer{ask_id: ask.id, user_id: user_id},
                 %{answer: answer, details: details, answered_at: Platform.Goals.Clock.now()}
               )
               |> Repo.insert_or_update() do
          if goal.owner_user_id == user_id and answer in ["used", "declined"],
            do: Platform.Goals.OwnerPace.refresh(goal, Platform.Goals.Clock.now())

          count =
            Repo.aggregate(
              from(a in Platform.Goals.AskAnswer, where: a.ask_id == ^ask.id),
              :count
            )

          if count == length(ask.addressed_user_ids) do
            ask
            |> Ecto.Changeset.change(status: "closed", closed_at: Platform.Goals.Clock.now())
            |> Repo.update()
          else
            {:ok, ask}
          end
        else
          nil -> {:error, :not_found}
          %Agent{} -> {:error, :not_found}
          {:error, _} = error -> error
          _ -> {:error, :not_found}
        end
      end)
    end
  end

  @doc "Prepares the reader's daily goal items, once per addressed ask and report window."
  def prepare_brief(actor, date),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.prepare(actor, date))

  def brief_items(actor, date),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.items(actor, date))

  @doc "Returns the date this reader received an addressed ask, or nil before delivery."
  def ask_brief_date(actor, ask_id),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.ask_brief_date(actor, ask_id))

  def brief_summary(actor, date),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.summary(actor, date))

  def set_report_noted(actor, id, noted?),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.set_noted(actor, id, noted?))

  @doc """
  Records one immutable Undo request for an action. Later Keep/Resume preferences
  append linked signals; repeating the current preference writes nothing. The
  coach receives the full history, and the action itself is never changed.
  """
  def request_undo(actor, goal_id, entry_id, request \\ "undo"),
    do:
      with(
        :ok <- check_enabled(),
        do: Platform.Goals.Brief.request_undo(actor, goal_id, entry_id, request)
      )

  def ask_coach(actor, goal_id, text, opts \\ []),
    do:
      with(:ok <- check_enabled(), do: Platform.Goals.Brief.ask_coach(actor, goal_id, text, opts))

  @doc "Withdraws a final offer/question answer before the coach sees it, extending the original final-answer rule."
  def withdraw_answer(actor, ask_id),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.withdraw_answer(actor, ask_id))

  def record_practice(actor, ask_id, results),
    do:
      with(
        :ok <- check_enabled(),
        do: Platform.Goals.Brief.record_practice(actor, ask_id, results)
      )

  def practice_streak(actor, goal_id, opts \\ []),
    do:
      with(:ok <- check_enabled(), do: Platform.Goals.Brief.practice_streak(actor, goal_id, opts))

  def get_ask(actor, ask_id),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.get_ask(actor, ask_id))

  def refresh_brief(actor, ask_id),
    do: with(:ok <- check_enabled(), do: Platform.Goals.Brief.refresh(actor, ask_id))

  @doc "Lists the core tasks tagged to a visible goal."
  def list_goal_tasks(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(), {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      closed = Platform.Goals.Sources.TaskCount.closed_statuses()
      limit = opts |> Keyword.get(:limit, 50) |> max(0) |> min(200)

      {:ok,
       Repo.all(
         from(l in children(actor, Platform.Goals.TaskLink, goal.id),
           join: t in Platform.Tasks.Task,
           on: t.id == l.task_id,
           order_by: [desc: l.inserted_at, desc: l.id],
           limit: ^limit,
           select: %{
             task_id: t.id,
             title: t.title,
             status: t.status,
             open: is_nil(t.deleted_at) and t.status not in ^closed,
             wake_up_id: l.wake_up_id,
             linked_at: l.inserted_at,
             phase_assignees: t.phase_assignees,
             assignee_id: t.assignee_id,
             assignee_type: t.assignee_type
           }
         )
       )
       |> GoalTasks.annotate()}
    end
  end

  @doc "Tags an existing core task as the goal's coach, enforcing mode and caps."
  def link_task(actor, goal_id, task_id, attrs \\ %{}) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- fetch_visible(actor, goal_id, false),
             :ok <- check_coach(actor, goal),
             :ok <- lock_clock(actor, goal),
             {:ok, goal} <- fetch_visible(actor, goal_id, false),
             :ok <- check_coach(actor, goal),
             :ok <- task_mode(goal),
             :ok <- GoalTasks.check_cap(actor, goal, 1),
             {:ok, id} <- project_task_id(task_id),
             %Platform.Tasks.Task{} = task <-
               Repo.one(from(t in Platform.Tasks.Task, where: t.id == ^id)),
             {:ok, _} <- GoalTasks.available_project(actor, goal, task.project_id),
             :ok <- GoalTasks.check_assignee(actor, goal, task),
             :ok <- unlinked(task.id) do
          insert_task_link(
            actor,
            goal,
            task,
            field_attr(attrs, :wake_up_id),
            field_attr(attrs, :entry_id)
          )
        else
          nil -> {:error, :project_not_available}
          error -> error
        end
      end)
    end
  end

  defp editable_wake(actor, raw_id) do
    with {:ok, id} <- cast_id(raw_id),
         %Platform.Goals.WakeUp{} = wake <-
           Repo.one(from(w in Platform.Goals.Clock.visible_wakes(actor), where: w.id == ^id)),
         {:ok, goal} <- fetch_visible(actor, wake.goal_id, false),
         :ok <- check_coach(actor, goal) do
      {:ok, wake, goal}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp check_coach(actor, goal), do: if(coach?(actor, goal), do: :ok, else: {:error, :forbidden})

  defp lock_clock(actor, goal) do
    Repo.one(
      from(c in children(actor, Platform.Goals.GoalClock, goal.id), lock: "FOR UPDATE OF g0")
    )

    # A freshly created goal may not have been ticked yet. Locking the goal
    # also serializes that case and coordinates add_entry/update_goal writers.
    fetch_visible(actor, goal.id, true)
    :ok
  end

  defp check_open(%{status: "open"}), do: :ok
  defp check_open(_), do: {:error, :wake_up_closed}
  defp known_outcome(outcome) when outcome in ~w(do ask wait), do: :ok
  defp known_outcome(_), do: {:error, :unknown_outcome}
  defp field_attr(attrs, key), do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key)))
  defp nonblank?(s), do: is_binary(s) and String.trim(s) != ""
  defp outcome_allowed(%{agent_mode: "advise"}, "do", _), do: {:error, :mode_forbids_do}

  defp outcome_allowed(goal, "do", attrs) do
    if field_attr(attrs, :task) in [nil, []], do: :ok, else: task_mode(goal)
  end

  defp outcome_allowed(%{outreach: "off"}, "ask", _), do: {:error, :outreach_off}
  defp outcome_allowed(_, _, _), do: :ok
  defp task_mode(%{agent_mode: "advise"}), do: {:error, :mode_forbids_do}
  defp task_mode(%{agent_mode: "coach"}), do: {:error, :mode_forbids_task}
  defp task_mode(_), do: :ok
  defp prediction_required("wait", _), do: :ok

  defp prediction_required(_, attrs) do
    date = parse_date(field_attr(attrs, :predicted_by))

    if nonblank?(field_attr(attrs, :prediction)) and match?(%Date{}, date) and
         Date.compare(date, DateTime.to_date(Platform.Goals.Clock.now())) == :gt,
       do: :ok,
       else: {:error, :prediction_required}
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp outcome_entry(outcome, attrs, wake) do
    base =
      Map.new([:title, :body, :prediction, :predicted_change, :predicted_by, :sources], fn key ->
        {key, field_attr(attrs, key)}
      end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()
      |> Platform.Goals.Takeaways.cite(outcome, field_attr(attrs, :takeaway_id))

    details = %{"wake_up_id" => wake.id}

    details =
      if field_attr(attrs, :undo_note),
        do: Map.put(details, "undo_note", field_attr(attrs, :undo_note)),
        else: details

    details =
      if field_attr(attrs, :until),
        do: Map.put(details, "until", date_scalar(field_attr(attrs, :until))),
        else: details

    base =
      Map.merge(base, %{
        kind: %{"do" => "action", "ask" => "ask", "wait" => "wait"}[outcome],
        reading_id: wake.reading_id,
        occurred_at: Platform.Goals.Clock.now(),
        details: details
      })

    cond do
      not is_nil(field_attr(attrs, :until)) and is_nil(parse_date(field_attr(attrs, :until))) ->
        {:error,
         Ecto.Changeset.add_error(
           Entry.changeset(%Entry{}, base),
           :details,
           "until must be a date"
         )}

      outcome == "wait" and not nonblank?(field_attr(attrs, :reason)) ->
        {:error, :reason_required}

      outcome == "wait" ->
        {:ok, Map.put(base, :body, field_attr(attrs, :reason))}

      not nonblank?(field_attr(attrs, :title)) ->
        {:error,
         Ecto.Changeset.add_error(Entry.changeset(%Entry{}, base), :title, "can't be blank")}

      true ->
        {:ok, base}
    end
  end

  defp date_scalar(%Date{} = date), do: Date.to_iso8601(date)
  defp date_scalar(value), do: value

  defp addressed(q, %User{id: id}), do: from(a in q, where: ^id in a.addressed_user_ids)
  defp addressed(q, _), do: from(a in q, where: false)
  defp final_answer_check(nil, _), do: :ok
  defp final_answer_check(%{answer: "ignored"}, answer) when answer in ~w(used declined), do: :ok
  defp final_answer_check(_, _), do: {:error, :already_answered}

  defp maybe_ask(actor, goal, wake, "ask", attrs) do
    now = Platform.Goals.Clock.now()
    clock = Platform.Goals.Clock.visible_clock(actor, goal.id)
    cap = Platform.Goals.OwnerPace.ask_cap(goal, clock)

    count =
      Repo.aggregate(
        from(a in children(actor, Platform.Goals.Ask, goal.id),
          where: a.status == "open" and a.expires_at > ^now
        ),
        :count
      )

    ids = field_attr(attrs, :addressed_user_ids) || [goal.owner_user_id]

    with :ok <- if(count < cap, do: :ok, else: {:error, :ask_cap_reached}),
         :ok <- addressees(actor, goal, ids) do
      %Platform.Goals.Ask{
        goal_id: goal.id,
        wake_up_id: wake.id,
        created_by_agent_id: actor.id,
        addressed_user_ids: Enum.uniq(ids)
      }
      |> Platform.Goals.Ask.changeset(%{
        kind: field_attr(attrs, :kind),
        title: field_attr(attrs, :title),
        body: field_attr(attrs, :body),
        payload: field_attr(attrs, :payload) || %{},
        expires_at: DateTime.add(now, Platform.Goals.Limits.ask_expiry_days() * 86400, :second)
      })
      |> Repo.insert()
    end
  end

  defp maybe_ask(_, _, _, _, _), do: {:ok, nil}

  defp addressees(_actor, goal, ids) do
    valid =
      is_list(ids) and length(ids) in 1..Platform.Goals.Limits.max_addressed() and
        Enum.all?(ids, fn raw ->
          case Ecto.UUID.cast(raw) do
            {:ok, id} ->
              user = Repo.one(from(u in User, where: u.id == ^id))
              match?({:ok, _}, get_goal(user, goal.id))

            _ ->
              false
          end
        end)

    if valid, do: :ok, else: {:error, :addressee_cannot_see_goal}
  end

  defp project_task_id(id) do
    case Platform.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :project_not_available}
    end
  end

  defp maybe_tasks(actor, goal, "do", attrs),
    do: GoalTasks.create_for_wake_up(actor, goal, field_attr(attrs, :task))

  defp maybe_tasks(_, _, _, _), do: {:ok, []}

  defp link_entry_attrs(attrs, ask, tasks) do
    details = attrs.details
    details = if ask, do: Map.put(details, "ask_id", ask.id), else: details

    details =
      case tasks do
        [first | _] ->
          Map.merge(details, %{"task_id" => first.id, "task_ids" => Enum.map(tasks, & &1.id)})

        [] ->
          details
      end

    %{attrs | details: details}
  end

  defp attach_outcome(actor, goal, wake, entry, ask, tasks) do
    if ask, do: Repo.update!(Ecto.Changeset.change(ask, entry_id: entry.id))

    for task <- tasks do
      case insert_task_link(actor, goal, task, wake.id, entry.id) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end

    :ok
  end

  defp unlinked(task_id) do
    if Repo.exists?(from(l in Platform.Goals.TaskLink, where: l.task_id == ^task_id)),
      do: {:error, :task_already_linked},
      else: :ok
  end

  defp insert_task_link(actor, goal, task, wake_id, entry_id) do
    with :ok <- same_goal_link(actor, goal, Platform.Goals.WakeUp, wake_id),
         :ok <- same_goal_link(actor, goal, Entry, entry_id) do
      changeset =
        Platform.Goals.TaskLink.changeset(
          %Platform.Goals.TaskLink{
            goal_id: goal.id,
            task_id: task.id,
            created_by_agent_id: actor.id,
            wake_up_id: wake_id,
            entry_id: entry_id
          },
          %{}
        )

      case Repo.insert(changeset) do
        {:error, changeset} = error ->
          if Keyword.has_key?(changeset.errors, :task_id),
            do: {:error, :task_already_linked},
            else: error

        ok ->
          ok
      end
    end
  end

  defp same_goal_link(_actor, _goal, _schema, nil), do: :ok

  defp same_goal_link(actor, goal, schema, raw_id) do
    with {:ok, id} <- cast_id(raw_id),
         true <- Repo.exists?(from(row in children(actor, schema, goal.id), where: row.id == ^id)) do
      :ok
    else
      _ -> {:error, :not_found}
    end
  end

  defp claim_close(wake, outcome, entry) do
    now = Platform.Goals.Clock.now()

    {count, _} =
      Repo.update_all(
        from(w in Platform.Goals.WakeUp, where: w.id == ^wake.id and w.status == "open"),
        set: [status: "closed", outcome: outcome, closed_at: now, entry_id: entry.id]
      )

    if count == 0,
      do: {:error, :wake_up_closed},
      else:
        {:ok, %{wake | status: "closed", outcome: outcome, closed_at: now, entry_id: entry.id}}
  end

  defp logged_source(goal) do
    with {:ok, source} <- Sources.fetch(goal.source_key),
         :logged <- source.kind() do
      {:ok, source}
    else
      _ -> {:error, :source_not_logged}
    end
  rescue
    _ -> {:error, :source_not_logged}
  end

  defp reading_attrs(attrs) when is_map(attrs) do
    # Normalise only the supported attrs, so callers may use either key style.
    for key <- [:value, :measured_at, :note, :origin, :details],
        into: %{measured_at: DateTime.utc_now(), origin: "manual"} do
      {key, Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), reading_default(key)))}
    end
  end

  defp reading_attrs(_), do: %{value: nil, measured_at: DateTime.utc_now(), origin: "manual"}
  defp reading_default(:measured_at), do: DateTime.utc_now()
  defp reading_default(:origin), do: "manual"
  defp reading_default(:details), do: %{}
  defp reading_default(_), do: nil

  defp authored_reading(actor, goal, population) do
    %Reading{
      goal_id: goal.id,
      source_key: goal.source_key,
      population: population,
      unit: goal.unit,
      author_type: if(match?(%User{}, actor), do: "user", else: "agent"),
      author_user_id: if(match?(%User{}, actor), do: actor.id),
      author_agent_id: if(match?(%Agent{}, actor), do: actor.id)
    }
  end

  defp with_source(%Goal{source_key: nil}, _fun), do: cannot_measure(:no_source, nil, nil)

  defp with_source(goal, fun) do
    case source_lookup(goal.source_key) do
      {:cannot_measure, :source_failed} ->
        cannot_measure(:source_failed, goal.source_key, nil)

      :error ->
        cannot_measure(:unknown_source, goal.source_key, nil)

      {:ok, source} ->
        case source_description(source) do
          {:ok, description} ->
            case source_call(fn -> source.population(goal) end, :population) do
              {:ok, population} ->
                fun.(source, description, population)

              {:cannot_measure, reason} ->
                cannot_measure(reason, goal.source_key, description.label)
            end

          :error ->
            cannot_measure(:source_failed, goal.source_key, nil)
        end
    end
  end

  defp source_lookup(key) do
    Sources.fetch(key)
  rescue
    _ -> {:cannot_measure, :source_failed}
  end

  defp source_description(source) do
    description = %{key: source.key(), label: source.label(), kind: source.kind()}

    if is_binary(description.key) and is_binary(description.label) and
         description.kind in [:logged, :measured], do: {:ok, description}, else: :error
  rescue
    _ -> :error
  end

  # Rescue only the source boundary, never database writes or context queries.
  defp source_call(fun, kind) do
    case {kind, fun.()} do
      {:population, {:ok, population}} when is_binary(population) ->
        {:ok, population}

      {:measure, {:ok, %{value: value, unit: unit, population: population} = result}}
      when is_binary(population) and (is_binary(unit) or is_nil(unit)) and
             (is_integer(value) or is_struct(value, Decimal)) ->
        case Decimal.cast(value) do
          {:ok, decimal} when is_integer(decimal.coef) -> {:ok, %{result | value: decimal}}
          _ -> {:cannot_measure, :source_failed}
        end

      {_, {:cannot_measure, reason}} when is_atom(reason) ->
        {:cannot_measure, reason}

      _ ->
        {:cannot_measure, :source_failed}
    end
  rescue
    _ -> {:cannot_measure, :source_failed}
  end

  defp measure_reading(actor, goal, source, description, population) do
    case source_call(fn -> source.measure(goal) end, :measure) do
      {:ok, %{population: ^population} = result} ->
        reading = %{authored_reading(actor, goal, population) | unit: result.unit}
        attrs = %{value: result.value, origin: "measured", measured_at: DateTime.utc_now()}

        with {:ok, _reading} <- reading |> Reading.changeset(attrs) |> Repo.insert() do
          number_result(actor, goal, description, population, [])
        end

      {:ok, _different_population} ->
        cannot_measure(:source_failed, goal.source_key, description.label)

      {:cannot_measure, reason} ->
        cannot_measure(reason, goal.source_key, description.label)
    end
  end

  defp cannot_measure(reason, key, label),
    do: {:ok, {:cannot_measure, %{reason: reason, source_key: key, source_label: label}}}

  defp ordered_readings(actor, goal) do
    from(r in children(actor, Reading, goal.id),
      order_by: [desc: r.measured_at, desc: r.inserted_at, desc: r.id]
    )
  end

  defp number_result(actor, goal, description, population, opts) do
    query =
      from(r in ordered_readings(actor, goal),
        where: r.source_key == ^goal.source_key and r.population == ^population
      )

    query =
      case Keyword.get(opts, :as_of) do
        %DateTime{} = cutoff -> from(r in query, where: r.measured_at <= ^cutoff)
        _ -> query
      end

    case Repo.all(from(r in query, limit: 2)) do
      [] ->
        cannot_measure(:no_reading_yet, goal.source_key, description.label)

      [latest | rest] ->
        previous = List.first(rest)

        baseline =
          case Keyword.get(opts, :since) do
            %DateTime{} = since ->
              Repo.one(from(r in query, where: r.measured_at <= ^since, limit: 1))

            _ ->
              nil
          end

        {:ok,
         {:reading,
          %{
            source: description,
            first:
              Repo.one(
                from(r in exclude(query, :order_by),
                  order_by: [asc: r.measured_at, asc: r.inserted_at, asc: r.id],
                  limit: 1
                )
              ),
            latest: latest,
            previous: previous,
            delta: reading_difference(latest, previous),
            baseline: baseline,
            change_since: reading_difference(latest, baseline)
          }}}
    end
  end

  defp reading_difference(_latest, nil), do: nil
  defp reading_difference(latest, earlier), do: Decimal.sub(latest.value, earlier.value)

  defp stop_attrs(attrs), do: Map.drop(attrs, [:position, "position"])

  defp children(actor, schema, goal_id) do
    from(row in schema,
      join: g in subquery(Visibility.visible_goals(actor)),
      on: g.id == row.goal_id,
      where: row.goal_id == ^goal_id
    )
  end

  defp authored_entry(%User{id: id}, goal),
    do: %Entry{
      goal_id: goal.id,
      author_type: "user",
      author_user_id: id,
      occurred_at: DateTime.utc_now()
    }

  defp authored_entry(%Agent{id: id}, goal),
    do: %Entry{
      goal_id: goal.id,
      author_type: "agent",
      author_agent_id: id,
      occurred_at: DateTime.utc_now()
    }

  defp validate_entry_link(changeset, actor, goal, field, schema) do
    case Ecto.Changeset.get_field(changeset, field) do
      nil ->
        changeset

      id ->
        query = from(row in children(actor, schema, goal.id), where: row.id == ^id)

        query =
          if field == :takeaway_id,
            do: from(row in query, where: row.kind == "takeaway"),
            else: query

        valid_id? = match?({:ok, _}, Ecto.UUID.cast(id))

        if valid_id? and Repo.exists?(query),
          do: changeset,
          else:
            Ecto.Changeset.add_error(
              changeset,
              field,
              "must belong to this goal and have the required kind"
            )
    end
  end

  # ── pages (Goals 4/8, task 01a1dfc1) ─────────────────────────────────────

  @typedoc """
  What a page shows about who a goal belongs to and who sees it. `audience`
  is the list for the owner and the coach and `:hidden` for every other
  viewer; a `:space` item also carries `handed?` (Goals 7/8). `current_stop`
  is the first stop by position not yet reached.
  """
  @type card :: %{
          goal: Goal.t(),
          role: :owner | :coach | :viewer,
          owner_name: String.t(),
          coach_name: String.t() | nil,
          audience:
            [
              %{
                :type => :user | :team | :space,
                :id => binary(),
                :name => String.t(),
                optional(:handed?) => boolean()
              }
            ]
            | :hidden,
          current_stop: Stop.t() | nil
        }

  @doc """
  A card (`t:card/0`) for every goal `actor` sees, newest first. A fixed
  number of queries whatever the number of goals; it never reads or
  computes a goal's number (`goal_number/3` does).
  """
  @spec describe_goals(actor()) :: {:ok, [card()]} | {:error, :goals_disabled}
  def describe_goals(actor) do
    with :ok <- check_enabled() do
      goals =
        actor
        |> Visibility.visible_goals()
        |> order_by([g], desc: g.inserted_at, desc: g.id)
        |> Repo.all()

      {:ok, cards(actor, goals)}
    end
  end

  @doc """
  The card (`t:card/0`) for one goal `actor` sees. Unseen, missing and
  malformed ids all answer `{:error, :not_found}`.
  """
  @spec describe_goal(actor(), term()) ::
          {:ok, card()} | {:error, :not_found | :goals_disabled}
  def describe_goal(actor, goal_id) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      [card] = cards(actor, [goal])
      {:ok, card}
    end
  end

  @doc """
  Who the owner may open `goal_id` to, each item
  `%{id, name, detail, open?}`, sorted by name:

    * `people`: non-external members of the orgs the owner holds a
      non-external membership in, the owner excluded; `detail` is nil;
    * `teams`: those orgs; `detail` is their non-external member count;
    * `spaces`: non-archived `channel` spaces the owner has a participant
      row in; `detail` is `:agents` for the space core's
      `Platform.Chat.Sidebar.agents_rail_block/0` shows, nil otherwise.

  `open?` says the goal is open to that audience now. Owner only: any other
  viewer gets `{:error, :forbidden}`, an unseen goal `{:error, :not_found}`.
  """
  @spec list_audience_options(actor(), term()) ::
          {:ok, %{people: [map()], teams: [map()], spaces: [map()]}} | {:error, term()}
  def list_audience_options(actor, goal_id) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false),
         :ok <- check_owner(actor, goal) do
      open = open_audiences(actor, goal)
      org_ids = owner_org_ids(goal.owner_user_id)

      {:ok,
       %{
         people: people_options(goal.owner_user_id, org_ids, open),
         teams: team_options(org_ids, open),
         spaces: space_options(goal.owner_user_id, open)
       }}
    end
  end

  @doc """
  Who wrote a visible goal's notebook, plus its coach, for the goal page
  (Goals 4/8 stage 3): `{:ok, %{agents: %{id => %{name, slot, avatar_url}},
  users: %{id => %{name}}}}`. `slot` is the agent's colour slot
  (`Platform.Agents.ColorPalette.slot_for/1`). Two bounded queries plus
  the goal read; unseen, missing and malformed ids answer
  `{:error, :not_found}`.
  """
  @spec entry_authors(actor(), term()) :: {:ok, map()} | {:error, :not_found | :goals_disabled}
  def entry_authors(actor, goal_id) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      authors =
        Repo.all(
          from(e in children(actor, Entry, goal.id),
            distinct: true,
            select: {e.author_agent_id, e.author_user_id}
          )
        )

      agent_ids =
        ([goal.coach_agent_id | Enum.map(authors, &elem(&1, 0))] ++
           Enum.map(Platform.Goals.Handoff.contributors(actor, goal), & &1.agent_id))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      user_ids = authors |> Enum.map(&elem(&1, 1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()

      agents =
        from(a in Agent,
          where: a.id in ^agent_ids,
          select: {a.id, %{name: a.name, color: a.color, avatar_url: a.avatar_url}}
        )
        |> Repo.all()
        |> Map.new(fn {id, a} ->
          {id,
           %{
             name: a.name,
             slot: Platform.Agents.ColorPalette.slot_for(a.color),
             avatar_url: a.avatar_url
           }}
        end)

      users = for {id, name} <- names_by_id(User, user_ids), into: %{}, do: {id, %{name: name}}

      {:ok, %{agents: agents, users: users}}
    end
  end

  defp cards(_actor, []), do: []

  defp cards(actor, goals) do
    goal_ids = Enum.map(goals, & &1.id)
    owners = names_by_id(User, goals |> Enum.map(& &1.owner_user_id) |> Enum.uniq())

    coaches =
      names_by_id(Agent, goals |> Enum.map(& &1.coach_agent_id) |> Enum.reject(&is_nil/1))

    roles = Map.new(goals, &{&1.id, role(actor, &1)})
    audiences = audiences(actor, for({id, role} <- roles, role != :viewer, do: id))
    stops = current_stops(actor, goal_ids)

    Enum.map(goals, fn goal ->
      role = Map.fetch!(roles, goal.id)

      %{
        goal: goal,
        role: role,
        owner_name: Map.get(owners, goal.owner_user_id, ""),
        coach_name: goal.coach_agent_id && Map.get(coaches, goal.coach_agent_id),
        audience: if(role == :viewer, do: :hidden, else: Map.get(audiences, goal.id, [])),
        current_stop: Map.get(stops, goal.id)
      }
    end)
  end

  defp role(actor, goal) do
    cond do
      owner?(actor, goal) -> :owner
      coach?(actor, goal) -> :coach
      true -> :viewer
    end
  end

  # One query per schema; a user without a name shows their email.
  defp names_by_id(_schema, []), do: %{}

  defp names_by_id(User, ids) do
    from(u in User, where: u.id in ^ids, select: {u.id, coalesce(u.name, u.email)})
    |> Repo.all()
    |> Map.new()
  end

  defp names_by_id(schema, ids) do
    from(row in schema, where: row.id in ^ids, select: {row.id, row.name})
    |> Repo.all()
    |> Map.new()
  end

  # Grants of the given (visible) goals, resolved to names with one query
  # per audience type.
  defp audiences(_actor, []), do: %{}

  defp audiences(actor, goal_ids) do
    grants =
      Repo.all(
        from(gr in Grant,
          join: g in subquery(Visibility.visible_goals(actor)),
          on: g.id == gr.goal_id,
          where: gr.goal_id in ^goal_ids,
          order_by: [asc: gr.inserted_at, asc: gr.id]
        )
      )

    ids = fn column -> grants |> Enum.map(&Map.get(&1, column)) |> Enum.reject(&is_nil/1) end

    names = %{
      user: names_by_id(User, ids.(:user_id)),
      team: names_by_id(Platform.Tenancy.Org, ids.(:org_id)),
      space: names_by_id(Platform.Chat.Space, ids.(:space_id))
    }

    grants
    |> Enum.map(fn gr ->
      {type, id} = grant_audience(gr)
      item = %{type: type, id: id, name: Map.get(names[type], id) || ""}
      item = if type == :space, do: Map.put(item, :handed?, gr.handed_at != nil), else: item
      {gr.goal_id, item}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp grant_audience(%Grant{audience_type: "user", user_id: id}), do: {:user, id}
  defp grant_audience(%Grant{audience_type: "team", org_id: id}), do: {:team, id}
  defp grant_audience(%Grant{audience_type: "space", space_id: id}), do: {:space, id}

  defp current_stops(actor, goal_ids) do
    from(s in Stop,
      join: g in subquery(Visibility.visible_goals(actor)),
      on: g.id == s.goal_id,
      where: s.goal_id in ^goal_ids and is_nil(s.reached_on),
      distinct: s.goal_id,
      order_by: [asc: s.goal_id, asc: s.position]
    )
    |> Repo.all()
    |> Map.new(&{&1.goal_id, &1})
  end

  defp open_audiences(actor, goal) do
    actor
    |> audiences([goal.id])
    |> Map.get(goal.id, [])
    |> MapSet.new(&{&1.type, &1.id})
  end

  defp owner_org_ids(owner_id) do
    Repo.all(
      from(m in OrgMembership,
        where: m.user_id == ^owner_id and m.external == false,
        distinct: true,
        select: m.org_id
      )
    )
  end

  defp people_options(_owner_id, [], _open), do: []

  defp people_options(owner_id, org_ids, open) do
    from(u in User,
      where:
        u.id != ^owner_id and
          u.id in subquery(
            from(m in OrgMembership,
              where: m.org_id in ^org_ids and m.external == false,
              select: m.user_id
            )
          ),
      select: {u.id, coalesce(u.name, u.email)}
    )
    |> Repo.all()
    |> options(:user, open, fn _id -> nil end)
  end

  defp team_options([], _open), do: []

  defp team_options(org_ids, open) do
    counts =
      from(m in OrgMembership,
        where: m.org_id in ^org_ids and m.external == false,
        group_by: m.org_id,
        select: {m.org_id, count(m.user_id, :distinct)}
      )
      |> Repo.all()
      |> Map.new()

    from(o in Platform.Tenancy.Org, where: o.id in ^org_ids, select: {o.id, o.name})
    |> Repo.all()
    |> options(:team, open, &Map.get(counts, &1, 0))
  end

  defp space_options(owner_id, open) do
    agents_space_id = agents_space_id()

    from(s in Platform.Chat.Space,
      join: p in Participant,
      on: p.space_id == s.id,
      where:
        s.kind == "channel" and is_nil(s.archived_at) and p.participant_type == "user" and
          p.participant_id == ^owner_id,
      distinct: true,
      select: {s.id, s.name}
    )
    |> Repo.all()
    |> options(:space, open, &if(&1 == agents_space_id, do: :agents))
  end

  defp agents_space_id do
    case Platform.Chat.Sidebar.agents_rail_block() do
      %{space: %{id: id}} -> id
      _ -> nil
    end
  end

  defp options(rows, type, open, detail) do
    rows
    |> Enum.map(fn {id, name} ->
      %{id: id, name: name || "", detail: detail.(id), open?: MapSet.member?(open, {type, id})}
    end)
    |> Enum.sort_by(&{String.downcase(&1.name), &1.id})
  end

  # ── hand-off to a space's agents (Goals 7/8, task 01a1dfc1-dffb) ─────────
  # Thin entry points: the rules live in `Platform.Goals.Handoff`.

  @doc """
  Hands a goal already opened to `space_id` to that space's agents. The user
  must be a root admin AND a participant of the space; an unseen goal or a
  malformed id is `:not_found`, a space without a grant `:not_linked`. A
  coachless goal gets the space's leader as coach when the owner hands it,
  else `:no_coach`; the coach must be in the space (`:coach_not_in_space`).
  Idempotent.
  """
  def hand_goal_to_space(actor, goal_id, space_id) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- locked_goal(actor, goal_id),
             do: Platform.Goals.Handoff.hand(actor, goal, owner?(actor, goal), space_id)
      end)
    end
  end

  @doc "Clears a space's hand-off: the owner or a user who may hand. Not handed is ok unchanged."
  def take_goal_back(actor, goal_id, space_id) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- locked_goal(actor, goal_id),
             do: Platform.Goals.Handoff.take_back(actor, goal, owner?(actor, goal), space_id)
      end)
    end
  end

  @doc "The agents working a visible goal in the spaces it is handed to, derived live."
  def list_contributors(actor, goal_id) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false),
         do: {:ok, Platform.Goals.Handoff.contributors(actor, goal)}
  end

  @doc "Creates the owner's idempotent pinned card for an existing space grant."
  def ensure_space_card(actor, goal_id, space_id) do
    with :ok <- check_enabled() do
      in_transaction(fn ->
        with {:ok, goal} <- locked_goal(actor, goal_id),
             :ok <- check_owner(actor, goal),
             do: Platform.Goals.SpaceCards.ensure(actor, goal, space_id)
      end)
    end
  end

  @doc "A visible space card, resolved through its grant's canvas id."
  def space_card(actor, canvas_id) do
    with :ok <- check_enabled(),
         {:ok, view} <- Platform.Goals.SpaceCards.view(actor, canvas_id) do
      audience = Map.get(audiences(actor, [view.card.goal.id]), view.card.goal.id, [])

      badge =
        case audience do
          [%{type: :space, id: id}] when id == view.space.id -> "Shown in ##{view.space.name}"
          rows -> "Shared: " <> Enum.map_join(rows, ", ", & &1.name)
        end

      {:ok, Map.put(view, :badge, badge)}
    end
  end

  # update_goal/3's lock order: clock, then goal.
  defp locked_goal(actor, goal_id) do
    with {:ok, goal} <- fetch_visible(actor, goal_id, false),
         :ok <- lock_clock(actor, goal),
         do: fetch_visible(actor, goal_id, true)
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp check_enabled, do: if(enabled?(), do: :ok, else: {:error, :goals_disabled})

  # `goals.use` for the functions that act without loading a goal through
  # `Visibility.visible_goals/1` (task 01a1e229). Every other function is
  # closed by `visible_goals/1` itself, answering `:not_found` as for a goal
  # that does not exist. Read on every call, never cached.
  defp check_use(%User{} = user),
    do: if(Visibility.may_use?(user), do: :ok, else: {:error, :forbidden})

  defp check_use(_actor), do: :ok

  defp fetch_visible(actor, goal_id, lock?) do
    with {:ok, id} <- cast_id(goal_id) do
      query = from(g in Visibility.visible_goals(actor), where: g.id == ^id)
      query = if lock?, do: lock(query, "FOR UPDATE"), else: query

      case Repo.one(query) do
        %Goal{} = goal -> {:ok, goal}
        nil -> {:error, :not_found}
      end
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp owner?(%User{id: id}, %Goal{owner_user_id: id}) when is_binary(id), do: true
  defp owner?(_actor, _goal), do: false

  defp coach?(%Agent{id: id}, %Goal{coach_agent_id: id}) when is_binary(id), do: true
  defp coach?(_actor, _goal), do: false

  defp check_owner(actor, goal), do: if(owner?(actor, goal), do: :ok, else: {:error, :forbidden})

  defp check_can_edit(actor, goal) do
    if owner?(actor, goal) or coach?(actor, goal), do: :ok, else: {:error, :forbidden}
  end

  defp has_grants?(goal), do: Repo.exists?(from(gr in Grant, where: gr.goal_id == ^goal.id))

  defp audience_column({:user, _}), do: {:ok, {"user", :user_id}}
  defp audience_column({:team, _}), do: {:ok, {"team", :org_id}}
  defp audience_column({:space, _}), do: {:ok, {"space", :space_id}}
  defp audience_column(_), do: {:error, :audience_not_available}

  defp available_audience(goal, {_, raw_id} = audience) do
    with {:ok, {type, column}} <- audience_column(audience),
         {:ok, id} <- cast_audience_id(raw_id),
         true <- audience_available?(goal, type, id) do
      {:ok, {type, column, id}}
    else
      _ -> {:error, :audience_not_available}
    end
  end

  defp available_audience(_goal, _audience), do: {:error, :audience_not_available}

  defp cast_audience_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      :error -> :error
    end
  end

  defp audience_available?(goal, "user", user_id) do
    user_id != goal.owner_user_id and Repo.exists?(from(u in User, where: u.id == ^user_id))
  end

  defp audience_available?(goal, "team", org_id) do
    Repo.exists?(
      from(m in OrgMembership,
        where: m.org_id == ^org_id and m.user_id == ^goal.owner_user_id and m.external == false
      )
    )
  end

  defp audience_available?(goal, "space", space_id) do
    Repo.exists?(
      from(p in Participant,
        where:
          p.space_id == ^space_id and p.participant_type == "user" and
            p.participant_id == ^goal.owner_user_id
      )
    )
  end

  defp in_transaction(fun) do
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
