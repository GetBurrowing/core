defmodule Platform.Agents.TeamCheck do
  @moduledoc """
  The per-agent status behind `agents.team_check` (task 01a1b6de stage 3): is
  each agent present, and if it is stuck, why and who can fix it.

  Built from real signals only:

    * presence — `Platform.Federation.federation_status/0` for federated
      agents (`online`, `last_seen_at`, `last_connected_at`); the row's
      probe/fire columns for external HTTP agents
      (`Platform.ExternalAgents.liveness/2`); a local built-in runs inside this
      BEAM and is present by construction;
    * failures — `runtime_events` rows of type `execution.blocked`,
      `execution.no_ack_timeout` and `execution.dispatch_unanswered` inside
      the lookback window, attributed to an agent by its id or any of its
      runtime ids (`runtime_id`, `payload.reported_by`,
      `payload.dispatch_runtime_id`). A later `execution.unblocked` on the
      same task (and stage, when both carry one) CLEARS a failure, whoever
      filed it.

  The class itself is `Platform.Agents.TeamCheck.Classifier.classify/1`, a
  pure function; nothing on this path calls a model.

  Every agent kind is classified — native built-in, federated (including
  install-managed native runtimes) and external HTTP — and an agent with no
  runtime row or no presence entry reads as offline rather than raising.

  ## Configuration is data

  The schedule is the `agents.team_check` row's `trigger_config`, read with
  `Platform.Responsibilities.GoalCadence.from_row/1` (`cadence/0`). The
  re-ask interval (`"reask_after_hours"`), the offline threshold
  (`"offline_after_minutes"`) and the failure lookback (`"lookback_hours"`)
  are read off the row's `metadata`; the module constants below are only the
  defaults used when the row or the key is absent.

  ## Re-asking

  A stuck agent is raised once, then not again until the interval passes or
  its class changes. The last raise is stamped on the agent's own
  `metadata["team_check"]` (`"class"`, `"asked_at"`), cleared when it reads
  `:ok`.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Platform.Accounts
  alias Platform.Agents.Agent
  alias Platform.Agents.AgentRuntime
  alias Platform.Agents.Kind
  alias Platform.Agents.TeamCheck.Classifier
  alias Platform.ExternalAgents
  alias Platform.Federation
  alias Platform.Orchestration.RuntimeEvent
  alias Platform.Repo
  alias Platform.Responsibilities
  alias Platform.Responsibilities.GoalCadence
  alias Platform.Responsibilities.Responsibility

  @key "agents.team_check"

  @failure_types ~w(execution.blocked execution.no_ack_timeout execution.dispatch_unanswered)
  @clear_type "execution.unblocked"

  @default_reask_after_hours 72
  @default_offline_after_minutes 120
  @default_lookback_hours 168

  @stamp_key "team_check"

  @doc "The responsibility key."
  def key, do: @key

  @doc "Event types read as failures."
  def failure_types, do: @failure_types

  @doc "The defaults the row's metadata overrides."
  def default_config do
    %{
      "reask_after_hours" => @default_reask_after_hours,
      "offline_after_minutes" => @default_offline_after_minutes,
      "lookback_hours" => @default_lookback_hours
    }
  end

  @doc "The `agents.team_check` row's cadence; daily at the declared hour when absent."
  @spec cadence(Responsibility.t() | nil) :: GoalCadence.reading()
  def cadence(row \\ Responsibilities.get_by_key(@key))

  def cadence(%Responsibility{} = row), do: GoalCadence.from_row(row)
  def cadence(nil), do: %{cadence: :daily, hour_utc: nil}

  @doc "The re-ask interval in hours, read from the row."
  @spec reask_after_hours(Responsibility.t() | nil) :: pos_integer()
  def reask_after_hours(row), do: config_int(row, "reask_after_hours")

  @doc "Minutes without presence before an agent reads offline, read from the row."
  @spec offline_after_minutes(Responsibility.t() | nil) :: non_neg_integer()
  def offline_after_minutes(row), do: config_int(row, "offline_after_minutes")

  @doc "How far back failures are read, in hours, read from the row."
  @spec lookback_hours(Responsibility.t() | nil) :: pos_integer()
  def lookback_hours(row), do: config_int(row, "lookback_hours")

  defp config_int(%Responsibility{metadata: metadata}, field) when is_map(metadata) do
    case Map.get(metadata, field) do
      n when is_integer(n) and n >= 0 -> n
      _ -> Map.fetch!(default_config(), field)
    end
  end

  defp config_int(_row, field), do: Map.fetch!(default_config(), field)

  @doc """
  One status per active agent:
  `%{agent, agent_id, agent_name, kind, class, evidence, fixer, action, last_ask}`.

  Options: `:row` (the responsibility row; read from the DB when absent),
  `:now`, and `:federation` (rows shaped like `Federation.federation_status/0`,
  the default).
  """
  @spec statuses(keyword()) :: [map()]
  def statuses(opts \\ []) do
    row = Keyword.get_lazy(opts, :row, fn -> Responsibilities.get_by_key(@key) end)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    federation = Keyword.get_lazy(opts, :federation, &safe_federation_status/0)

    agents = active_agents()
    runtimes = runtimes_by_agent(agents)
    federation_by_agent = Enum.group_by(federation, & &1.agent_id)
    failures = open_failures(agents, runtimes, now, lookback_hours(row))
    owner = Accounts.install_owner()
    threshold = offline_after_minutes(row) * 60

    Enum.map(agents, fn agent ->
      agent_runtimes = Map.get(runtimes, agent.id, [])

      result =
        Classifier.classify(%{
          presence: presence(agent, Map.get(federation_by_agent, agent.id, []), now),
          failures: Map.get(failures, agent.id, []),
          now: now,
          offline_after_seconds: threshold,
          sponsor: sponsor(agent_runtimes),
          owner: owner
        })

      Map.merge(result, %{
        agent: agent,
        agent_id: agent.id,
        agent_name: agent.name,
        kind: Kind.classify(agent),
        last_ask: last_ask(agent)
      })
    end)
  end

  @doc """
  The statuses that should be raised now: not `:ok`, and either never asked,
  asked about a different class, or asked longer ago than the interval.
  """
  @spec to_raise([map()], Responsibility.t() | nil, DateTime.t()) :: [map()]
  def to_raise(statuses, row, now \\ DateTime.utc_now()) do
    interval = reask_after_hours(row) * 3600

    Enum.filter(statuses, fn status ->
      status.class != :ok and due?(status.last_ask, status.class, interval, now)
    end)
  end

  defp due?(nil, _class, _interval, _now), do: true

  defp due?(%{"class" => asked_class, "asked_at" => asked_at}, class, interval, now) do
    with true <- asked_class == Atom.to_string(class),
         {:ok, at, _} <- DateTime.from_iso8601(to_string(asked_at)) do
      DateTime.diff(now, at, :second) >= interval
    else
      _ -> true
    end
  end

  defp due?(_last_ask, _class, _interval, _now), do: true

  @doc """
  Stamp what was raised and clear stamps on agents that now read `:ok`.
  A failed write is logged, never raised.
  """
  @spec record_asks([map()], [map()], DateTime.t()) :: :ok
  def record_asks(statuses, raised, now \\ DateTime.utc_now()) do
    raised_ids = MapSet.new(raised, & &1.agent_id)

    Enum.each(statuses, fn status ->
      cond do
        MapSet.member?(raised_ids, status.agent_id) ->
          stamp(status.agent, %{
            "class" => Atom.to_string(status.class),
            "asked_at" => DateTime.to_iso8601(now)
          })

        status.class == :ok and status.last_ask != nil ->
          stamp(status.agent, nil)

        true ->
          :ok
      end
    end)
  end

  # The struct `statuses/1` loaded, so no id lookup happens here.
  defp stamp(%Agent{} = agent, value) do
    metadata = agent.metadata || %{}

    metadata =
      if value, do: Map.put(metadata, @stamp_key, value), else: Map.delete(metadata, @stamp_key)

    case agent |> Ecto.Changeset.change(metadata: metadata) |> Repo.update() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("[agents.team_check] could not stamp #{agent.id}: #{inspect(reason)}")
        :ok
    end
  rescue
    error ->
      Logger.warning("[agents.team_check] stamp raised for #{agent.id}: #{inspect(error)}")
      :ok
  end

  defp last_ask(%Agent{metadata: %{@stamp_key => %{} = ask}}), do: ask
  defp last_ask(_agent), do: nil

  # ── signals ──────────────────────────────────────────────────────────────

  defp active_agents do
    Repo.all(from(a in Agent, where: a.status == "active", order_by: [asc: a.inserted_at]))
  end

  defp runtimes_by_agent([]), do: %{}

  defp runtimes_by_agent(agents) do
    ids = Enum.map(agents, & &1.id)
    pks = agents |> Enum.map(& &1.runtime_id) |> Enum.reject(&is_nil/1)

    from(r in AgentRuntime, where: r.agent_id in ^ids or r.id in ^pks)
    |> Repo.all()
    |> Enum.flat_map(fn runtime ->
      owners =
        Enum.filter(agents, fn agent ->
          agent.id == runtime.agent_id or agent.runtime_id == runtime.id
        end)

      Enum.map(owners, &{&1.id, runtime})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {id, runtimes} -> {id, Enum.uniq_by(runtimes, & &1.id)} end)
  end

  defp safe_federation_status do
    Federation.federation_status()
  rescue
    error ->
      Logger.warning("[agents.team_check] federation_status raised: #{inspect(error)}")
      []
  catch
    :exit, reason ->
      Logger.warning("[agents.team_check] federation_status exited: #{inspect(reason)}")
      []
  end

  @doc false
  # Presence for one agent, by kind. Public for tests.
  def presence(%Agent{} = agent, federation_rows, now) do
    case Kind.classify(agent) do
      :loc_built_in ->
        %{online: true, last_seen_at: now, source: :in_process}

      :ext_single_responsibility ->
        %{
          online: ExternalAgents.liveness(agent, now) != :dead,
          last_seen_at: agent.last_successful_fire_at,
          source: :external_probe
        }

      :fed_conversational ->
        federated_presence(federation_rows)
    end
  end

  defp federated_presence([]), do: %{online: false, last_seen_at: nil, source: :no_runtime}

  defp federated_presence(rows) do
    seen =
      rows
      |> Enum.flat_map(&[Map.get(&1, :last_seen_at), Map.get(&1, :last_connected_at)])
      |> Enum.filter(&match?(%DateTime{}, &1))
      |> Enum.max(DateTime, fn -> nil end)

    %{
      online: Enum.any?(rows, &(Map.get(&1, :online) == true)),
      last_seen_at: seen,
      source: :federation
    }
  end

  defp sponsor(runtimes) do
    Enum.find_value(runtimes, fn
      %AgentRuntime{owner_user_id: id} when is_binary(id) ->
        case Accounts.get_user(id) do
          %{id: id, name: name} -> %{id: id, name: name}
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp open_failures(agents, runtimes, now, lookback_hours) do
    since = DateTime.add(now, -lookback_hours * 3600, :second)
    identity = identity_index(agents, runtimes)

    events =
      Repo.all(
        from(e in RuntimeEvent,
          where: e.occurred_at >= ^since and e.event_type in ^[@clear_type | @failure_types],
          order_by: [asc: e.occurred_at]
        )
      )

    {clears, failures} = Enum.split_with(events, &(&1.event_type == @clear_type))

    failures
    |> Enum.reject(&cleared?(&1, clears))
    |> Enum.flat_map(fn event ->
      event
      |> candidate_ids()
      |> Enum.map(&Map.get(identity, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&{&1, failure(event)})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp identity_index(agents, runtimes) do
    Enum.reduce(agents, %{}, fn agent, acc ->
      ids =
        [agent.id | Enum.flat_map(Map.get(runtimes, agent.id, []), &[&1.runtime_id, &1.id])]
        |> Enum.reject(&is_nil/1)

      Enum.reduce(ids, acc, &Map.put(&2, &1, agent.id))
    end)
  end

  defp candidate_ids(%RuntimeEvent{runtime_id: runtime_id, payload: payload}) do
    payload = payload || %{}

    [runtime_id, payload["reported_by"], payload["dispatch_runtime_id"], payload["runtime_id"]]
    |> Enum.filter(&is_binary/1)
  end

  defp cleared?(%RuntimeEvent{} = failure, clears) do
    stage = stage_of(failure)

    Enum.any?(clears, fn clear ->
      clear.task_id == failure.task_id and
        DateTime.compare(clear.occurred_at, failure.occurred_at) == :gt and
        (is_nil(stage) or is_nil(stage_of(clear)) or stage_of(clear) == stage)
    end)
  end

  defp stage_of(%RuntimeEvent{payload: %{"stage_id" => id}}) when is_binary(id), do: id
  defp stage_of(_), do: nil

  defp failure(%RuntimeEvent{event_type: type, payload: payload, occurred_at: at}) do
    payload = payload || %{}

    text =
      [payload["description"], payload["required_capability"], payload["reason"]]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.join(" | ")

    %{event_type: type, text: if(text == "", do: type, else: text), occurred_at: at}
  end
end
