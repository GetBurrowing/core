defmodule Platform.Doctor do
  @moduledoc """
  The `doctor` super agent's server side: a read-only checkup of install
  health, a closed list of safe heals, and the findings no agent may heal.

  The doctor heals Burrow itself. It is its own role, not a key on an existing
  bundle, because it reads install-wide health that no product role should
  hold, and because it judges other agents' failures, so it must not be one
  of the agents it judges (super-agent spec, section 3, "Add").

  ## The checkup (`checkup/1`): reads only

    * **agents** — every native agent whose host last reported `crashed` or
      `needs_login` (`Platform.AgentHost.status/1`), with its desired state;
    * **stuck dispatches** — `blocked` execution leases, split into
      dependency waits and human waits (`ExecutionLease.wait_kind/1`), and
      `active` leases already past `expires_at`;
    * **failing responsibilities** — enabled rows whose assignee resolves but
      cannot be reached (`:runtime_missing` / `:runtime_offline` in
      `Platform.Responsibilities.Reachability.report/0`), excluding rows that
      declare themselves inert;
    * **held updates** — `Platform.Updates.status/0` reporting
      `held_irreversible`;
    * **agent host** — configured but not connected (an install with no
      agent host configured has nothing to connect and reads healthy).

  ## Safe heals (`heal/2`): existing functions only, bounded, audited

  Exactly two, both reversible and both already offered to humans by the UI:

    1. **Restart a crashed native agent** that is meant to be running, with
       `Platform.AgentHost.restart_agent/1` (the Restart button). At most once
       per agent per `restart_backoff_hours/0`: a second crash inside the
       window is escalated instead of restarted again, so the doctor never
       loops on a broken agent.
    2. **Re-verify a dependency wait** with
       `Platform.Orchestration.BlockerReassessment.reassess/1`, which is
       due-gated, has its own attempt budget and asks only the owning runtime.
       A wait whose budget is spent is escalated.

  Every heal attempt writes one `doctor.heal` audit row (`Platform.Audit`).

  ## Never healed, always escalated

  A login (`needs_login` needs a human's credential), a held update (a human
  chooses whether an irreversible release goes out), a crash that came back
  after a restart, a failed restart, and an agent host that is not connected.
  The doctor never stops, deletes, rolls back, deploys, migrates, clears a
  lease or changes a task's status. Those are destructive or a human's call,
  and the doctor has no code path that does them.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias Platform.AgentHost
  alias Platform.Agents.NativeAgents
  alias Platform.Audit
  alias Platform.Orchestration.BlockerReassessment
  alias Platform.Orchestration.ExecutionLease
  alias Platform.Repo
  alias Platform.Responsibilities.Reachability
  alias Platform.Updates

  @role "doctor"
  @heal_event "doctor.heal"
  @restart_backoff_hours 6
  @list_cap 20
  @unreachable_classes [:runtime_missing, :runtime_offline]

  @typedoc "One agent the host reports unwell."
  @type agent_finding :: %{
          agent_id: String.t(),
          name: String.t(),
          state: :crashed | :needs_login,
          desired_state: String.t() | nil,
          detail: String.t() | nil
        }

  @typedoc "The checkup snapshot."
  @type checkup :: %{
          agents: [agent_finding()],
          dependency_waits: [map()],
          human_waits: [map()],
          expired_leases: [map()],
          unreachable_responsibilities: [map()],
          update_held?: boolean(),
          agent_host: :ok | :not_connected | :not_configured
        }

  @typedoc "A finding no agent may heal: the question and its detail."
  @type escalation :: %{question: String.t(), detail: String.t()}

  @doc "The role key."
  @spec role() :: String.t()
  def role, do: @role

  @doc "The audit `event_type` every heal attempt writes."
  @spec heal_event() :: String.t()
  def heal_event, do: @heal_event

  @doc """
  Switches the doctor on for one agent: assigns `doctor` and records the
  person its escalations go to. See `Platform.SuperAgents.provision/3`.
  """
  @spec provision(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def provision(attrs),
    do:
      Platform.SuperAgents.provision(
        @role,
        Platform.Responsibilities.Handlers.DoctorCheckup,
        attrs
      )

  @doc "Hours a restarted agent must stay up before the doctor restarts it again."
  @spec restart_backoff_hours() :: pos_integer()
  def restart_backoff_hours, do: @restart_backoff_hours

  @doc """
  Reads install health. Each section is read on its own and a section that
  raises reads as empty (logged), so one broken probe never hides the rest.
  `opts[:now]` fixes the clock (tests).
  """
  @spec checkup(keyword()) :: checkup()
  def checkup(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    blocked = section(:blocked_leases, fn -> blocked_leases() end, [])

    %{
      agents: section(:agents, fn -> unwell_agents() end, []),
      dependency_waits: Enum.filter(blocked, &(&1.wait_kind == "dependency")),
      human_waits: Enum.filter(blocked, &(&1.wait_kind == "human")),
      expired_leases: section(:expired_leases, fn -> expired_leases(now) end, []),
      unreachable_responsibilities:
        section(:responsibilities, fn -> unreachable_responsibilities() end, []),
      update_held?: section(:updates, fn -> update_held?() end, false),
      agent_host: section(:agent_host, fn -> agent_host() end, :ok)
    }
  end

  @doc "True when the checkup found nothing at all."
  @spec healthy?(checkup()) :: boolean()
  def healthy?(checkup) do
    checkup.agents == [] and checkup.dependency_waits == [] and checkup.human_waits == [] and
      checkup.expired_leases == [] and checkup.unreachable_responsibilities == [] and
      not checkup.update_held? and checkup.agent_host != :not_connected
  end

  @doc """
  Runs the safe heals over `checkup`, as `actor_id` (the doctor agent).
  Returns `%{healed: [String.t()], escalations: [escalation()]}`: one line per
  heal that went through, and every finding a human must decide, including a
  heal that was refused or failed. `opts[:restart]` and `opts[:reassess]`
  replace the two heal functions (tests); `opts[:now]` fixes the clock.
  """
  @spec heal(checkup(), String.t() | nil, keyword()) :: %{
          healed: [String.t()],
          escalations: [escalation()]
        }
  def heal(checkup, actor_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    restart = Keyword.get(opts, :restart, &AgentHost.restart_agent/1)
    reassess = Keyword.get(opts, :reassess, &BlockerReassessment.reassess/1)

    agent_results = Enum.map(checkup.agents, &heal_agent(&1, actor_id, restart, now))

    wait_results =
      checkup.dependency_waits
      |> Enum.uniq_by(& &1.task_id)
      |> Enum.map(&heal_wait(&1, actor_id, reassess))

    results = agent_results ++ wait_results

    %{
      healed: for({:healed, line} <- results, do: line),
      escalations:
        for({:escalate, escalation} <- results, do: escalation) ++ standing_escalations(checkup)
    }
  end

  @doc "The checkup and heal results as prompt text, one finding per line."
  @spec render(checkup(), %{healed: [String.t()], escalations: [escalation()]}) :: String.t()
  def render(checkup, %{healed: healed, escalations: escalations}) do
    [
      {"Healed this run", healed},
      {"Escalated to the human this run", Enum.map(escalations, & &1.question)},
      {"Unwell agents",
       Enum.map(checkup.agents, fn a ->
         "#{a.name} (#{a.agent_id}): #{a.state}, meant to be #{a.desired_state || "unknown"}" <>
           detail_suffix(a.detail)
       end)},
      {"Dependency waits", Enum.map(checkup.dependency_waits, &lease_line/1)},
      {"Human waits", Enum.map(checkup.human_waits, &lease_line/1)},
      {"Active leases past expiry", Enum.map(checkup.expired_leases, &lease_line/1)},
      {"Responsibilities that cannot reach their assignee",
       Enum.map(checkup.unreachable_responsibilities, fn r ->
         "#{r.key}: #{r.class} (assignee #{r.assignee_slug || r.assignee_id || "unknown"})"
       end)},
      {"Updates",
       if(checkup.update_held?, do: ["a release is held (held_irreversible)"], else: [])},
      {"Agent host",
       if(checkup.agent_host == :not_connected, do: ["configured but not connected"], else: [])}
    ]
    |> Enum.map_join("\n\n", fn {heading, lines} ->
      body = if lines == [], do: "- none", else: Enum.map_join(lines, "\n", &"- #{&1}")
      "### #{heading}\n#{body}"
    end)
  end

  # ── checkup sections ──

  defp section(name, fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.warning("[doctor] checkup section #{name} raised: #{Exception.message(error)}")
      fallback
  end

  defp unwell_agents do
    for %{agent: agent, runtime: runtime} <- NativeAgents.list(),
        %{state: state} = status <- [AgentHost.status(agent)],
        state in [:crashed, :needs_login] do
      %{
        agent_id: agent.id,
        name: agent.name,
        state: state,
        desired_state: runtime.desired_state,
        detail: Map.get(status, :detail)
      }
    end
    |> Enum.take(@list_cap)
  end

  defp blocked_leases do
    from(l in ExecutionLease,
      where: l.status == "blocked",
      order_by: [asc: l.updated_at],
      limit: @list_cap
    )
    |> Repo.all()
    |> Enum.map(fn lease -> lease |> lease_map() |> Map.put(:wait_kind, wait_kind(lease)) end)
  end

  defp wait_kind(lease), do: ExecutionLease.wait_kind(lease)

  defp expired_leases(now) do
    from(l in ExecutionLease,
      where: l.status == "active" and not is_nil(l.expires_at) and l.expires_at < ^now,
      order_by: [asc: l.expires_at],
      limit: @list_cap
    )
    |> Repo.all()
    |> Enum.map(&lease_map/1)
  end

  defp lease_map(lease) do
    %{
      lease_id: lease.id,
      task_id: lease.task_id,
      stage_id: lease.stage_id,
      phase: lease.phase,
      block_reason: lease.block_reason,
      since: lease.updated_at
    }
  end

  defp unreachable_responsibilities do
    Reachability.report()
    |> Enum.filter(&(&1.class in @unreachable_classes and not &1.declared_inert?))
    |> Enum.map(&Map.take(&1, [:key, :class, :assignee_slug, :assignee_id, :runtime_id]))
    |> Enum.take(@list_cap)
  end

  # `Updates.status/0` is `:not_installed` on an install without the updater.
  defp update_held?, do: match?(%{last_result: "held_irreversible"}, Updates.status())

  defp agent_host do
    cond do
      not AgentHost.configured?() -> :not_configured
      AgentHost.connected?() -> :ok
      true -> :not_connected
    end
  end

  # ── heals ──

  defp heal_agent(%{state: :needs_login} = agent, _actor_id, _restart, _now) do
    {:escalate,
     %{
       question: "#{agent.name} needs a login",
       detail:
         "The agent host reports #{agent.name} (#{agent.agent_id}) as needs_login, so it " <>
           "cannot reply or take work. Log it in from its agent page. The doctor cannot: a " <>
           "login needs a person's credential."
     }}
  end

  defp heal_agent(%{state: :crashed, desired_state: "running"} = agent, actor_id, restart, now) do
    if restarted_recently?(agent.agent_id, now) do
      {:escalate,
       %{
         question: "#{agent.name} keeps crashing",
         detail:
           "The doctor restarted #{agent.name} (#{agent.agent_id}) in the last " <>
             "#{@restart_backoff_hours} hours and it has crashed again. It will not restart " <>
             "it again inside that window. Read its logs from its agent page and decide." <>
             detail_suffix(agent.detail)
       }}
    else
      result = safe_call(fn -> restart.(Repo.get(Platform.Agents.Agent, agent.agent_id)) end)
      audit("restart_agent", agent.agent_id, actor_id, result)

      case result do
        :ok ->
          {:healed, "restarted #{agent.name} (#{agent.agent_id}) after a crash"}

        {:error, reason} ->
          {:escalate,
           %{
             question: "#{agent.name} crashed and could not be restarted",
             detail:
               "The doctor tried to restart #{agent.name} (#{agent.agent_id}) and the restart " <>
                 "failed: #{inspect(reason)}."
           }}
      end
    end
  end

  # Crashed but meant to be stopped: nothing to heal, and nothing to ask.
  defp heal_agent(_agent, _actor_id, _restart, _now), do: :noop

  defp heal_wait(%{task_id: task_id}, actor_id, reassess) do
    result = safe_call(fn -> reassess.(task_id) end)
    audit("reassess_dependency_wait", task_id, actor_id, result)

    # `reassess/1` is due-gated and budgeted on its own: a wait that is not due
    # is left alone, and only a wait whose budget is spent needs a person.
    case result do
      {:ok, results} when is_list(results) ->
        cond do
          Enum.any?(results, &match?({:requested, _}, &1)) ->
            {:healed,
             "asked the owning runtime to re-verify the dependency wait on task #{task_id}"}

          Enum.any?(results, &(&1 == :exhausted)) ->
            {:escalate,
             %{
               question: "Task #{task_id} is stuck on a dependency that never verified",
               detail:
                 "Its dependency wait spent its verification budget. Check whether the " <>
                   "dependency really shipped, then unblock or re-plan the task."
             }}

          true ->
            :noop
        end

      _ ->
        :noop
    end
  end

  defp standing_escalations(checkup) do
    held =
      if checkup.update_held? do
        [
          %{
            question: "A release is held because it cannot be rolled back",
            detail:
              "The updater stopped at held_irreversible. Open Admin, then Updates, and decide " <>
                "whether this release goes out. The doctor never releases a held update."
          }
        ]
      else
        []
      end

    host =
      case checkup.agent_host do
        :not_connected ->
          [
            %{
              question: "The agent host is not connected",
              detail:
                "Native agents cannot be started, restarted or logged in until the agent host " <>
                  "reconnects. Check the agent-host service on this install's machine."
            }
          ]

        _ ->
          []
      end

    held ++ host
  end

  defp restarted_recently?(agent_id, now) do
    since = DateTime.add(now, -@restart_backoff_hours * 3600, :second)

    Repo.exists?(
      from(e in Audit.Event,
        where:
          e.event_type == ^@heal_event and e.action == "restart_agent" and
            e.resource_id == ^agent_id and e.inserted_at >= ^since
      )
    )
  rescue
    _ -> false
  end

  defp audit(action, resource_id, actor_id, result) do
    Audit.record(%{
      event_type: @heal_event,
      action: action,
      actor_type: "agent",
      actor_id: if(is_binary(actor_id) and Platform.UUID.valid?(actor_id), do: actor_id),
      resource_type: if(action == "restart_agent", do: "agent", else: "task"),
      resource_id: resource_id,
      metadata: %{"result" => result_label(result)}
    })
  rescue
    error -> Logger.warning("[doctor] heal audit failed: #{Exception.message(error)}")
  end

  defp result_label(:ok), do: "ok"
  defp result_label({:error, reason}), do: "error: " <> String.slice(inspect(reason), 0, 200)
  defp result_label(other), do: String.slice(inspect(other), 0, 200)

  defp safe_call(fun) do
    case fun.() do
      :ok -> :ok
      {:error, _} = error -> error
      other -> other
    end
  rescue
    error -> {:error, {:raised, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp lease_line(lease) do
    "task #{lease.task_id} (#{lease.phase || "?"}), since #{lease.since}" <>
      case lease.block_reason do
        reason when is_binary(reason) and reason != "" -> ": " <> String.slice(reason, 0, 160)
        _ -> ""
      end
  end

  defp detail_suffix(detail) when is_binary(detail) and detail != "", do: " (#{detail})"
  defp detail_suffix(_), do: ""
end
