# Goals dev seed (task 01a1dfc1, Goals 4/8 stage 2). For screenshots and
# review ONLY: it lives outside priv, so it never ships in the image.
#
#     GOALS_ENABLED=true mix run dev/seed.exs you@example.com
#
# Creates, for the user with that email and through `Platform.Goals` only,
# goals shaped like the canvas samples (canvas 01a15ef6, prototype v4):
#
#   1. personal, a coach in mode do, source self_reported, three stops,
#      two logged readings;
#   2. personal, coach mode, source self_reported, one reading;
#   3. opened to the user's org (team), source task_count on a project in
#      that org with a few tasks, measured once;
#   4. no unit, target or source.
#
# Core rows (the user and org lookup, the coach agent, the project and its tasks, the goals.use
# grant) are made through core's public contexts.
alias Platform.Goals

email =
  case System.argv() do
    [email | _] -> email
    [] -> raise "usage: mix run dev/seed.exs <user email>"
  end

true = Goals.enabled?() || raise "set GOALS_ENABLED=true"
import Ecto.Query, only: [from: 2]

user =
  Platform.Repo.get_by(Platform.Accounts.User, email: email) || raise "no user #{email}"

# The user's first internal org: create_goal/2 needs an org the user reads.
org_id =
  Platform.Repo.one(
    from(m in Platform.Tenancy.OrgMembership,
      where: m.user_id == ^user.id and m.external == false,
      order_by: m.inserted_at,
      select: m.org_id,
      limit: 1
    )
  ) || raise "user #{email} has no internal org membership"

ok! = fn
  {:ok, value} -> value
  other -> raise "seed step failed: #{inspect(other)}"
end

# goals.use: no built-in role carries it.
space =
  ok!.(
    Platform.Chat.create_space(%{
      name: "Goals seed",
      slug: "goals-seed-#{System.unique_integer([:positive])}",
      kind: "channel",
      org_id: org_id
    })
  )

ok!.(Platform.Access.Grants.grant(%{principal: user, permission: "goals.use", resource: {:space, space.id}}))

coach =
  Platform.Repo.insert!(%Platform.Agents.Agent{
    slug: "dalton-seed-#{System.unique_integer([:positive])}",
    name: "Dalton"
  })

# 1. How to Computer
yt =
  ok!.(
    Goals.create_goal(user, %{
      org_id: org_id,
      title: "Grow How to Computer to 1M subscribers",
      why: "Plain-language computer help for people nobody ever taught.",
      agent_mode: "do",
      source_key: "self_reported",
      unit: "subscribers",
      target_value: 1_000_000
    })
  )

ok!.(Goals.update_goal(user, yt.id, %{coach_agent_id: coach.id}))

ok!.(
  Goals.put_stops(user, yt.id, [
    %{
      label: "First 1,000",
      target_value: 1000,
      due_on: ~D[2026-12-01],
      theme: "learning",
      criteria: [
        %{"text" => "Try 4 kinds of video", "needed" => 4, "found" => 4},
        %{"text" => "Find 3 kinds that bring subscribers", "needed" => 3, "found" => 1}
      ]
    },
    %{label: "30,000", target_value: 30_000, due_on: ~D[2027-06-01]},
    %{label: "1 million", target_value: 1_000_000, caption: "the big one"}
  ])
)

ok!.(Goals.log_reading(user, yt.id, %{value: 588, measured_at: DateTime.add(DateTime.utc_now(), -7, :day)}))
ok!.(Goals.log_reading(user, yt.id, %{value: 640}))

# Stage 3: the notebook behind the goal page (takeaways, actions, the rest).
shorts =
  ok!.(
    Goals.add_entry(coach, yt.id, %{
      kind: "takeaway",
      title: "Short videos bring in new viewers",
      body: "Small help channels that post shorts grow about twice as fast as those that only post long videos.",
      sources: [%{"name" => "YouTube Creator Academy"}, %{"name" => "A 2025 survey of 1,200 small creators"}],
      details: %{"doing" => "Two short fixes a week, under 6 minutes each."}
    })
  )

questions =
  ok!.(
    Goals.add_entry(coach, yt.id, %{
      kind: "takeaway",
      title: "Viewers' own questions make the best topics",
      body: "The most common comment is a question, and each one is a ready-made video.",
      sources: [%{"name" => "Notes from 40 help channels' comment sections"}],
      details: %{"doing" => "Turning the most-asked questions into shorts."}
    })
  )

ok!.(
  Goals.add_entry(coach, yt.id, %{
    kind: "action",
    title: "Short fixes under 6 minutes",
    prediction: "2 shorts a week so far, aiming for 3. People who watch them subscribe more.",
    body: "is editing \u201cClear your browser cache\u201d",
    takeaway_id: shorts.id
  })
)

ok!.(
  Goals.add_entry(coach, yt.id, %{
    kind: "action",
    title: "Comment questions as videos",
    prediction: "We'll know it works if these videos bring 2 or more subscribers per 100 views within 2 weeks.",
    body: "is picking the first 3 questions",
    takeaway_id: questions.id
  })
)

for {kind, title, body} <- [
      {"wake_up", "Morning check", "Looked at last night's numbers: 12 new subscribers."},
      {"ask", "Which thumbnail style?", "Face or screen for the next video?"},
      {"wait", "Waiting on the edit", "The cache video is with the editor until Thursday."},
      {"retro", "October retro", "Shorts did most of the work this month."}
    ] do
  ok!.(Goals.add_entry(coach, yt.id, %{kind: kind, title: title, body: body}))
end

# 2. Spanish
es =
  ok!.(
    Goals.create_goal(user, %{
      org_id: org_id,
      title: "Get by in Spanish by June",
      agent_mode: "coach",
      source_key: "self_reported",
      unit: "words",
      target_value: 300
    })
  )

ok!.(Goals.update_goal(user, es.id, %{coach_agent_id: coach.id}))
ok!.(Goals.log_reading(user, es.id, %{value: 180}))
ok!.(Goals.put_stops(user, es.id, [%{label: "300 words", target_value: 300, due_on: ~D[2027-06-01]}]))

ok!.(
  Goals.add_entry(coach, es.id, %{
    kind: "takeaway",
    title: "Spaced repetition beats cramming",
    body: "Ten minutes a day keeps more words than an hour on Sunday.",
    sources: [%{"name" => "A language-learning study"}],
    details: %{"doing" => "Daily flash cards in your briefing."}
  })
)

# 3. Redesign, opened to the org
project =
  ok!.(Platform.Tasks.create_project(%{name: "Burrow redesign (goals seed)", org_id: org_id}))

for {title, status} <- [{"Sidebar", "done"}, {"Inbox", "backlog"}, {"Chat", "backlog"}, {"Tasks", "backlog"}] do
  ok!.(Platform.Tasks.create_task(%{project_id: project.id, title: title, status: status}))
end

rd =
  ok!.(
    Goals.create_goal(user, %{
      org_id: org_id,
      title: "Ship the Burrow redesign",
      source_key: "task_count",
      source_settings: %{"project_id" => project.id, "count" => "completed"},
      unit: "pieces live",
      target_value: 24
    })
  )

ok!.(Goals.update_goal(user, rd.id, %{coach_agent_id: coach.id, agent_mode: "do"}))
ok!.(Goals.put_stops(user, rd.id, [%{label: "Half live", target_value: 12}, %{label: "All 24", target_value: 24}]))
ok!.(Goals.open_goal(user, rd.id, {:team, org_id}))
ok!.(Goals.measure_goal(user, rd.id))

# 4. No number
ok!.(Goals.create_goal(user, %{org_id: org_id, title: "Hire a second designer"}))

IO.puts("goals seed: 4 goals for #{email} in org #{org_id}")
