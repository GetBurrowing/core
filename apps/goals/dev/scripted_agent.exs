# Play one turn of the scripted lead agent (task 01a1dfc1-7625, Goals 5/8
# stage 3). For screenshots and review ONLY: it lives outside priv and lib,
# so it never ships. Run inside the dev container, from apps/goals:
#
#     GOALS_ENABLED=true mix run dev/scripted_agent.exs you@example.com yt
#     GOALS_ENABLED=true mix run dev/scripted_agent.exs you@example.com es
#
# The user must have started a New goal conversation on /m/goals?new=1 (or
# pass `start "<opening text>"` as the third and fourth arguments to start
# one as them). It plays the agent's next turn with
# `Platform.Goals.ScriptedAgent.next_turn/3`, which records the proposal
# through the `goal_propose` tool and posts in the proposal's own
# conversation space as the agent: the same
# moves a real agent makes. This script runs in its own BEAM, so an open
# page does not hear it: reload the page after each turn.
#
# With `lead` as the second argument it gives the first agent the
# `agents_leader` role when nobody holds it (core's public Roles context).
#
# Stage 4, after the person pressed Create goal:
#
#     GOALS_ENABLED=true mix run dev/scripted_agent.exs you@example.com yt research
#     GOALS_ENABLED=true mix run dev/scripted_agent.exs you@example.com yt cite
#
# `research` plays the coach's answer to the confirmed signal on the
# person's latest confirmed conversation: the researching message in its space
# and three takeaways through `goal_takeaway_add`. `cite` runs the goal's
# clock to its first slot and closes that wake-up with `goal_do` (yt) or a
# practice `goal_ask` (es) citing the first takeaway.
Code.require_file("../test/support/scripted_agent.ex", __DIR__)

alias Platform.Goals

true = Goals.enabled?() || raise "set GOALS_ENABLED=true"

user_for = fn email ->
  Platform.Repo.get_by(Platform.Accounts.User, email: email) || raise "no user #{email}"
end

case System.argv() do
  [_email, "lead"] ->
    role = Platform.Chat.Sidebar.agents_leader_role()

    case Platform.Roles.agent_id_for_role(role) do
      nil ->
        import Ecto.Query, only: [from: 2]

        agent =
          Platform.Repo.one(
            from(a in Platform.Agents.Agent, order_by: a.inserted_at, limit: 1)
          ) || raise "no agent"

        {:ok, _} = Platform.Roles.assign_role(role, agent.id)
        IO.puts("agents_leader -> #{agent.name}")

      id ->
        IO.puts("agents_leader already held by #{id}")
    end

  [email, example, action] when example in ["yt", "es"] and action in ["research", "cite"] ->
    import Ecto.Query, only: [from: 2]
    user = user_for.(email)
    {:ok, lead} = Goals.lead_agent(user)
    example = String.to_existing_atom(example)

    proposal =
      Platform.Repo.one(
        from(p in Platform.Goals.Proposal,
          where: p.user_id == ^user.id and p.status == "confirmed",
          order_by: [desc: p.confirmed_at],
          limit: 1
        )
      ) || raise "#{email} has not created a goal from a New goal conversation"

    goal_id = proposal.goal_id
    agent = %{agent_id: lead.id}

    case action do
      "research" ->
        {:ok, entries} = Platform.Goals.ScriptedAgent.research(lead, proposal.id, goal_id, example)
        IO.puts("posted the researching message and #{length(entries)} takeaways")

      "cite" ->
        alias Platform.Goals.{Clock, GoalClock, WakeUp}

        takeaway =
          Platform.Repo.one(
            from(e in Platform.Goals.Entry,
              where: e.goal_id == ^goal_id and e.kind == "takeaway",
              order_by: [asc: e.occurred_at, asc: e.id],
              limit: 1
            )
          ) || raise "run research first"

        clock_for = fn -> Platform.Repo.one(from(c in GoalClock, where: c.goal_id == ^goal_id)) end
        if is_nil(clock_for.()), do: :ok = Clock.tick(DateTime.utc_now())
        :ok = Clock.tick(clock_for.().next_wake_at)

        wake =
          Platform.Repo.one!(
            from(w in WakeUp, where: w.goal_id == ^goal_id and w.status == "open", limit: 1)
          )

        base = %{
          "wake_up_id" => wake.id,
          "takeaway_id" => takeaway.id,
          "prediction" => "This will help",
          "predicted_by" => Date.to_iso8601(Date.add(Date.utc_today(), 7))
        }

        {tool, args} =
          case example do
            :yt ->
              {"goal_do", Map.put(base, "title", "Scheduled Monday's video")}

            :es ->
              {"goal_ask",
               Map.merge(base, %{
                 "kind" => "practice",
                 "title" => "Five new words",
                 "payload" => %{
                   "cards" => [
                     %{"front" => "la playa", "back" => "the beach"},
                     %{"front" => "el tren", "back" => "the train"}
                   ]
                 }
               })}
          end

        {:ok, _} = Platform.Goals.Tools.execute(tool, args, agent)
        IO.puts("#{tool} closed the first check-in citing #{inspect(takeaway.title)}")
    end

  [email, example | rest] when example in ["yt", "es"] ->
    user = user_for.(email)
    {:ok, lead} = Goals.lead_agent(user)

    case rest do
      ["start", text] -> {:ok, _} = Goals.start_goal_conversation(user, text)
      [] -> :ok
    end

    {:ok, proposal} = Goals.current_proposal(user)
    proposal || raise "#{email} has no open New goal conversation"

    case Platform.Goals.ScriptedAgent.next_turn(lead, proposal, String.to_existing_atom(example)) do
      {:ok, turn} -> IO.puts("played turn #{turn}")
      :done -> IO.puts("the conversation is complete")
    end

  _ ->
    raise "usage: mix run dev/scripted_agent.exs <email> yt|es [start <text> | research | cite] | <email> lead"
end
