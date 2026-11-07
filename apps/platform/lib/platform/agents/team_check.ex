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
  are read, first found wins, from:

    1. the row's `metadata["operator_config"]`, written by
       `Platform.Responsibilities.put_operator_config/2`. Boot
       re-registration keeps this key and replaces the rest of `metadata`
       (task 01a1b6de stage 4), so an operator's value survives a deploy;
    2. the row's `metadata`;
    3. `config :platform, Platform.Agents.TeamCheck` (config/config.exs);
    4. the module constants, only when the config is absent too.

  The re-ask interval an ask actually uses is resolved per subject through
  the `agents.unblock_ask.reask_interval` experiment surface first
  (`Platform.Agents.UnblockAsks.interval_for/2`), falling back to the above.

  ## Re-asking

  Asks are `unblock_asks` rows, one live row per subject and class
  (`Platform.Agents.UnblockAsks`), which decide when to ask again.
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

  @doc "The responsibility key."
  def key, do: @key

  @doc "Event types read as failures."
  def failure_types, do: @failure_types

  @doc "The configured defaults (config, then module constants) the row overrides."
  def default_config do
    config = Application.get_env(:platform, __MODULE__, [])

    %{
      "reask_after_hours" =>
        config_value(config, :reask_after_hours, @default_reask_after_hours, 1),
      "offline_after_minutes" =>
        config_value(config, :offline_after_minutes, @default_offline_after_minutes, 0),
      "lookback_hours" => config_value(config, :lookback_hours, @default_lookback_hours, 1)
    }
  end

  defp config_value(config, key, default, min) do
    case Keyword.get(config, key) do
      n when is_integer(n) and n >= min -> n
      _ -> default
    end
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
    operator = Map.get(metadata, "operator_config")
    operator = if is_map(operator), do: operator, else: %{}

    Enum.find_value(
      [Map.get(operator, field), Map.get(metadata, field)],
      Map.fetch!(default_config(), field),
      fn
        n when is_integer(n) and n >= 0 -> n
        _ -> nil
      end
    )
  end

  defp config_int(_row, field), do: Map.fetch!(default_config(), field)

  @doc """
  One status per active agent:
  `%{agent, agent_id, agent_name, kind, class, evidence, basis, fixer, action,
  details}`. `details` are the placeholder values an unblock ask renders
  with, read from the deciding failure text (`refusal_details/1`).

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
        runtime_ids: agent_runtimes |> Enum.map(& &1.runtime_id) |> Enum.filter(&is_binary/1),
        details: refusal_details(result.basis)
      })
    end)
  end

  @doc """
  The placeholder values a refusal text names: `"org"` and `"repo"` from
  "Permission to <org>/<repo>.git denied", `"account"` from "denied to
  <account>". Keys the text does not name are absent.
  """
  @spec refusal_details(String.t() | nil) :: map()
  def refusal_details(text) when is_binary(text) do
    repo =
      case Regex.run(
             ~r{[Pp]ermission to ([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)? denied},
             text
           ) do
        [_, org, repo] -> %{"org" => org, "repo" => repo}
        _ -> %{}
      end

    account =
      case Regex.run(~r{denied to ([A-Za-z0-9][A-Za-z0-9_-]*(?:\[bot\])?)}, text) do
        [_, account] -> %{"account" => account}
        _ -> %{}
      end

    Map.merge(repo, account)
  end

  def refusal_details(_text), do: %{}

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
