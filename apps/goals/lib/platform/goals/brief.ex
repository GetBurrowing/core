defmodule Platform.Goals.Brief do
  @moduledoc "Reader-scoped daily goal delivery and notebook signals (task 01a1dfc1-abcc)."
  import Ecto.Query
  alias Platform.Accounts.User
  alias Platform.Goals
  alias Platform.Goals.{Ask, AskAnswer, BriefItem, Clock, Entry, Limits, Visibility, WakeUp}
  alias Platform.Repo

  defp children(actor, schema) do
    from(row in schema,
      join: g in subquery(Visibility.visible_goals(actor)),
      on: g.id == row.goal_id
    )
  end

  defp answers(actor) do
    from(answer in AskAnswer,
      join: ask in Ask,
      on: ask.id == answer.ask_id,
      join: g in subquery(Visibility.visible_goals(actor)),
      on: g.id == ask.goal_id
    )
  end

  defp reader_items(%User{id: id} = user),
    do: from(i in children(user, BriefItem), where: i.user_id == ^id)

  defp tx(fun) do
    case Repo.transaction(fn ->
           case fun.() do
             {:error, reason} -> Repo.rollback(reason)
             {:ok, result} -> result
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def prepare(%User{id: id} = user, %Date{} = date) do
    tx(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", ["goals:brief:" <> id])
      now = Clock.now()
      ignored = ignore_old(user, date, now)
      {:ok, asks} = Goals.list_my_asks(user, limit: :infinity)

      new_asks =
        Enum.count(asks, fn ask ->
          if Repo.exists?(from(i in reader_items(user), where: i.ask_id == ^ask.id)) do
            false
          else
            %BriefItem{user_id: id, goal_id: ask.goal_id, ask_id: ask.id}
            |> BriefItem.changeset(%{kind: "ask", digest_date: date})
            |> Repo.insert!()

            true
          end
        end)

      goals =
        Repo.all(
          from(g in Visibility.visible_goals(user),
            where:
              g.owner_user_id == ^id and g.status == "active" and not is_nil(g.coach_agent_id)
          )
        )

      reports = Enum.count(goals, &prepare_report(user, &1, date, now))
      {:ok, %{new: new_asks + reports, ignored: ignored}}
    end)
  end

  def prepare(_, _), do: {:ok, %{new: 0, ignored: 0}}

  defp ignore_old(user, date, now) do
    Repo.all(
      from(i in reader_items(user),
        where: i.kind == "ask" and i.digest_date < ^date and is_nil(i.ignored_at)
      )
    )
    |> Enum.count(fn item ->
      # Lock in the same goal-then-ask order as practice. Re-addressing an old
      # item must not make answer_ask's nested rollback abort the entire brief.
      goal =
        Repo.one(
          from(g in Visibility.visible_goals(user),
            where: g.id == ^item.goal_id,
            lock: "FOR UPDATE"
          )
        )

      ask =
        if goal,
          do:
            Repo.one(
              from(a in children(user, Ask),
                where: a.id == ^item.ask_id and ^user.id in a.addressed_user_ids,
                lock: "FOR UPDATE OF g0"
              )
            ),
          else: nil

      old = answer_for(user, item.ask_id)

      written =
        not is_nil(ask) and is_nil(old) and
          match?({:ok, _}, Goals.answer_ask(user, item.ask_id, "ignored"))

      if goal, do: item |> Ecto.Changeset.change(ignored_at: now) |> Repo.update!()
      written
    end)
  end

  defp prepare_report(user, goal, date, now) do
    query =
      from(i in reader_items(user),
        where: i.goal_id == ^goal.id and i.kind == "report",
        order_by: [desc: i.through_at, desc: i.id]
      )

    previous = Repo.one(from(i in query, limit: 1))
    cutoff = DateTime.add(now, -Limits.report_window_days(), :day)
    start = if previous, do: previous.through_at, else: later(goal.inserted_at, cutoff)

    entries =
      Repo.all(
        from(e in children(user, Entry),
          where:
            e.goal_id == ^goal.id and e.kind == "action" and e.author_type == "agent" and
              e.occurred_at > ^start and e.occurred_at <= ^now,
          order_by: [asc: e.occurred_at, asc: e.id]
        )
      )

    case entries do
      [] ->
        false

      _ ->
        today =
          Repo.one(
            from(i in reader_items(user),
              where: i.goal_id == ^goal.id and i.kind == "report" and i.digest_date == ^date
            )
          )

        row = today || %BriefItem{user_id: user.id, goal_id: goal.id}

        row
        |> BriefItem.changeset(%{
          kind: "report",
          digest_date: date,
          since_at: if(today, do: today.since_at, else: start),
          through_at: List.last(entries).occurred_at,
          entry_ids:
            Enum.uniq(if(today, do: today.entry_ids, else: []) ++ Enum.map(entries, & &1.id))
        })
        |> Repo.insert_or_update!()

        true
    end
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  def items(%User{id: user_id} = user, %Date{} = date) do
    rows =
      Repo.all(
        from(i in reader_items(user),
          join: g in subquery(Visibility.visible_goals(user)),
          on: g.id == i.goal_id,
          left_join: a in Ask,
          on: a.id == i.ask_id,
          where:
            i.digest_date == ^date and (i.kind == "report" or ^user_id in a.addressed_user_ids),
          select: {i, g, a}
        )
      )

    result = Enum.map(rows, fn {item, goal, ask} -> item_map(user, item, goal, ask) end)
    {:ok, Enum.sort_by(result, &{order(&1.kind), String.downcase(&1.goal.title), &1.id})}
  end

  def items(_, _), do: {:ok, []}
  defp order(:report), do: 0
  defp order(:practice), do: 2
  defp order(_), do: 1

  def summary(user, date) do
    {:ok, items} = items(user, date)
    open = Enum.filter(items, &(&1.state == :open))

    {:ok,
     %{
       total: length(items),
       open: length(open),
       calls: Enum.count(open, &(&1.kind in [:offer, :idea, :question]))
     }}
  end

  defp item_map(user, item, goal, ask) do
    {:ok, stops} = Goals.list_stops(user, goal.id)
    stop = Enum.find(stops, &is_nil(&1.reached_on))

    number =
      case Goals.goal_number(user, goal.id) do
        {:ok, {:reading, %{latest: latest}}} -> latest
        _ -> nil
      end

    coach =
      if goal.coach_agent_id,
        do:
          Repo.one(
            from(a in Platform.Agents.Agent, where: a.id == ^goal.coach_agent_id, select: a.name)
          ),
        else: nil

    base = %{
      id: item.id,
      digest_date: item.digest_date,
      goal: %{id: goal.id, title: goal.title, agent_mode: goal.agent_mode, coach_name: coach},
      stop: stop_map(stop, number)
    }

    if item.kind == "report" do
      report_map(user, item, goal, stop, number, base)
    else
      ask_map(user, ask, goal, base)
    end
  end

  defp stop_map(nil, _), do: nil

  defp stop_map(stop, number) do
    base = Map.take(stop, [:label, :position])

    if number && stop.target_value && Decimal.compare(stop.target_value, 0) != :eq do
      percent =
        number.value
        |> Decimal.div(stop.target_value)
        |> Decimal.mult(100)
        |> Decimal.round(0, :floor)
        |> Decimal.to_integer()
        |> min(100)

      Map.put(base, :percent, percent)
    else
      base
    end
  end

  defp report_map(user, item, goal, stop, number, base) do
    entries =
      Repo.all(
        from(e in children(user, Entry),
          where: e.id in ^item.entry_ids,
          order_by: [asc: e.occurred_at, asc: e.id]
        )
      )

    entries =
      Enum.map(entries, fn e ->
        undo = latest_request(user, goal.id, e.id)
        note = e.details["undo_note"]

        takeaway =
          if e.takeaway_id,
            do:
              Repo.one(
                from(t in children(user, Entry),
                  where: t.id == ^e.takeaway_id,
                  select: %{id: t.id, title: t.title}
                )
              ),
            else: nil

        %{
          id: e.id,
          title: e.title,
          undo:
            cond do
              not nonblank?(note) -> nil
              undo && undo.details["request"] == "undo" -> :requested
              true -> :available
            end,
          undo_note: note,
          takeaway: takeaway
        }
      end)

    target = (stop && stop.target_value) || goal.target_value

    value =
      if number && target,
        do: %{value: number.value, target: target, unit: number.unit},
        else: nil

    {:ok, clock} = Goals.clock_status(user, goal.id)

    questions =
      Repo.all(
        from(e in children(user, Entry),
          where:
            e.goal_id == ^goal.id and e.author_user_id == ^user.id and
              fragment("?->>'brief_item_id'", e.details) == ^item.id and
              fragment("?->>'request'", e.details) == "question",
          order_by: [asc: e.occurred_at],
          select: %{id: e.id, title: e.title}
        )
      )

    Map.merge(base, %{
      kind: :report,
      state: if(item.noted_at, do: :done, else: :open),
      entries: entries,
      since_at: item.since_at,
      number: value,
      noted_at: item.noted_at,
      next_wake_at: clock && clock.next_wake_at,
      questions: questions
    })
  end

  defp ask_map(user, ask, goal, base) do
    answer = answer_for(user, ask.id)

    kind =
      case ask.kind do
        "practice" -> :practice
        "question" -> :question
        "offer" -> if(is_map(ask.payload["idea"]), do: :idea, else: :offer)
      end

    done =
      answer && (answer.answer == "used" or (kind != :practice and answer.answer == "declined"))

    base =
      Map.merge(base, %{
        kind: kind,
        state: if(done, do: :done, else: :open),
        ask: Map.take(ask, [:id, :title, :body, :payload]),
        answer: answer
      })

    if kind == :practice do
      results =
        if answer,
          do: Map.new(answer.details["cards"] || [], &{&1["index"], &1["result"]}),
          else: %{}

      cards =
        (ask.payload["cards"] || [])
        |> Enum.with_index()
        |> Enum.map(fn {c, i} ->
          %{index: i, front: c["front"], back: c["back"], result: results[i]}
        end)

      {:ok, streak} = practice_streak(user, goal.id, [])

      Map.merge(base, %{
        cards: cards,
        streak: if(goal.agent_mode == "coach", do: streak, else: nil)
      })
    else
      Map.put(base, :withdrawable?, withdrawable?(user, ask, answer))
    end
  end

  defp answer_for(%User{id: id} = user, ask_id),
    do: Repo.one(from(a in answers(user), where: a.ask_id == ^ask_id and a.user_id == ^id))

  def set_noted(%User{} = user, raw_id, noted?) when is_boolean(noted?) do
    with {:ok, id} <- cast_id(raw_id),
         %BriefItem{} = item <-
           Repo.one(from(i in reader_items(user), where: i.id == ^id and i.kind == "report")) do
      item
      |> BriefItem.changeset(%{noted_at: if(noted?, do: Clock.now(), else: nil)})
      |> Repo.update()
    else
      _ -> {:error, :not_found}
    end
  end

  def set_noted(_, _, _), do: {:error, :not_found}

  defp owned(user, goal_id) do
    with %User{id: id} <- user, {:ok, goal} <- Goals.get_goal(user, goal_id) do
      if goal.owner_user_id == id, do: {:ok, goal}, else: {:error, :forbidden}
    else
      _ -> {:error, :not_found}
    end
  end

  defp latest_request(user, goal_id, entry_id) do
    Repo.one(
      from(e in children(user, Entry),
        where:
          e.goal_id == ^goal_id and e.author_user_id == ^user.id and
            fragment("?->>'undo_of'", e.details) == ^entry_id and
            fragment("?->>'request'", e.details) in ["undo", "keep"],
        order_by: [desc: e.occurred_at, desc: e.inserted_at, desc: e.id],
        limit: 1
      )
    )
  end

  defp undo_request_id(user, goal_id, entry_id) do
    Repo.one(
      from(e in children(user, Entry),
        where:
          e.goal_id == ^goal_id and e.author_user_id == ^user.id and
            fragment("?->>'undo_of'", e.details) == ^entry_id and
            fragment("?->>'request'", e.details) == "undo",
        order_by: [asc: e.occurred_at, asc: e.inserted_at, asc: e.id],
        select: e.id,
        limit: 1
      )
    )
  end

  def request_undo(user, goal_id, raw_entry_id, request) do
    with {:ok, goal} <- owned(user, goal_id), {:ok, entry_id} <- cast_id(raw_entry_id) do
      tx(fn ->
        Repo.one!(
          from(g in Visibility.visible_goals(user), where: g.id == ^goal.id, lock: "FOR UPDATE")
        )

        entry =
          Repo.one(
            from(e in children(user, Entry),
              where: e.id == ^entry_id and e.goal_id == ^goal.id and e.kind == "action"
            )
          )

        previous = latest_request(user, goal.id, entry_id)

        cond do
          is_nil(entry) or not nonblank?(entry.details["undo_note"]) ->
            {:error, :not_undoable}

          request not in ["undo", "keep"] ->
            {:error, :not_undoable}

          previous && previous.details["request"] == request ->
            {:ok, previous}

          request == "keep" && is_nil(previous) ->
            {:error, :not_undoable}

          true ->
            # One immutable request identity; preference changes are separate,
            # append-only signals. The coach retains the complete chronology.
            anchor =
              previous &&
                (previous.details["undo_request_id"] || undo_request_id(user, goal.id, entry.id))

            prefix =
              cond do
                is_nil(previous) -> "Undo: "
                request == "keep" -> "Keep: "
                true -> "Resume undo: "
              end

            body =
              cond do
                is_nil(previous) -> entry.details["undo_note"]
                request == "keep" -> "Cancel the undo request; keep this action."
                true -> "Ask the coach to resume the original undo request."
              end

            details = %{"request" => request, "undo_of" => entry.id}
            details = if anchor, do: Map.put(details, "undo_request_id", anchor), else: details

            Goals.add_entry(user, goal.id, %{
              kind: "ask",
              title: String.slice(prefix <> (entry.title || ""), 0, 200),
              body: body,
              occurred_at: Clock.now(),
              details: details
            })
        end
      end)
    end
  end

  def ask_coach(user, goal_id, text, opts) do
    with {:ok, goal} <- owned(user, goal_id),
         true <- is_binary(text),
         text = String.trim(text),
         true <- String.length(text) in 1..Limits.max_question_chars() do
      item_id = Keyword.get(opts, :item_id)
      details = %{"request" => "question"}

      details =
        case cast_id(item_id) do
          {:ok, id} ->
            if Repo.exists?(
                 from(i in reader_items(user), where: i.id == ^id and i.goal_id == ^goal.id)
               ), do: Map.put(details, "brief_item_id", id), else: details

          _ ->
            details
        end

      Goals.add_entry(user, goal.id, %{
        kind: "ask",
        title: text,
        occurred_at: Clock.now(),
        details: details
      })
    else
      false -> {:error, :invalid_question}
      error -> error
    end
  end

  def get_ask(actor, raw_id) do
    with {:ok, id} <- cast_id(raw_id),
         %Ask{} = ask <- Repo.one(from(a in children(actor, Ask), where: a.id == ^id)),
         {:ok, goal} <- Goals.get_goal(actor, ask.goal_id),
         true <- allowed_ask?(actor, goal, ask) do
      own_answers = Repo.all(from(a in answers(actor), where: a.ask_id == ^id))
      {:ok, %{ask | answers: own_answers}}
    else
      _ -> {:error, :not_found}
    end
  end

  def ask_brief_date(%User{id: id} = user, ask_id) do
    with {:ok, ask} <- get_ask(user, ask_id),
         true <- id in ask.addressed_user_ids do
      {:ok,
       Repo.one(from(i in reader_items(user), where: i.ask_id == ^ask.id, select: i.digest_date))}
    else
      _ -> {:error, :not_found}
    end
  end

  def ask_brief_date(_, _), do: {:error, :not_found}

  defp allowed_ask?(%User{id: id}, goal, ask),
    do: goal.owner_user_id == id or id in ask.addressed_user_ids

  defp allowed_ask?(%Platform.Agents.Agent{id: id}, goal, _), do: goal.coach_agent_id == id
  defp allowed_ask?(_, _, _), do: false

  defp seen?(user, ask, answer) do
    Repo.exists?(
      from(w in children(user, WakeUp),
        where:
          w.goal_id == ^ask.goal_id and w.kind == "check_in" and w.fired_at > ^answer.answered_at
      )
    )
  end

  defp withdrawable?(_user, _ask, nil), do: false

  defp withdrawable?(user, ask, answer),
    do:
      ask.kind in ["offer", "question"] and answer.answer in ["used", "declined"] and
        not seen?(user, ask, answer)

  def withdraw_answer(%User{} = user, ask_id) do
    tx(fn ->
      with {:ok, ask} <- get_ask(user, ask_id), true <- user.id in ask.addressed_user_ids do
        ask =
          Repo.one!(
            from(a in children(user, Ask), where: a.id == ^ask.id, lock: "FOR UPDATE OF g0")
          )

        answer = answer_for(user, ask.id)

        cond do
          ask.kind == "practice" ->
            {:error, :not_withdrawable}

          is_nil(answer) or answer.answer not in ["used", "declined"] ->
            {:error, :not_withdrawable}

          seen?(user, ask, answer) ->
            {:error, :already_seen}

          true ->
            Repo.delete!(answer)

            if ask.status == "closed" and DateTime.compare(ask.expires_at, Clock.now()) == :gt do
              ask |> Ecto.Changeset.change(status: "open", closed_at: nil) |> Repo.update()
            else
              {:ok, ask}
            end
        end
      else
        _ -> {:error, :not_found}
      end
    end)
  end

  def withdraw_answer(_, _), do: {:error, :not_found}

  def record_practice(%User{} = user, ask_id, results) do
    result =
      tx(fn ->
        with {:ok, ask} <- get_ask(user, ask_id),
             true <- ask.kind == "practice",
             true <- user.id in ask.addressed_user_ids do
          Repo.one!(
            from(g in Visibility.visible_goals(user),
              where: g.id == ^ask.goal_id,
              lock: "FOR UPDATE"
            )
          )

          ask =
            Repo.one!(
              from(a in children(user, Ask), where: a.id == ^ask.id, lock: "FOR UPDATE OF g0")
            )

          old = answer_for(user, ask.id)
          old_cards = if old, do: old.details["cards"] || [], else: []
          count = length(ask.payload["cards"])

          expected =
            if old && old.answer == "used",
              do: for(c <- old_cards, c["result"] == "missed", do: c["index"]),
              else: Enum.to_list(0..(count - 1))

          cond do
            old && old.answer == "used" && expected == [] ->
              {:error, :already_answered}

            not valid_results?(results, expected) ->
              {:error, :incomplete}

            true ->
              pass = if old && old.answer == "used", do: (old.details["passes"] || 1) + 1, else: 1
              changed = Map.new(results, &{&1["index"], Map.put(&1, "pass", pass)})

              cards =
                if pass == 1,
                  do: Enum.map(results, &Map.put(&1, "pass", pass)),
                  else: Enum.map(old_cards, &Map.get(changed, &1["index"], &1))

              got = Enum.count(cards, &(&1["result"] == "got"))

              details = %{
                "cards" => cards,
                "got" => got,
                "missed" => count - got,
                "passes" => pass
              }

              answer_result =
                if pass == 1 do
                  with {:ok, _} <- Goals.answer_ask(user, ask.id, "used", details),
                       do: {:ok, answer_for(user, ask.id)}
                else
                  old |> Ecto.Changeset.change(details: details) |> Repo.update()
                end

              with {:ok, answer} <- answer_result do
                newly_got = Enum.count(results, &(&1["result"] == "got"))

                with {:ok, reading} <- practice_reading(user, ask.goal_id, newly_got),
                     {:ok, streak} <- practice_streak(user, ask.goal_id, []) do
                  {:ok,
                   %{
                     answer: answer,
                     got: got,
                     missed: count - got,
                     reading: reading,
                     streak: streak
                   }}
                end
              end
          end
        else
          false -> {:error, :not_found}
          error -> error
        end
      end)

    if match?({:ok, _}, result), do: refresh(user, ask_id)
    result
  end

  def record_practice(_, _, _), do: {:error, :not_found}

  defp valid_results?(results, expected) when is_list(results) do
    Enum.all?(
      results,
      &(is_map(&1) and is_integer(&1["index"]) and &1["result"] in ["got", "missed"])
    ) and Enum.sort(Enum.map(results, & &1["index"])) == Enum.sort(expected)
  end

  defp valid_results?(_, _), do: false

  defp practice_reading(user, goal_id, newly_got) do
    {:ok, goal} = Goals.get_goal(user, goal_id)
    source = Platform.Goals.Sources.fetch(goal.source_key)

    if newly_got > 0 and goal.owner_user_id == user.id and match?({:ok, _}, source) and
         elem(source, 1).kind() == :logged do
      base =
        case Goals.goal_number(user, goal_id) do
          {:ok, {:reading, %{latest: latest}}} -> latest.value
          {:ok, {:cannot_measure, %{reason: :no_reading_yet}}} -> Decimal.new(0)
          _ -> nil
        end

      if base,
        do:
          Goals.log_reading(user, goal_id, %{
            value: Decimal.add(base, newly_got),
            origin: "practice",
            note: "Practice",
            measured_at: Clock.now()
          }),
        else: {:ok, nil}
    else
      {:ok, nil}
    end
  end

  def practice_streak(%User{id: user_id} = user, goal_id, opts) do
    with {:ok, goal} <- Goals.get_goal(user, goal_id) do
      zone = Platform.Memory.Insights.Disseminator.timezone()

      today =
        Keyword.get(opts, :today, Clock.now() |> DateTime.shift_zone!(zone) |> DateTime.to_date())

      cutoff = today |> Date.add(-400) |> DateTime.new!(~T[00:00:00], zone)

      dates =
        Repo.all(
          from(a in answers(user),
            join: ask in Ask,
            on: ask.id == a.ask_id,
            where:
              ask.goal_id == ^goal.id and ask.kind == "practice" and a.user_id == ^user_id and
                a.answer == "used" and a.answered_at >= ^cutoff,
            select: a.answered_at
          )
        )
        |> Enum.map(&(DateTime.shift_zone!(&1, zone) |> DateTime.to_date()))
        |> MapSet.new()

      start = if MapSet.member?(dates, today), do: today, else: Date.add(today, -1)
      {:ok, count_days(dates, start, 0)}
    end
  end

  def practice_streak(_, _, _), do: {:ok, 0}
  defp count_days(_dates, _day, 400), do: 400

  defp count_days(dates, day, count),
    do:
      if(MapSet.member?(dates, day),
        do: count_days(dates, Date.add(day, -1), count + 1),
        else: count
      )

  def refresh(%User{} = user, raw_id) do
    with {:ok, id} <- cast_id(raw_id) do
      Repo.all(from(i in reader_items(user), where: i.ask_id == ^id))
      |> Enum.each(&Platform.Memory.Insights.BriefingSections.changed(user.id, &1.digest_date))
    end

    :ok
  end

  def refresh(_, _), do: :ok

  defp cast_id(raw_id) do
    case Ecto.UUID.cast(raw_id) do
      {:ok, id} -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp nonblank?(value), do: is_binary(value) and String.trim(value) != ""
end
