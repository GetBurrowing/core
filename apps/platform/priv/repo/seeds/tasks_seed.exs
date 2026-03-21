# Seeds for the Tasks kanban board (ADR 0018 Phase 5)
#
# Run with:
#   cd apps/platform && mix run priv/repo/seeds/tasks_seed.exs
#
# Idempotent — uses get_or_insert pattern on project slug.

alias Platform.Repo
alias Platform.Tasks.{Project, Epic, Task, Plan, Stage, Validation}

# ── Project ─────────────────────────────────────────────────────────────

project =
  case Repo.get_by(Project, slug: "startup-suite-core") do
    nil ->
      Repo.insert!(%Project{
        name: "Startup Suite Core",
        slug: "startup-suite-core",
        repo_url: "git@github.com:example/startup-suite-core.git",
        default_branch: "main",
        tech_stack: %{"language" => "elixir", "framework" => "phoenix", "build" => "mix"},
        deploy_config: %{
          "targets" => [
            %{"name" => "production", "type" => "docker_compose", "host" => "dev@192.0.2.234"}
          ]
        }
      })

    existing ->
      existing
  end

IO.puts("Project: #{project.name} (#{project.id})")

# ── Epics ───────────────────────────────────────────────────────────────

epic_auth =
  Repo.insert!(%Epic{
    project_id: project.id,
    name: "Authentication & Authorization",
    description: "OIDC login, session management, role-based access",
    acceptance_criteria:
      "Users can log in via OIDC, sessions persist, roles enforced on all routes.",
    status: "in_progress"
  })

epic_exec =
  Repo.insert!(%Epic{
    project_id: project.id,
    name: "Execution Runtime",
    description: "Run control, context plane, artifact promotion pipeline",
    acceptance_criteria: "Runs complete end-to-end with artifacts promoted and published.",
    status: "open"
  })

IO.puts("Epics: #{epic_auth.name}, #{epic_exec.name}")

# ── Tasks ───────────────────────────────────────────────────────────────

tasks_data = [
  %{
    title: "Implement OIDC callback handler",
    description: "Handle the OIDC callback, create or match user, set session.",
    status: "done",
    priority: "high",
    epic_id: epic_auth.id
  },
  %{
    title: "Add role-based route guards",
    description: "Middleware that checks user roles before granting access to protected routes.",
    status: "in_review",
    priority: "high",
    epic_id: epic_auth.id
  },
  %{
    title: "Session expiry and refresh",
    description: "Implement session TTL with silent refresh using OIDC refresh tokens.",
    status: "in_progress",
    priority: "medium",
    epic_id: epic_auth.id
  },
  %{
    title: "RunServer stale detection",
    description:
      "Detect stale runs when the agent stops sending heartbeats within the SLA window.",
    status: "in_progress",
    priority: "high",
    epic_id: epic_exec.id
  },
  %{
    title: "Artifact promotion pipeline",
    description: "Promote artifacts from staging to published state with integrity checks.",
    status: "backlog",
    priority: "medium",
    epic_id: epic_exec.id
  },
  %{
    title: "Context plane snapshot API",
    description: "Expose snapshot/delta endpoints for external agents to consume context.",
    status: "backlog",
    priority: "low",
    epic_id: epic_exec.id
  },
  %{
    title: "Deploy target config UI",
    description:
      "Admin panel for configuring project deploy targets (docker-compose, fly, etc.).",
    status: "backlog",
    priority: "low",
    epic_id: epic_exec.id
  },
  %{
    title: "CI validation checker",
    description: "Poll GitHub Actions status and update stage validation automatically.",
    status: "blocked",
    priority: "medium",
    epic_id: epic_exec.id,
    metadata: %{"blocked_reason" => "Waiting on GitHub App installation"}
  }
]

tasks =
  Enum.map(tasks_data, fn data ->
    Repo.insert!(%Task{
      project_id: project.id,
      epic_id: data.epic_id,
      title: data.title,
      description: data.description,
      status: data.status,
      priority: data.priority,
      metadata: Map.get(data, :metadata, %{})
    })
  end)

IO.puts("Tasks: #{length(tasks)} created")

# ── Plans with stages (for 2 tasks) ────────────────────────────────────

# Plan for "Session expiry and refresh" (in_progress)
session_task = Enum.find(tasks, &(&1.title == "Session expiry and refresh"))

plan1 =
  Repo.insert!(%Plan{
    task_id: session_task.id,
    status: "approved",
    version: 1,
    approved_by: "system",
    approved_at: DateTime.utc_now()
  })

Repo.insert!(%Stage{
  plan_id: plan1.id,
  position: 1,
  name: "Implement refresh token storage",
  description: "Store OIDC refresh tokens securely in the session store.",
  status: "passed",
  started_at: DateTime.add(DateTime.utc_now(), -3600),
  completed_at: DateTime.add(DateTime.utc_now(), -1800)
})

stage1_2 =
  Repo.insert!(%Stage{
    plan_id: plan1.id,
    position: 2,
    name: "Add silent refresh flow",
    description: "Background refresh before token expiry using refresh_token grant.",
    status: "running",
    started_at: DateTime.add(DateTime.utc_now(), -900)
  })

Repo.insert!(%Validation{
  stage_id: stage1_2.id,
  kind: "test_pass",
  status: "pending"
})

Repo.insert!(%Stage{
  plan_id: plan1.id,
  position: 3,
  name: "Integration test with OIDC provider",
  description: "End-to-end test against the dev OIDC provider.",
  status: "pending"
})

# Plan for "RunServer stale detection" (in_progress)
stale_task = Enum.find(tasks, &(&1.title == "RunServer stale detection"))

plan2 =
  Repo.insert!(%Plan{
    task_id: stale_task.id,
    status: "approved",
    version: 1,
    approved_by: "system",
    approved_at: DateTime.utc_now()
  })

Repo.insert!(%Stage{
  plan_id: plan2.id,
  position: 1,
  name: "Add heartbeat tracking to RunServer",
  description: "Track last heartbeat timestamp in RunServer state.",
  status: "passed",
  started_at: DateTime.add(DateTime.utc_now(), -7200),
  completed_at: DateTime.add(DateTime.utc_now(), -5400)
})

Repo.insert!(%Stage{
  plan_id: plan2.id,
  position: 2,
  name: "Implement stale detection timer",
  description: "Periodic check that flags runs as stale when heartbeat exceeds SLA.",
  status: "passed",
  started_at: DateTime.add(DateTime.utc_now(), -5400),
  completed_at: DateTime.add(DateTime.utc_now(), -3600)
})

stage2_3 =
  Repo.insert!(%Stage{
    plan_id: plan2.id,
    position: 3,
    name: "Dead run cleanup",
    description: "Transition stale runs to dead status and notify the board.",
    status: "running",
    started_at: DateTime.add(DateTime.utc_now(), -1800)
  })

Repo.insert!(%Validation{
  stage_id: stage2_3.id,
  kind: "test_pass",
  status: "pending"
})

Repo.insert!(%Validation{
  stage_id: stage2_3.id,
  kind: "code_review",
  status: "pending"
})

IO.puts("Plans: 2 created with stages and validations")
IO.puts("Done — seed data ready for kanban board.")
