defmodule Platform.Goals.OwnerPace do
  @moduledoc "Owner response pacing from delivered, ignored asks (task 01a1dfc2-0d97)."
  import Ecto.Query
  alias Platform.Accounts.User
  alias Platform.Goals
  alias Platform.Goals.{Ask, AskAnswer, BriefItem, Clock, GoalClock, Limits, Visibility}
  alias Platform.Repo

  defp answers(owner, goal) do
    from(a in AskAnswer,
      join: ask in Ask,
      on: ask.id == a.ask_id,
      join: g in subquery(Visibility.visible_goals(owner)),
      on: g.id == ask.goal_id,
      where: g.id == ^goal.id and a.user_id == ^owner.id
    )
  end

  @doc "Counts distinct owner briefs since their most recent final answer, in one query."
  def ignored_briefs(goal) do
    owner = %User{id: goal.owner_user_id}

    latest =
      from(a in answers(owner, goal),
        where: a.answer in ["used", "declined"],
        select: %{answered_at: max(a.answered_at)}
      )

    Repo.one(
      from(a in answers(owner, goal),
        join: i in BriefItem,
        on: i.ask_id == a.ask_id and i.user_id == a.user_id,
        left_join: last in subquery(latest),
        on: true,
        where: i.kind == "ask" and a.answer == "ignored",
        where: is_nil(last.answered_at) or a.answered_at > last.answered_at,
        select: count(i.digest_date, :distinct)
      )
    )
  end

  @doc false
  def ask_cap(goal, clock) do
    usual = Limits.max_open_asks(goal.outreach)
    if clock && clock.paced_at, do: min(usual, Limits.paced_max_open_asks()), else: usual
  end

  @doc "Refreshes an already-visible goal inside the caller's transaction (planner ruling)."
  def refresh(goal, now) do
    owner = %User{id: goal.owner_user_id}

    clock =
      Repo.one(
        from(c in GoalClock,
          join: g in subquery(Visibility.visible_goals(owner)),
          on: g.id == c.goal_id,
          where: g.id == ^goal.id,
          lock: "FOR UPDATE OF g0"
        )
      )

    if (goal.status == "active" and goal.coach_agent_id) && clock do
      ignored = ignored_briefs(goal)

      cond do
        ignored >= Limits.pace_after_ignored_briefs() and is_nil(clock.paced_at) ->
          clock = clock |> Ecto.Changeset.change(paced_at: now) |> Repo.update!()
          {:ok, _} = Clock.repace(clock, goal, now)
          coach = Repo.one(from(a in Platform.Agents.Agent, where: a.id == ^goal.coach_agent_id))

          {:ok, _} =
            Goals.add_entry(coach, goal.id, %{
              kind: "wait",
              title: "Slowed down to match you",
              occurred_at: now,
              body:
                "Nothing from the last #{ignored} briefs was answered, so I am checking in less often and holding one thing at a time. Answer anything and the usual rhythm comes back.",
              details: %{
                "pace" => "slowed",
                "ignored_briefs" => ignored,
                "every" => Limits.paced_every(goal.rhythm)
              }
            })

          :slowed

        ignored < Limits.pace_after_ignored_briefs() and not is_nil(clock.paced_at) ->
          clock = clock |> Ecto.Changeset.change(paced_at: nil) |> Repo.update!()
          {:ok, _} = Clock.repace(clock, goal, now)
          :restored

        true ->
          :unchanged
      end
    else
      :unchanged
    end
  end
end
