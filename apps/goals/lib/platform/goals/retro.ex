defmodule Platform.Goals.Retro do
  @moduledoc "Retro rules and the hoped-for line (Goals 8/8, task 01a1dfc2-0d97)."
  import Ecto.Query
  alias Platform.{Goals, Repo}

  alias Platform.Goals.{
    Ask,
    AskAnswer,
    Clock,
    Entry,
    GoalClock,
    Limits,
    Reading,
    Stop,
    Visibility,
    WakeUp
  }

  @final ~w(came_true did_not not_scored cannot_measure)

  def effective_every(goal), do: goal.retro_every || Limits.retro_every(goal.rhythm)

  # Planner ruling: existing undated predictions are finalized without a number.
  def verdict(%{predicted_by: nil}, _today), do: "not_scored"

  def verdict(row, today) do
    cond do
      Date.after?(row.predicted_by, today) ->
        "too_early"

      is_nil(row.predicted_change) ->
        "not_scored"

      row.actual_change in [nil, :cannot_measure] ->
        "cannot_measure"

      Decimal.compare(row.predicted_change, 0) == :gt ->
        scored(Decimal.compare(row.actual_change, row.predicted_change) != :lt)

      Decimal.compare(row.predicted_change, 0) == :lt ->
        scored(Decimal.compare(row.actual_change, row.predicted_change) != :gt)

      true ->
        scored(Decimal.equal?(row.actual_change, 0))
    end
  end

  defp scored(true), do: "came_true"
  defp scored(false), do: "did_not"

  def predictions(actor, goal_id, now) do
    with {:ok, goal} <- Goals.get_goal(actor, goal_id),
         :ok <- can_edit(actor, goal) do
      {:ok, prediction_rows(actor, goal, now)}
    end
  end

  defp prediction_rows(actor, goal, now) do
    final_ids =
      Repo.all(
        from(e in rows(actor, Entry, goal.id), where: e.kind == "retro", select: e.details)
      )
      |> Enum.flat_map(&Map.get(&1, "verdicts", []))
      |> Enum.filter(&(&1["verdict"] in @final))
      |> MapSet.new(& &1["entry_id"])

    Repo.all(
      from(e in rows(actor, Entry, goal.id),
        where: e.kind in ["action", "ask", "wait"] and not is_nil(e.prediction),
        order_by: [asc: e.occurred_at, asc: e.inserted_at, asc: e.id]
      )
    )
    |> Enum.reject(&MapSet.member?(final_ids, &1.id))
    |> Enum.take(Limits.max_retro_predictions())
    |> Enum.map(fn entry ->
      today = local_date(actor, goal, now)

      preliminary =
        verdict(
          %{
            predicted_by: entry.predicted_by,
            predicted_change: entry.predicted_change,
            actual_change: nil
          },
          today
        )

      actual =
        if preliminary in ["too_early", "not_scored"],
          do: nil,
          else: actual_change(actor, goal, entry, now)

      result =
        verdict(
          %{
            predicted_by: entry.predicted_by,
            predicted_change: entry.predicted_change,
            actual_change: actual
          },
          today
        )

      %{
        "entry_id" => entry.id,
        "kind" => entry.kind,
        "title" => entry.title,
        "prediction" => entry.prediction,
        "predicted_change" => decimal(entry.predicted_change),
        "predicted_by" => if(entry.predicted_by, do: Date.to_iso8601(entry.predicted_by)),
        "verdict" => result,
        "actual_change" => if(result in ["came_true", "did_not"], do: decimal(actual))
      }
    end)
  end

  defp actual_change(actor, goal, entry, now) do
    reading =
      if entry.reading_id,
        do: Repo.one(from(r in rows(actor, Reading, goal.id), where: r.id == ^entry.reading_id))

    if reading do
      zone = zone(actor, goal)
      # Start of the next local day minus one microsecond handles DST boundaries.
      {:ok, next_day} = DateTime.new(Date.add(entry.predicted_by, 1), ~T[00:00:00], zone)
      deadline = DateTime.add(next_day, -1, :microsecond)
      cutoff = if DateTime.after?(deadline, now), do: now, else: deadline

      case Goals.goal_number(actor, goal.id, since: reading.measured_at, as_of: cutoff) do
        {:ok, {:reading, %{change_since: change}}} when not is_nil(change) -> change
        _ -> :cannot_measure
      end
    else
      :cannot_measure
    end
  end

  def window(actor, goal_id, now) do
    with {:ok, goal} <- Goals.get_goal(actor, goal_id),
         :ok <- can_edit(actor, goal),
         {:ok, predictions} <- predictions(actor, goal_id, now) do
      retros =
        Repo.all(
          from(w in rows(actor, WakeUp, goal.id),
            where:
              w.kind == "retro" and w.status in ["closed", "unanswered"] and w.fired_at < ^now,
            order_by: [desc: w.fired_at, desc: w.id]
          )
        )

      prior_reading =
        Repo.one(
          from(w in rows(actor, WakeUp, goal.id),
            join: r in subquery(rows(actor, Reading, goal.id)),
            on: r.id == w.reading_id,
            where:
              w.kind == "retro" and w.status in ["closed", "unanswered"] and w.fired_at < ^now,
            order_by: [desc: w.fired_at, desc: w.id],
            limit: 1,
            select: r
          )
        )

      number = Goals.goal_number(actor, goal.id)

      since =
        case {prior_reading, number} do
          {%Reading{} = r, _} -> r.measured_at
          {nil, {:ok, {:reading, n}}} -> n.first.measured_at
          _ -> nil
        end

      change =
        if since do
          case Goals.goal_number(actor, goal.id, since: since) do
            {:ok, {:reading, n}} -> n.change_since
            _ -> nil
          end
        end

      flat =
        not is_nil(change) and Decimal.compare(Decimal.abs(change), Limits.flat_within()) != :gt

      flat_retros =
        if flat,
          do:
            1 + length(Enum.take_while(retros, &(get_in(&1.briefing, ["retro", "flat"]) == true))),
          else: 0

      answers = answer_counts(actor, goal, since)

      {:ok,
       %{
         since: since,
         change: change,
         flat: flat,
         flat_retros: flat_retros,
         goal_change_required: flat_retros >= Limits.flat_retros_before_goal_change(),
         predictions: predictions,
         answers: answers
       }}
    end
  end

  defp answer_counts(_actor, _goal, nil), do: %{used: 0, declined: 0, ignored: 0}

  defp answer_counts(actor, goal, since) do
    counts =
      Repo.all(
        from(g in subquery(Visibility.visible_goals(actor)),
          join: a in Ask,
          on: a.goal_id == g.id,
          join: answer in AskAnswer,
          on: answer.ask_id == a.id,
          where: g.id == ^goal.id and answer.answered_at >= ^since,
          group_by: answer.answer,
          select: {answer.answer, count(answer.id)}
        )
      )
      |> Map.new()

    %{
      used: Map.get(counts, "used", 0),
      declined: Map.get(counts, "declined", 0),
      ignored: Map.get(counts, "ignored", 0)
    }
  end

  def expected_pace(actor, goal, opts) do
    case Goals.goal_number(actor, goal.id) do
      {:ok, {:reading, number}} ->
        stops = Repo.all(from(s in rows(actor, Stop, goal.id), order_by: [asc: s.position]))
        current = Enum.find(stops, &is_nil(&1.reached_on))

        start =
          if current do
            previous =
              stops
              |> Enum.filter(
                &(&1.position < current.position and not is_nil(&1.reached_on) and
                    not is_nil(&1.target_value))
              )
              |> List.last()

            if previous,
              do: {previous.reached_on, previous.target_value},
              else: {local_date(actor, goal, number.first.measured_at), number.first.value}
          end

        {:ok,
         pace(
           current,
           start,
           number.latest.value,
           goal.unit,
           Keyword.get_lazy(opts, :today, fn -> local_date(actor, goal, Clock.now()) end)
         )}

      {:ok, {:cannot_measure, _}} ->
        {:ok, nil}

      error ->
        error
    end
  end

  defp pace(nil, _, _, _, _), do: nil
  defp pace(%{target_value: nil}, _, _, _, _), do: nil
  defp pace(%{due_on: nil}, _, _, _, _), do: nil
  defp pace(_, nil, _, _, _), do: nil

  defp pace(stop, {start_date, start}, value, unit, today) do
    total = Date.diff(stop.due_on, start_date)

    if total > 0 do
      elapsed = today |> Date.diff(start_date) |> max(0) |> min(total)
      distance = Decimal.sub(stop.target_value, start)

      places =
        if Decimal.equal?(Decimal.round(stop.target_value, 0), stop.target_value), do: 0, else: 2

      hoped =
        start
        |> Decimal.add(Decimal.div(Decimal.mult(distance, elapsed), total))
        |> Decimal.round(places)

      tolerance =
        distance
        |> Decimal.abs()
        |> Decimal.mult(Limits.on_track_tolerance_percent())
        |> Decimal.div(100)

      on_track =
        if Decimal.compare(distance, 0) != :lt,
          do: Decimal.compare(value, Decimal.sub(hoped, tolerance)) != :lt,
          else: Decimal.compare(value, Decimal.add(hoped, tolerance)) != :gt

      %{
        state: if(on_track, do: :on_track, else: :behind),
        hoped: hoped,
        value: value,
        unit: unit,
        due_on: stop.due_on,
        stop_label: stop.label
      }
    end
  end

  defp can_edit(%Platform.Accounts.User{id: id}, %{owner_user_id: id}), do: :ok
  defp can_edit(%Platform.Agents.Agent{id: id}, %{coach_agent_id: id}), do: :ok
  defp can_edit(_, _), do: {:error, :forbidden}

  defp rows(actor, schema, goal_id),
    do:
      from(g in subquery(Visibility.visible_goals(actor)),
        join: row in ^schema,
        on: row.goal_id == g.id,
        where: g.id == ^goal_id,
        select: row
      )

  defp zone(actor, goal),
    do:
      Repo.one(from(c in rows(actor, GoalClock, goal.id), select: c.time_zone)) ||
        Application.get_env(:goals, :default_time_zone, "Etc/UTC")

  defp local_date(actor, goal, now),
    do: now |> DateTime.shift_zone!(zone(actor, goal)) |> DateTime.to_date()

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: Decimal.to_string(value, :normal)
end
