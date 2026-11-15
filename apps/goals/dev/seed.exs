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
    %{label: "First 1,000", target_value: 1000, due_on: ~D[2026-12-01]},
    %{label: "30,000", target_value: 30_000, due_on: ~D[2027-06-01]},
    %{label: "1 million", target_value: 1_000_000, caption: "the big one"}
  ])
)

ok!.(Goals.log_reading(user, yt.id, %{value: 588, measured_at: DateTime.add(DateTime.utc_now(), -7, :day)}))
ok!.(Goals.log_reading(user, yt.id, %{value: 640}))

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

ok!.(Goals.open_goal(user, rd.id, {:team, org_id}))
ok!.(Goals.measure_goal(user, rd.id))

# 4. No number
ok!.(Goals.create_goal(user, %{org_id: org_id, title: "Hire a second designer"}))

IO.puts("goals seed: 4 goals for #{email} in org #{org_id}")
