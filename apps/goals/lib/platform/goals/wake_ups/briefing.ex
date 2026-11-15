defmodule Platform.Goals.WakeUps.Briefing do
  @moduledoc "Private coach snapshots and content-free runtime signals."
  import Ecto.Query
  alias Platform.Goals
  alias Platform.Goals.{Ask, AskAnswer, GoalClock, Limits, Reading, TaskLink, Visibility, WakeUp}
  alias Platform.Repo

  def wire_prompt(wake_up) do
    "A goal you coach is due for a check-in. Wake-up id: #{wake_up.id}. Read it with goal_wake_up_get, then close it with exactly one of goal_do, goal_ask or goal_wait before #{DateTime.to_iso8601(wake_up.respond_by)}."
  end

  def snapshot(actor, goal, wake_up, {:ok, result}), do: snapshot(actor, goal, wake_up, result)

  def snapshot(actor, goal, wake_up, result) do
    {:ok, stops} = Goals.list_stops(actor, goal.id)

    previous =
      Repo.one(
        from(w in visible(actor, WakeUp, goal.id),
          where: w.kind == "check_in" and w.fired_at < ^wake_up.fired_at,
          order_by: [desc: w.fired_at, desc: w.id],
          limit: 1
        )
      )

    clock = Repo.one(visible(actor, GoalClock, goal.id))

    since =
      if previous, do: previous.fired_at, else: (clock && clock.inserted_at) || goal.inserted_at

    {:ok, entries} = Goals.list_entries(actor, goal.id, limit: Limits.briefing_entries())

    %{
      "goal" =>
        goal
        |> fields(~w(id title why kind status agent_mode rhythm rhythm_weekday outreach unit)a)
        |> Map.put("target_value", scalar(goal.target_value))
        |> Map.put("stops", Enum.map(stops, &fields(&1, ~w(position label due_on reached_on)a))),
      "number" => number(actor, goal, wake_up, result),
      "since_last" => %{
        "previous" => if(previous, do: fields(previous, [:status, :outcome]), else: nil),
        "finished_tasks" => finished_tasks(actor, goal, wake_up),
        "open_tasks" => open_tasks(actor, goal),
        "answers" => answers(actor, goal, since, wake_up.fired_at),
        "open_asks" => asks(actor, goal, "open", nil, wake_up.fired_at),
        "expired_asks" => asks(actor, goal, "expired", since, wake_up.fired_at),
        "entries" =>
          entries
          |> Enum.filter(
            &(DateTime.compare(&1.occurred_at, since) != :lt and
                DateTime.compare(&1.occurred_at, wake_up.fired_at) != :gt)
          )
          |> Enum.map(&fields(&1, [:id, :kind, :title, :author_type]))
      }
    }
  end

  defp visible(actor, schema, id) do
    from(row in schema,
      join: g in subquery(Visibility.visible_goals(actor)),
      on: g.id == row.goal_id,
      where: row.goal_id == ^id
    )
  end

  defp number(actor, goal, wake_up, {:reading, r}) do
    prior =
      Repo.one(
        from(w in visible(actor, WakeUp, goal.id),
          join: r in Reading,
          on: r.id == w.reading_id,
          where: w.kind == "check_in" and w.fired_at < ^wake_up.fired_at,
          order_by: [desc: w.fired_at, desc: w.id],
          limit: 1,
          select: r
        )
      )

    comparison =
      if prior && prior.population == r.latest.population &&
           prior.source_key == r.latest.source_key,
         do: Goals.goal_number(actor, goal.id, since: prior.measured_at)

    {change, since} =
      case comparison do
        {:ok, {:reading, %{baseline: %Reading{} = baseline, change_since: change}}}
        when not is_nil(change) ->
          {scalar(change), scalar(baseline.measured_at)}

        _ ->
          {nil, nil}
      end

    %{
      "state" => "reading",
      "value" => scalar(r.latest.value),
      "unit" => r.latest.unit,
      "measured_at" => scalar(r.latest.measured_at),
      "source_label" => r.source.label,
      "change" => change,
      "change_since" => since
    }
  end

  defp number(_actor, _goal, _wake_up, {:cannot_measure, m}) do
    %{
      "state" => "cannot_measure",
      "reason" => Atom.to_string(m.reason),
      "wording" => wording(m.reason)
    }
  end

  defp wording(:no_source), do: "No number source is set for this goal."

  defp wording(:unknown_source),
    do: "The number source set for this goal is not available on this install."

  defp wording(:unknown_project), do: "The project this goal counts from is not available."
  defp wording(:bad_settings), do: "The number source settings are incomplete."
  defp wording(:no_reading_yet), do: "No value has been logged yet."
  defp wording(_), do: "The number source could not be read this time."

  defp task_rows(actor, goal) do
    from(l in visible(actor, TaskLink, goal.id),
      join: t in Platform.Tasks.Task,
      on: t.id == l.task_id
    )
  end

  defp finished_tasks(actor, goal, wake_up) do
    closed = Goals.Sources.TaskCount.closed_statuses()

    query =
      from([l, _g, t] in task_rows(actor, goal),
        where:
          is_nil(l.reported_wake_up_id) and (t.status in ^closed or not is_nil(t.deleted_at)),
        select: %{id: l.id, task_id: t.id, title: t.title, status: t.status}
      )

    {:ok, rows} =
      Repo.transaction(fn ->
        rows = Repo.all(lock(query, "FOR UPDATE OF g0"))
        ids = Enum.map(rows, & &1.id)

        Repo.update_all(from(l in visible(actor, TaskLink, goal.id), where: l.id in ^ids),
          set: [reported_wake_up_id: wake_up.id]
        )

        Enum.map(rows, &%{"id" => &1.task_id, "title" => &1.title, "status" => &1.status})
      end)

    rows
  end

  defp open_tasks(actor, goal) do
    closed = Goals.Sources.TaskCount.closed_statuses()

    Repo.all(
      from([_l, _g, t] in task_rows(actor, goal),
        where: t.status not in ^closed and is_nil(t.deleted_at),
        select: %{id: t.id, title: t.title, status: t.status}
      )
    )
    |> Enum.map(&fields(&1, [:id, :title, :status]))
  end

  defp answers(actor, goal, since, until) do
    Repo.all(
      from(a in visible(actor, Ask, goal.id),
        join: ans in AskAnswer,
        on: ans.ask_id == a.id,
        where: ans.answered_at >= ^since and ans.answered_at <= ^until,
        select: %{ask_id: a.id, title: a.title, answer: ans.answer, user_id: ans.user_id}
      )
    )
    |> Enum.map(&fields(&1, [:ask_id, :title, :answer, :user_id]))
  end

  defp asks(actor, goal, status, since, until) do
    q = from(a in visible(actor, Ask, goal.id), where: a.status == ^status)

    q =
      if since, do: from(a in q, where: a.closed_at >= ^since and a.closed_at <= ^until), else: q

    Repo.all(q)
    |> Enum.map(
      &fields(&1, [:id, :kind, :title, :body, :payload, :addressed_user_ids, :expires_at])
    )
  end

  def text(%{"goal" => goal, "number" => number, "since_last" => since}) do
    "## The goal\n#{goal["title"]}\n#{goal["why"]}\nTarget: #{goal["target_value"]} #{goal["unit"]}\nSettings: #{inspect(goal)}\n\n## The number\n#{number_text(number)}\n\n## Since the last check-in\n#{inspect(since)}\n\n## What you may do\nClose this check-in with exactly one of goal_do, goal_ask or goal_wait. Respect the goal's agent mode, stops and outreach settings."
  end

  def text(_), do: "The briefing for this check-in is not available."

  defp number_text(%{"state" => "cannot_measure", "wording" => sentence}),
    do:
      "The number could not be measured for this check-in. #{sentence} Do not state or estimate a number for this goal in your outcome."

  defp number_text(n) do
    comparison =
      if n["change"],
        do: "Change: #{n["change"]} since #{n["change_since"]}.",
        else: "This is the first comparable check-in."

    "#{n["value"]} #{n["unit"]} (#{n["source_label"]}, #{n["measured_at"]}). #{comparison}"
  end

  defp fields(row, keys), do: Map.new(keys, &{Atom.to_string(&1), scalar(Map.get(row, &1))})
  defp scalar(%Decimal{} = value), do: Decimal.to_string(value)
  defp scalar(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp scalar(%Date{} = value), do: Date.to_iso8601(value)
  defp scalar(value), do: value
end
