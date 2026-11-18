defmodule Platform.Designer.Loop do
  @moduledoc """
  The deterministic triggers and budget of the super agent loop for the
  designer (task 01a1f048). No model call happens here; this module decides
  WHEN `design.reflect`, `design.prototype_eval` and `design.scout` fire.

  ## Triggers

    * `design.reflect` fires after each design job the designer finishes,
      observed at the tool call that finishes it: `design_critique_complete`
      (a critique returned), `task_attach_canvas` / `task_design_decline`
      (direction delivered or declined). The prototype path reflects after
      its evaluation instead, so the reflection sees the scorecard.
    * `design.prototype_eval` fires when the designer publishes a prototype
      (`prototype_publish`).
    * `design.scout` is a cron row (twice a week); its budget is below.

  Each fires only when the CALLER is the agent the key resolves to
  (`Platform.Roles.assignee_for/1`), so another agent publishing a
  prototype or attaching a canvas never wakes the designer.

  `observe/4` is called from `Platform.Federation.ToolCall.invoke/4` after
  every successful call. A name outside the four above returns at once. The
  rest runs in a supervised task (`config :platform, :designer_loop_mode`:
  `:async` default, `:sync` for tests, `:off`) so a tool call never waits on
  a responsibility dispatch.

  ## Scout budget (spec decision 9)

  The weekly cap is 2x the designer's MEDIAN weekly tokens over the last 8
  complete weeks (`agent_usage_events`, input + output). With fewer than 2
  weeks of history the cap is `config :platform, :designer_scout_weekly_tokens`
  (default #{400_000}). The scout runs only while this week's spend is under
  the cap, and each run is offered at most half the cap.
  """

  import Ecto.Query

  require Logger

  alias Platform.Analytics.UsageEvent
  alias Platform.Repo
  alias Platform.Responsibilities.Router

  @reflect "design.reflect"
  @prototype_eval "design.prototype_eval"
  @job_tools ~w(design_critique_complete task_attach_canvas task_design_decline)
  @history_weeks 8
  @default_weekly_tokens 400_000

  @doc "The tool names that end a design job."
  @spec job_tools() :: [String.t()]
  def job_tools, do: @job_tools

  @doc """
  Observe one successful tool call. Returns `:ignored` for a tool the loop
  does not watch, else whatever the configured mode does (`:ok` async).
  """
  @spec observe(String.t(), map(), map(), term()) :: :ignored | :ok | term()
  def observe(name, args, context, {:ok, result})
      when name in ["prototype_publish" | @job_tools] do
    agent_id = Map.get(context, :agent_id)

    if is_binary(agent_id) do
      run(fn -> fire_for(name, agent_id, args, result) end)
    else
      :ignored
    end
  end

  def observe(_name, _args, _context, _result), do: :ignored

  @doc """
  Fire `design.reflect` for a finished job when `agent_id` holds it.
  `job` names the job; `meta` rides along in the trigger payload.
  """
  @spec job_finished(String.t(), String.t(), map()) :: term()
  def job_finished(agent_id, job, meta \\ %{}) do
    if assignee?(@reflect, agent_id) do
      Router.fire(@reflect, Map.merge(meta, %{kind: :event_topic, job: job, agent_id: agent_id}))
    else
      {:ok, :not_assignee}
    end
  end

  @doc """
  The scout budget for `agent_id` at `now`:
  `%{weekly_cap, spent_this_week, allowance, median_weekly, weeks_of_history}`.
  `allowance` is 0 when this week's spend has reached the cap.
  """
  @spec scout_budget(String.t(), DateTime.t()) :: map()
  def scout_budget(agent_id, now \\ DateTime.utc_now()) when is_binary(agent_id) do
    week_start = week_start(now)
    weekly = weekly_totals(agent_id, week_start)
    history = Enum.reject(weekly, &(&1 == 0))

    {median, cap} =
      if length(history) >= 2 do
        m = median(history)
        {m, 2 * m}
      else
        {nil, default_weekly_tokens()}
      end

    spent = tokens_between(agent_id, week_start, now)

    %{
      weekly_cap: cap,
      spent_this_week: spent,
      allowance: max(min(cap - spent, div(cap, 2)), 0),
      median_weekly: median,
      weeks_of_history: length(history)
    }
  end

  @doc "Median of a non-empty list of integers (the lower middle for an even count)."
  @spec median([integer()]) :: integer()
  def median(values) when is_list(values) and values != [] do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted) - 1, 2))
  end

  # ── internals ──

  defp fire_for("prototype_publish", agent_id, _args, result) do
    prototype_id = fetch(result, :prototype_id)
    version = fetch(result, :version)

    if is_binary(prototype_id) and assignee?(@prototype_eval, agent_id) do
      Router.fire(@prototype_eval, %{
        kind: :event_topic,
        prototype_id: prototype_id,
        version: version,
        agent_id: agent_id
      })
    else
      {:ok, :not_assignee}
    end
  end

  defp fire_for(name, agent_id, args, _result) do
    job_finished(agent_id, name, %{
      task_id: Map.get(args, "task_id"),
      canvas_id: Map.get(args, "canvas_id")
    })
  end

  defp assignee?(key, agent_id) do
    case Platform.Roles.assignee_for(key) do
      %{id: ^agent_id} -> true
      _ -> false
    end
  end

  defp run(fun) do
    case Application.get_env(:platform, :designer_loop_mode, :async) do
      :off ->
        :ignored

      :sync ->
        safe(fun)

      _async ->
        case Task.Supervisor.start_child(Platform.TaskSupervisor, fn -> safe(fun) end) do
          {:ok, _pid} -> :ok
          _ -> :ignored
        end
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    # An `async: true` test (manual sandbox mode) gives this child no
    # connection; the trigger is best-effort and never takes the tool call down.
    DBConnection.OwnershipError ->
      {:error, :sandbox_ownership}

    error ->
      Logger.warning("[designer.loop] trigger raised: #{Exception.message(error)}")
      {:error, :raised}
  catch
    kind, reason ->
      Logger.warning("[designer.loop] trigger #{kind}: #{inspect(reason)}")
      {:error, :raised}
  end

  defp week_start(now) do
    date = DateTime.to_date(now)
    monday = Date.add(date, 1 - Date.day_of_week(date))
    DateTime.new!(monday, ~T[00:00:00], "Etc/UTC")
  end

  defp weekly_totals(agent_id, week_start) do
    Enum.map(1..@history_weeks, fn n ->
      from = DateTime.add(week_start, -7 * n, :day)
      tokens_between(agent_id, from, DateTime.add(from, 7, :day))
    end)
  end

  defp tokens_between(agent_id, from, to) do
    from(e in UsageEvent,
      where: e.agent_id == ^agent_id and e.inserted_at >= ^from and e.inserted_at < ^to,
      select: sum(e.input_tokens + e.output_tokens)
    )
    |> Repo.one()
    |> case do
      nil -> 0
      %Decimal{} = d -> Decimal.to_integer(d)
      n -> n
    end
  end

  defp default_weekly_tokens,
    do: Application.get_env(:platform, :designer_scout_weekly_tokens, @default_weekly_tokens)

  defp fetch(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp fetch(_map, _key), do: nil
end
