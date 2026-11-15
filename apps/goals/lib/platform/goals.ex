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
  `{:error, :not_found}`. Of those who can see a goal, the owner and the
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
  alias Platform.Goals.{Entry, Goal, Grant, Reading, Sources, Stop, Visibility}
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
    with :ok <- check_enabled() do
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
        with {:ok, goal} <- fetch_visible(actor, goal_id, true),
             :ok <- check_can_edit(actor, goal),
             changeset = Goal.changeset(goal, editable_attrs(actor, goal, attrs)),
             :ok <- check_kind_change(changeset, goal) do
          Repo.update(changeset)
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
             :ok <- check_can_edit(actor, goal) do
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

  @doc "Reads the current population's latest number, previous value and optional baseline."
  def goal_number(actor, goal_id, opts \\ []) do
    with :ok <- check_enabled(),
         {:ok, goal} <- fetch_visible(actor, goal_id, false) do
      with_source(goal, fn _source, description, population ->
        number_result(actor, goal, description, population, opts)
      end)
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
  def list_sources(_actor) do
    with :ok <- check_enabled(), do: {:ok, Sources.describe()}
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

  # ── internals ────────────────────────────────────────────────────────────

  defp check_enabled, do: if(enabled?(), do: :ok, else: {:error, :goals_disabled})

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
