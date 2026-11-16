defmodule Platform.Goals.Clock do
  @moduledoc "Per-goal clock and atomic wake-up claims (task 01a1dfc1-05b0)."
  import Ecto.Query
  require Logger
  alias Platform.Repo
  alias Platform.Goals
  alias Platform.Goals.{Goal, GoalClock, WakeUp, Ask, Limits, Rhythm}
  alias Platform.Goals.WakeUps.Briefing

  def now, do: Application.get_env(:goals, :clock_now, &DateTime.utc_now/0).()

  def due(now, limit) do
    Repo.all(
      from(g in Goal,
        left_join: c in GoalClock,
        on: c.goal_id == g.id,
        where: g.status == "active" and not is_nil(g.coach_agent_id),
        where: is_nil(c.id) or (c.next_wake_at <= ^now and is_nil(c.stalled_at)),
        order_by: [asc: c.next_wake_at, asc: g.id],
        limit: ^limit,
        select: %{goal_id: g.id, coach_agent_id: g.coach_agent_id, clock_id: c.id}
      )
    )
  end

  def tick(now) do
    if Goals.enabled?() do
      sweep(now)

      Repo.update_all(from(a in Ask, where: a.status == "open" and a.expires_at <= ^now),
        set: [status: "expired", closed_at: now]
      )

      for item <- due(now, Limits.tick_batch()) do
        try do
          coach = Repo.one(from(a in Platform.Agents.Agent, where: a.id == ^item.coach_agent_id))

          with {:ok, goal} <- Goals.get_goal(coach, item.goal_id) do
            clock = visible_clock(coach, goal.id)

            if clock do
              case claim(coach, goal, clock, now) do
                {:ok, wake} -> deliver(coach, goal, wake)
                _ -> :ok
              end
            else
              create_clock(goal, now)
            end
          end
        rescue
          error -> Logger.error("Goals clock failed: #{Exception.message(error)}")
        end
      end
    end

    :ok
  end

  def visible_clock(actor, goal_id) do
    Repo.one(
      from(c in GoalClock,
        join: g in subquery(Platform.Goals.Visibility.visible_goals(actor)),
        on: g.id == c.goal_id,
        where: c.goal_id == ^goal_id
      )
    )
  end

  defp settings(goal, clock),
    do:
      Map.merge(
        Map.take(goal, [:rhythm, :rhythm_weekday]),
        Map.take(clock, [:wake_hour, :time_zone, :anchor_on])
      )

  defp schedule(goal, hour, zone, now, anchor) do
    {:ok, slot} =
      Rhythm.next_slot(
        now,
        Map.merge(Map.take(goal, [:rhythm, :rhythm_weekday]), %{
          wake_hour: hour,
          time_zone: zone,
          anchor_on: anchor
        })
      )

    %{
      next_wake_at: slot,
      anchor_on: slot |> DateTime.shift_zone!(zone) |> DateTime.to_date(),
      schedule_key: Rhythm.schedule_key(goal, hour, zone),
      stalled_at: nil
    }
  end

  defp create_clock(goal, now) do
    zone = Application.get_env(:goals, :default_time_zone, "Etc/UTC")
    zone = if Rhythm.valid_time_zone?(zone), do: zone, else: "Etc/UTC"
    hour = Limits.default_wake_hour()

    %GoalClock{goal_id: goal.id}
    |> GoalClock.changeset(
      Map.merge(schedule(goal, hour, zone, now, nil), %{time_zone: zone, wake_hour: hour})
    )
    |> Repo.insert(on_conflict: :nothing, conflict_target: :goal_id)
  end

  @doc false
  def claim(coach, goal, clock, now) do
    case Repo.transaction(fn ->
           if DateTime.compare(clock.next_wake_at, now) == :gt or not is_nil(clock.stalled_at),
             do: Repo.rollback(:already_claimed)

           # The same lock order as outcome/cap transactions: clock, goal, wake-up.
           Repo.one(from(c in GoalClock, where: c.id == ^clock.id, lock: "FOR UPDATE"))

           current =
             Repo.one(
               from(g in Platform.Goals.Visibility.visible_goals(coach),
                 where: g.id == ^goal.id,
                 lock: "FOR UPDATE"
               )
             )

           unless current && current.status == "active" && current.coach_agent_id == coach.id,
             do: Repo.rollback(:already_claimed)

           goal = current
           {:ok, next} = Rhythm.next_slot(now, settings(goal, clock))
           {:ok, following} = Rhythm.next_slot(clock.next_wake_at, settings(goal, clock))

           {count, _} =
             Repo.update_all(
               from(c in GoalClock,
                 where:
                   c.id == ^clock.id and c.next_wake_at == ^clock.next_wake_at and
                     is_nil(c.stalled_at)
               ),
               set: [next_wake_at: next, last_woken_at: now]
             )

           if count == 0, do: Repo.rollback(:already_claimed)

           open =
             Repo.all(
               from(w in visible_wakes(coach),
                 where: w.goal_id == ^goal.id and w.status == "open"
               )
             )

           Enum.each(open, &unanswered(&1, now))

           %WakeUp{goal_id: goal.id, coach_agent_id: coach.id}
           |> WakeUp.changeset(%{
             kind: wake_kind(coach, goal),
             due_at: clock.next_wake_at,
             fired_at: now,
             respond_by: DateTime.add(now, Limits.respond_within_hours(goal.rhythm) * 3600),
             catch_up: DateTime.compare(following, now) != :gt
           })
           |> Repo.insert!()
         end) do
      {:error, :already_claimed} -> :already_claimed
      other -> other
    end
  end

  defp wake_kind(actor, goal) do
    latest =
      Repo.one(
        from(w in visible_wakes(actor),
          where: w.goal_id == ^goal.id and w.kind == "retro",
          order_by: [desc: w.due_at],
          limit: 1,
          select: w.due_at
        )
      )

    query = from(w in visible_wakes(actor), where: w.goal_id == ^goal.id and w.kind == "check_in")
    query = if latest, do: from(w in query, where: w.due_at > ^latest), else: query
    count = Repo.aggregate(query, :count)
    if count >= Platform.Goals.Retro.effective_every(goal) - 1, do: "retro", else: "check_in"
  end

  def visible_wakes(actor) do
    from(w in WakeUp,
      join: g in subquery(Platform.Goals.Visibility.visible_goals(actor)),
      on: g.id == w.goal_id
    )
  end

  defp deliver(coach, goal, wake) do
    result = Goals.measure_goal(coach, goal.id)

    reading_id =
      case result do
        {:ok, {:reading, r}} -> r.latest.id
        _ -> nil
      end

    {:ok, wake} =
      Repo.transaction(fn ->
        snapshot = Briefing.snapshot(coach, goal, wake, result)
        wake |> WakeUp.changeset(%{reading_id: reading_id, briefing: snapshot}) |> Repo.update!()
      end)

    delivery = dispatch(coach, wake)
    wake |> WakeUp.changeset(%{delivery: delivery}) |> Repo.update!()
  end

  defp dispatch(%{runtime_type: "external", runtime_id: id} = coach, wake) when is_binary(id) do
    signal = %{
      reason: :system_event,
      metadata: %{
        agent_id: coach.id,
        agent_slug: coach.slug,
        responsibility_key: "goals.wake_up",
        feature: "goals",
        trigger_kind: "cron",
        prompt: Briefing.wire_prompt(wake),
        prompt_status: :rendered
      }
    }

    dispatcher =
      Application.get_env(:goals, :wake_up_dispatcher, {Platform.Chat.AgentResponder, :respond})

    result =
      case dispatcher do
        {module, function} -> apply(module, function, [signal])
        function when is_function(function, 1) -> function.(signal)
      end

    case result do
      :ok -> "sent"
      {:error, :runtime_offline} -> "offline"
      _ -> "failed"
    end
  rescue
    _ -> "failed"
  end

  defp dispatch(_, _), do: "no_runtime"

  defp sweep(now) do
    # Identifier-only scan; goal content is loaded through the coach's visibility.
    ids =
      Repo.all(
        from(w in WakeUp,
          where: w.status == "open" and w.respond_by <= ^now,
          select: {w.id, w.goal_id}
        )
      )

    for {id, goal_id} <- ids do
      try do
        Repo.transaction(fn ->
          Repo.one(from(c in GoalClock, where: c.goal_id == ^goal_id, lock: "FOR UPDATE"))

          case Repo.one(from(w in WakeUp, where: w.id == ^id, lock: "FOR UPDATE")) do
            %WakeUp{status: "open"} = wake -> unanswered(wake, now)
            _ -> :ok
          end
        end)
      rescue
        error -> Logger.error("Goals sweep failed: #{Exception.message(error)}")
      end
    end
  end

  defp load_coach(nil), do: nil
  defp load_coach(id), do: Repo.one(from(a in Platform.Agents.Agent, where: a.id == ^id))

  defp unanswered(wake, now) do
    wake = wake |> WakeUp.changeset(%{status: "unanswered", closed_at: now}) |> Repo.update!()
    coach = load_coach(wake.coach_agent_id)

    with {:ok, %{coach_agent_id: coach_id}} <- Goals.get_goal(coach, wake.goal_id),
         true <- coach_id == wake.coach_agent_id,
         {:ok, entry} <-
           Goals.add_entry(coach, wake.goal_id, %{
             kind: "wake_up",
             title:
               if(wake.kind == "retro", do: "Retro not answered", else: "Check-in not answered"),
             reading_id: wake.reading_id,
             occurred_at: now,
             details: %{"wake_up_id" => wake.id, "status" => "unanswered"}
           }) do
      wake |> WakeUp.changeset(%{entry_id: entry.id}) |> Repo.update!()
    end

    recent =
      Repo.all(
        from(w in visible_wakes(coach),
          where: w.goal_id == ^wake.goal_id and w.kind == "check_in",
          order_by: [desc: w.due_at],
          limit: ^Limits.stall_after(),
          select: w.status
        )
      )

    if length(recent) == Limits.stall_after() and Enum.all?(recent, &(&1 == "unanswered")),
      do:
        Repo.update_all(from(c in GoalClock, where: c.goal_id == ^wake.goal_id),
          set: [stalled_at: now]
        )
  end

  def sync(before_goal, after_goal, now) do
    clock = visible_clock(%Platform.Accounts.User{id: after_goal.owner_user_id}, after_goal.id)

    if clock &&
         (clock.schedule_key != Rhythm.schedule_key(after_goal, clock.wake_hour, clock.time_zone) or
            (after_goal.status == "active" and
               (before_goal.status != "active" or
                  before_goal.coach_agent_id != after_goal.coach_agent_id))) do
      reset(clock, after_goal, now)
    end

    :ok
  end

  def reset(clock, goal, now) do
    clock
    |> GoalClock.changeset(schedule(goal, clock.wake_hour, clock.time_zone, now, nil))
    |> Repo.update()
  end
end

