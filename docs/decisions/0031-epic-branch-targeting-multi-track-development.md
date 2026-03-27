# ADR 0031: Epic-Level Branch Targeting for Multi-Track Development

- **Status:** Accepted
- **Date:** 2026-03-27
- **Owners:** Rowan Ellis

## Context

Suite needs to support parallel development tracks: one team works on `main` (production), another works on a long-lived feature branch (e.g. `feat/reskin`). Both tracks need:

- Independent task management on the same board
- Agent-driven development with correct branch targeting
- Independent deployments (production vs experimental)
- Regular absorption of `main` into the feature branch

The existing infrastructure already supports this partially:
- `core-platform-exp` runs as a source-mounted container on hive at `suite-exp.example.com`
- The task system has epics that group related tasks
- `project.default_branch` drives git workflow in agent prompts

What's missing is the ability for an epic to override the target branch and deploy target, so tasks in that epic flow to the right branch and the right environment.

## Decision

### Epic-level `target_branch` field

Add a nullable `target_branch` column to the `epics` table. When set, all tasks in this epic:
- Create worktrees from `origin/<target_branch>` instead of `origin/<project.default_branch>`
- Open PRs against `<target_branch>` instead of `<project.default_branch>`
- Deploy to the environment associated with that branch

Resolution order: `epic.target_branch || project.default_branch || "main"`

### Epic-level `deploy_target` field

Add a nullable `deploy_target` column (varchar) to the `epics` table. Maps to a named deploy target in `project.deploy_config.deploy_targets`. When set, the deploy stage uses this target's configuration instead of the project default.

### Branch-aware dispatch

`HeartbeatScheduler` and `ContextAssembler` resolve the effective branch via:

```elixir
defp resolve_branch(task) do
  epic = task.epic
  project = task.project
  (epic && epic.target_branch) || (project && project.default_branch) || "main"
end
```

All dispatch prompts (execution, review, deploying) use this resolved branch instead of hardcoded `project.default_branch`.

### CI: feature branch image builds

Update `.github/workflows/ci.yml` to:
- Run tests on PRs targeting `feat/reskin` (not just `main`)
- Build and push images for feature branches with branch-specific tags

For the source-mounted exp instance, no image is needed — it runs from the git checkout directly. But CI must still validate PRs against the feature branch.

### Exp instance: branch switching

The `core-platform-exp` container on hive source-mounts `/home/dev/sources/core`. To target `feat/reskin`:

1. `cd /home/dev/sources/core && git fetch origin && git checkout feat/reskin`
2. Restart `core-platform-exp` (it recompiles on start via `mix deps.get && mix ecto.migrate && mix phx.server`)

A helper script in core-ops automates this.

### Main absorption

Feature branches must regularly absorb `main` to avoid drift. This is the feature branch owner's responsibility. The recommended cadence is daily or after each significant main merge.

## Schema Changes

```sql
ALTER TABLE epics ADD COLUMN target_branch varchar;
ALTER TABLE epics ADD COLUMN deploy_target varchar;
```

Both nullable. When null, project defaults apply.

## Implementation

### Platform changes
- `Epic` schema: add `target_branch` and `deploy_target` fields
- `ContextAssembler`: include `target_branch` in serialized epic
- `HeartbeatScheduler`: resolve branch from epic → project chain
- `DeployStageBuilder`: use epic's deploy target when set
- `TasksLive`: show target branch on epic detail, allow editing

### CI changes
- Add `feat/reskin` (and pattern `feat/**`) to PR target branches
- Optionally build images for feature branches

### Ops changes
- Script to switch exp instance branch
- Document the branch switching procedure

## Consequences

### Positive
- Parallel development tracks without project/board duplication
- Same agents, same tooling, same workflow — just different branch targets
- Clean separation via epics — easy to see what's on which track
- No new infrastructure — reuses existing exp container

### Tradeoffs
- Long-lived feature branches accumulate merge debt
- Two deployment targets means two things to monitor
- Epic-level branching adds complexity to the dispatch prompt resolution

## Guardrails
- Feature branch epics must be clearly named (e.g. "Reskin [feat/reskin]")
- Main absorption is the feature branch owner's responsibility
- Do not create circular dependencies between tracks
- The exp instance is for validation, not production traffic
