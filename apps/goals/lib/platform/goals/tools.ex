defmodule Platform.Goals.Tools do
  @moduledoc """
  Behaviour of the `goals` bundle's tools (task 01a1dfc1-05b0, Goals 3/8
  stage 4); definitions in `Platform.Goals.ToolDefinitions`. Core dispatches
  here through the extension fallback in `ToolSurface.execute/3`.

  A thin layer over `Platform.Goals`: every read and write is a context call
  with the calling agent as the actor, and this module holds no query on a
  goal table. It adds one rule of its own: every tool is for the goal's
  coach only. A goal that does not exist, an id that is not a UUID, a goal
  the agent cannot see, and a goal the agent sees but does not coach all
  answer the same `not_found` envelope (`coached_goal/3`).

  Checks run in one order for every tool: the switch, the agent (from the
  context, never from arguments), the tool name, the coach rule, then the
  context call. Refusals are envelopes `%{error, code, recoverable,
  suggestion}`.
  """

  import Ecto.Query, only: [from: 2]

  alias Platform.Agents.Agent
  alias Platform.Goals
  alias Platform.Goals.ToolDefinitions
  alias Platform.Repo

  @outcomes %{"goal_do" => "do", "goal_ask" => "ask", "goal_wait" => "wait"}

  @do_keys ~w(title body prediction predicted_by predicted_change sources undo_note task)
  @ask_keys ~w(kind title body payload prediction predicted_by predicted_change addressed_user_ids)
  @wait_keys ~w(reason until prediction predicted_by predicted_change)

  @spec execute(String.t(), map(), map()) :: {:ok, map()} | {:error, map()}
  def execute(tool, args, context) do
    args = if is_map(args), do: args, else: %{}
    context = if is_map(context), do: context, else: %{}

    with :ok <- check_enabled(),
         {:ok, agent} <- fetch_agent(context),
         :ok <- check_tool(tool) do
      run(tool, args, agent)
    end
  end

  defp check_enabled, do: if(Goals.enabled?(), do: :ok, else: {:error, disabled()})

  defp fetch_agent(context) do
    case agent(context) do
      %Agent{} = agent -> {:ok, agent}
      _ -> {:error, no_agent()}
    end
  end

  defp check_tool(tool) do
    if tool in ToolDefinitions.names(), do: :ok, else: {:error, unknown_tool(tool)}
  end

  # ── The agent ────────────────────────────────────────────────────────

  defp agent(%{agent: %Agent{} = agent}), do: agent

  defp agent(%{agent_id: id}) when is_binary(id) do
    if Platform.UUID.valid?(id), do: Repo.one(from(a in Agent, where: a.id == ^id))
  end

  defp agent(_), do: nil

  # ── The coach rule ───────────────────────────────────────────────────

  # The ONE place the coach rule lives. Missing, malformed, unseen and
  # seen-but-not-coached all return the identical `not_found` envelope.
  defp coached_goal(agent, :goal, goal_id) do
    case Goals.get_goal(agent, goal_id) do
      {:ok, goal} ->
        if goal.coach_agent_id == agent.id, do: {:ok, goal}, else: {:error, goal_not_found()}

      {:error, :goals_disabled} ->
        {:error, disabled()}

      {:error, _} ->
        {:error, goal_not_found()}
    end
  end

  defp coached_goal(agent, :wake_up, wake_up_id) do
    case Goals.get_wake_up(agent, wake_up_id) do
      {:ok, %{wake_up: wake} = read} ->
        with {:ok, goal} <- coached_goal(agent, :goal, wake.goal_id), do: {:ok, goal, read}

      {:error, :goals_disabled} ->
        {:error, disabled()}

      {:error, _} ->
        {:error, goal_not_found()}
    end
  end

  # ── Tools ────────────────────────────────────────────────────────────

  defp run("goal_list", _args, agent) do
    case Goals.list_goals(agent) do
      {:ok, goals} ->
        rows =
          goals
          |> Enum.filter(&(&1.coach_agent_id == agent.id))
          |> Enum.map(&list_row(agent, &1))

        {:ok, %{goals: rows, total: length(rows)}}

      {:error, reason} ->
        {:error, context_error(reason)}
    end
  end

  defp run("goal_get", args, agent) do
    with {:ok, goal} <- coached_goal(agent, :goal, args["goal_id"]) do
      entries_limit = bounded(args["entries_limit"], 20, 50)
      readings_limit = bounded(args["readings_limit"], 10, 50)

      with {:ok, stops} <- Goals.list_stops(agent, goal.id),
           {:ok, entries} <- Goals.list_entries(agent, goal.id, limit: entries_limit),
           {:ok, readings} <- Goals.list_readings(agent, goal.id, limit: readings_limit),
           {:ok, number} <- Goals.goal_number(agent, goal.id),
           {:ok, asks} <- Goals.list_asks(agent, goal.id, status: "open"),
           {:ok, tasks} <- Goals.list_goal_tasks(agent, goal.id),
           {:ok, clock} <- Goals.clock_status(agent, goal.id) do
        {status, number_json} = number_json(number)

        {:ok,
         %{
           goal: goal_json(goal),
           stops: Enum.map(stops, &stop_json/1),
           entries: Enum.map(entries, &entry_json/1),
           readings: Enum.map(readings, &reading_json/1),
           number_status: status,
           number: number_json,
           asks: Enum.map(asks, &ask_json/1),
           tasks: Enum.map(tasks, &task_link_json/1),
           clock: clock_json(clock)
         }}
      else
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp run("goal_wake_up_get", %{"wake_up_id" => id}, agent) when not is_nil(id) do
    with {:ok, goal, read} <- coached_goal(agent, :wake_up, id) do
      {:ok, wake_up_read_json(agent, goal, read)}
    end
  end

  defp run("goal_wake_up_get", args, agent) do
    with {:ok, goal} <- coached_goal(agent, :goal, args["goal_id"]) do
      case Goals.list_wake_ups(agent, goal.id, status: "open", limit: 1) do
        {:ok, [wake | _]} ->
          case Goals.get_wake_up(agent, wake.id) do
            {:ok, read} -> {:ok, wake_up_read_json(agent, goal, read)}
            {:error, reason} -> {:error, context_error(reason)}
          end

        {:ok, []} ->
          {:error,
           err(
             :no_open_wake_up,
             "This goal has no open wake-up.",
             true,
             "Wait for the next check-in; goal_list shows next_wake_at."
           )}

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  defp run(tool, args, agent) when is_map_key(@outcomes, tool) do
    with {:ok, _goal, %{wake_up: wake}} <- coached_goal(agent, :wake_up, args["wake_up_id"]) do
      attrs = Map.take(args, keys(tool))

      case Goals.close_wake_up(agent, wake.id, Map.fetch!(@outcomes, tool), attrs) do
        {:ok, result} -> {:ok, closed_json(result)}
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp keys("goal_do"), do: @do_keys
  defp keys("goal_ask"), do: @ask_keys
  defp keys("goal_wait"), do: @wait_keys

  defp bounded(value, _default, cap) when is_integer(value), do: value |> max(0) |> min(cap)

  defp bounded(value, default, cap) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> bounded(n, default, cap)
      _ -> default
    end
  end

  defp bounded(_value, default, _cap), do: default

  # ── allowed ──────────────────────────────────────────────────────────

  # The refusal `close_wake_up/4` would give now for each choice, in the
  # order it checks them. Per-call checks (prediction, reason, project,
  # addressees) depend on arguments and are not predicted here.
  defp allowed(agent, goal, wake) do
    if wake.status != "open" do
      Map.new(~w(do do_with_task ask wait), &{&1, :wake_up_closed})
    else
      %{
        "do" => if(goal.agent_mode == "advise", do: :mode_forbids_do, else: true),
        "do_with_task" => do_with_task(agent, goal),
        "ask" => ask_allowed(agent, goal),
        "wait" => true
      }
    end
  end

  defp do_with_task(agent, goal) do
    case goal.agent_mode do
      "advise" ->
        :mode_forbids_do

      "coach" ->
        :mode_forbids_task

      _ ->
        case Goals.list_goal_tasks(agent, goal.id, limit: 200) do
          {:ok, tasks} ->
            if Enum.count(tasks, & &1.open) < Goals.Limits.max_open_tasks(),
              do: true,
              else: :task_cap_reached

          {:error, reason} ->
            reason
        end
    end
  end

  defp ask_allowed(_agent, %{outreach: "off"}), do: :outreach_off

  defp ask_allowed(agent, goal) do
    now = Goals.Clock.now()

    case Goals.list_asks(agent, goal.id, status: "open", limit: 200) do
      {:ok, asks} ->
        open = Enum.count(asks, &(DateTime.compare(&1.expires_at, now) == :gt))

        if open < Goals.Limits.max_open_asks(goal.outreach), do: true, else: :ask_cap_reached

      {:error, reason} ->
        reason
    end
  end

  # ── Refusals ─────────────────────────────────────────────────────────

  @refusals %{
    wake_up_closed:
      {"This wake-up is already closed or was marked unanswered; a wake-up takes one outcome.",
       false, "Wait for the next wake-up; goal_wake_up_get with goal_id finds an open one."},
    mode_forbids_do:
      {"This goal is advise-only: close with goal_ask or goal_wait.", true,
       "Close this wake-up with goal_ask or goal_wait."},
    mode_forbids_task:
      {"This goal is in coach mode: goal_do may not create a task.", true,
       "Call goal_do without task, or close with goal_ask or goal_wait."},
    outreach_off:
      {"Outreach is off for this goal: it takes no asks.", true,
       "Close this wake-up with goal_do or goal_wait."},
    ask_cap_reached:
      {"This goal already has as many open asks as its outreach allows.", true,
       "Close this wake-up with goal_do or goal_wait; an answer or expiry frees a slot."},
    task_cap_reached:
      {"This goal already has as many open tagged tasks as allowed.", true,
       "Call goal_do without task, or close with goal_wait until a task closes."},
    project_not_available:
      {"That project is not available for this goal's tasks.", true,
       "Pick a live project in the goal's org, or call goal_do without task."},
    addressee_cannot_see_goal:
      {"Every addressed person must be able to see this goal.", true,
       "Omit addressed_user_ids to ask the goal's owner."},
    prediction_required:
      {"A prediction and a predicted_by date after today are required.", true,
       "Send prediction and predicted_by (YYYY-MM-DD, after today)."},
    reason_required: {"goal_wait needs a reason.", true, "Send reason: why nothing is due now."},
    task_already_linked:
      {"That task is already tagged to a goal.", true, "Create a new task instead."},
    unknown_outcome: {"Unknown outcome.", false, "Use goal_do, goal_ask or goal_wait."}
  }

  defp context_error(:goals_disabled), do: disabled()
  defp context_error(reason) when reason in [:not_found, :forbidden], do: goal_not_found()

  defp context_error(%Ecto.Changeset{} = changeset) do
    messages =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string_safe(value))
        end)
      end)

    err(
      :invalid,
      "Invalid arguments: " <> inspect(messages),
      true,
      "Fix the named fields and call again; nothing was written."
    )
    |> Map.put(:messages, messages)
  end

  defp context_error(reason) when is_map_key(@refusals, reason) do
    {error, recoverable, suggestion} = Map.fetch!(@refusals, reason)
    err(reason, error, recoverable, suggestion)
  end

  defp context_error(reason) do
    err(:invalid, "Refused: #{inspect(reason)}", false, "goal_list shows the goals you coach.")
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: inspect(value)

  defp disabled do
    err(
      :goals_disabled,
      "Goals is not switched on for this install.",
      false,
      "Goals tools work only where an admin set GOALS_ENABLED."
    )
  end

  defp no_agent do
    err(
      :no_agent,
      "No calling agent: goals tools need an agent.",
      false,
      "Call through an agent runtime's MCP connection."
    )
  end

  defp goal_not_found do
    err(:not_found, "No such goal.", false, "goal_list shows the goals you coach.")
  end

  defp unknown_tool(tool) do
    err(
      :unknown_tool,
      "Unknown tool: #{tool}.",
      false,
      "The goals tools are #{Enum.join(ToolDefinitions.names(), ", ")}."
    )
  end

  defp err(code, error, recoverable, suggestion),
    do: %{error: error, code: code, recoverable: recoverable, suggestion: suggestion}

  # ── JSON ─────────────────────────────────────────────────────────────

  defp list_row(agent, goal) do
    clock =
      case Goals.clock_status(agent, goal.id) do
        {:ok, clock} -> clock
        _ -> nil
      end

    open =
      case Goals.list_wake_ups(agent, goal.id, status: "open", limit: 1) do
        {:ok, [wake | _]} -> wake.id
        _ -> nil
      end

    %{
      id: goal.id,
      title: goal.title,
      status: goal.status,
      agent_mode: goal.agent_mode,
      rhythm: goal.rhythm,
      outreach: goal.outreach,
      next_wake_at: clock && time(clock.next_wake_at),
      stalled: not is_nil(clock && clock.stalled_at),
      open_wake_up_id: open
    }
  end

  defp goal_json(goal) do
    %{
      id: goal.id,
      title: goal.title,
      why: goal.why,
      kind: goal.kind,
      status: goal.status,
      unit: goal.unit,
      target_value: dec(goal.target_value),
      source_key: goal.source_key,
      source_settings: goal.source_settings,
      agent_mode: goal.agent_mode,
      rhythm: goal.rhythm,
      rhythm_weekday: goal.rhythm_weekday,
      outreach: goal.outreach,
      owner_user_id: goal.owner_user_id,
      coach_agent_id: goal.coach_agent_id
    }
  end

  defp stop_json(stop) do
    %{
      id: stop.id,
      position: stop.position,
      label: stop.label,
      target_value: dec(stop.target_value),
      due_on: date(stop.due_on),
      caption: stop.caption,
      theme: stop.theme,
      criteria: stop.criteria,
      reached_on: date(stop.reached_on)
    }
  end

  defp entry_json(entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      title: entry.title,
      body: entry.body,
      occurred_at: time(entry.occurred_at),
      author_type: entry.author_type,
      prediction: entry.prediction,
      predicted_change: dec(entry.predicted_change),
      predicted_by: date(entry.predicted_by),
      sources: entry.sources,
      details: entry.details,
      reading_id: entry.reading_id
    }
  end

  defp reading_json(nil), do: nil

  defp reading_json(reading) do
    %{
      id: reading.id,
      value: dec(reading.value),
      unit: reading.unit,
      source_key: reading.source_key,
      population: reading.population,
      origin: reading.origin,
      measured_at: time(reading.measured_at),
      note: reading.note
    }
  end

  # A cannot-measure result keeps exactly its three keys and never a value.
  defp number_json({:cannot_measure, %{reason: reason, source_key: key, source_label: label}}),
    do: {"cannot_measure", %{reason: reason, source_key: key, source_label: label}}

  defp number_json({:reading, number}) do
    {"reading",
     %{
       source: number.source,
       latest: reading_json(number.latest),
       previous: reading_json(number.previous),
       delta: dec(number.delta),
       baseline: reading_json(number.baseline),
       change_since: dec(number.change_since)
     }}
  end

  defp ask_json(nil), do: nil

  defp ask_json(ask) do
    answers =
      case ask.answers do
        answers when is_list(answers) ->
          Enum.map(answers, fn a ->
            %{
              user_id: a.user_id,
              answer: a.answer,
              details: a.details,
              answered_at: time(a.answered_at)
            }
          end)

        _ ->
          []
      end

    %{
      id: ask.id,
      kind: ask.kind,
      title: ask.title,
      body: ask.body,
      payload: ask.payload,
      addressed_user_ids: ask.addressed_user_ids,
      status: ask.status,
      expires_at: time(ask.expires_at),
      wake_up_id: ask.wake_up_id,
      entry_id: ask.entry_id,
      answers: answers
    }
  end

  defp task_link_json(link) do
    %{
      task_id: link.task_id,
      title: link.title,
      status: link.status,
      open: link.open,
      wake_up_id: link.wake_up_id,
      linked_at: time(link.linked_at)
    }
  end

  defp clock_json(nil), do: nil

  defp clock_json(clock) do
    %{
      next_wake_at: time(clock.next_wake_at),
      time_zone: clock.time_zone,
      wake_hour: clock.wake_hour,
      last_woken_at: time(clock.last_woken_at),
      stalled_at: time(clock.stalled_at),
      stalled: not is_nil(clock.stalled_at)
    }
  end

  defp wake_up_json(wake) do
    %{
      id: wake.id,
      goal_id: wake.goal_id,
      kind: wake.kind,
      status: wake.status,
      outcome: wake.outcome,
      due_at: time(wake.due_at),
      fired_at: time(wake.fired_at),
      respond_by: time(wake.respond_by),
      closed_at: time(wake.closed_at),
      entry_id: wake.entry_id,
      reading_id: wake.reading_id
    }
  end

  defp wake_up_read_json(agent, goal, %{wake_up: wake, briefing: briefing, text: text}) do
    %{
      wake_up: wake_up_json(wake),
      briefing: briefing,
      text: text,
      allowed: allowed(agent, goal, wake)
    }
  end

  defp closed_json(%{wake_up: wake, entry: entry, ask: ask, task: task}) do
    %{
      wake_up: wake_up_json(wake),
      entry: entry_json(entry),
      ask: ask_json(ask),
      task: task && %{id: task.id, title: task.title, status: task.status}
    }
  end

  defp dec(nil), do: nil
  defp dec(%Decimal{} = d), do: Decimal.to_string(d)
  defp dec(other), do: other

  defp date(nil), do: nil
  defp date(%Date{} = d), do: Date.to_iso8601(d)

  defp time(nil), do: nil
  defp time(%DateTime{} = t), do: DateTime.to_iso8601(t)
end
