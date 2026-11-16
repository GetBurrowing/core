defmodule Platform.Goals.WakeUps.Briefing do
  @moduledoc """
  Private coach snapshots and content-free runtime signals.
  Task 01a1dfc1-abcc adds answer details and readable practice results and
  suggestion choices so the coach can react to briefing signals.
  """
  import Ecto.Query
  alias Platform.Goals
  alias Platform.Goals.{Ask, AskAnswer, GoalClock, Limits, Reading, TaskLink, Visibility, WakeUp}
  alias Platform.Repo

  def wire_prompt(%{kind: "retro"} = wake_up) do
    "A goal you coach is due for a retro. Wake-up id: #{wake_up.id}. Read it with goal_wake_up_get, then close it with goal_retro before #{DateTime.to_iso8601(wake_up.respond_by)}."
  end

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

    snapshot = %{
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

    if wake_up.kind == "retro" do
      {:ok, window} = Goals.Retro.window(actor, goal.id, wake_up.fired_at)

      retro = %{
        "since" => scalar(window.since),
        "change" => scalar(window.change),
        "flat" => window.flat,
        "flat_retros" => window.flat_retros,
        "goal_change_required" => window.goal_change_required,
        "every" => Goals.Retro.effective_every(goal),
        "predictions" => window.predictions,
        "answers" => fields(window.answers, [:used, :declined, :ignored])
      }

      Map.put(snapshot, "retro", retro)
    else
      snapshot
    end
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
        select: %{
          ask_id: a.id,
          title: a.title,
          answer: ans.answer,
          user_id: ans.user_id,
          details: ans.details,
          payload: a.payload
        }
      )
    )
    |> Enum.map(&fields(&1, [:ask_id, :title, :answer, :user_id, :details, :payload]))
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

  def text(%{"retro" => retro} = snapshot) do
    base = text(Map.delete(snapshot, "retro"))
    [context, _] = String.split(base, "## What you may do", parts: 2)

    predictions =
      Enum.map_join(retro["predictions"] || [], "\n", fn row ->
        verdict = String.replace(row["verdict"], "_", " ")

        numbers =
          if row["predicted_by"] && row["predicted_change"] && row["actual_change"],
            do: "; expected #{row["predicted_change"]}, moved #{row["actual_change"]}",
            else: ""

        "#{row["prediction"]}: #{verdict}#{numbers}"
      end)

    change =
      if retro["change"],
        do: "The number moved #{retro["change"]} in this window.",
        else: "The change could not be measured."

    requirement =
      if retro["goal_change_required"],
        do:
          "\nThe number has not moved across #{retro["flat_retros"]} retros. Propose changing the goal itself (its target, its scope, or ending it). Another tactic is refused.",
        else: ""

    context <>
      "## Looking back\n" <>
      predictions <>
      "\n" <> change <> "\n\n## What you may do\nClose this retro with goal_retro." <> requirement
  end

  def text(%{"goal" => goal, "number" => number, "since_last" => since}) do
    "## The goal\n#{goal["title"]}\n#{goal["why"]}\nTarget: #{goal["target_value"]} #{goal["unit"]}\nSettings: #{inspect(goal)}\n\n## The number\n#{number_text(number)}\n\n## Since the last check-in\n#{inspect(since)}\n#{answer_text(since["answers"] || [])}\n\n## What you may do\nClose this check-in with exactly one of goal_do, goal_ask or goal_wait. Respect the goal's agent mode, stops and outreach settings."
  end

  def text(_), do: "The briefing for this check-in is not available."

  # Practice results and suggestion choices must reach the coach as readable signals
  # (task 01a1dfc1-abcc), beyond the persisted answer payload.
  defp answer_text(answers) do
    Enum.map_join(answers, "\n", fn answer ->
      details = answer["details"] || %{}

      practice =
        if is_integer(details["got"]) and is_integer(details["missed"]),
          do: "got #{details["got"]}, missed #{details["missed"]}",
          else: ""

      choices =
        case details["choices"] do
          list when is_list(list) -> Enum.filter(list, &is_map/1)
          _ -> []
        end
        |> Enum.map_join("; ", fn choice ->
          suggestions = get_in(answer, ["payload", "suggestions"]) || []

          suggestion =
            if is_integer(choice["index"]), do: Enum.at(suggestions, choice["index"]), else: nil

          title = choice["title"] || (suggestion && suggestion["title"]) || "Suggestion"
          "#{title}: #{choice["choice"]}"
        end)

      "#{answer["title"]}: #{practice} #{choices}"
    end)
  end

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
