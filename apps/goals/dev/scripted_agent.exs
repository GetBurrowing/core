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
# through the `goal_propose` tool and posts in the DM as the agent: the same
# moves a real agent makes. This script runs in its own BEAM, so an open
# page does not hear it: reload the page after each turn.
#
# With `lead` as the second argument it gives the first agent the
# `agents_leader` role when nobody holds it (core's public Roles context).
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
    raise "usage: mix run dev/scripted_agent.exs <email> yt|es [start <text>] | <email> lead"
end
