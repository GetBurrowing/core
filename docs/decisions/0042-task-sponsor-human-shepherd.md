# ADR 0042: Task Sponsor — human shepherd distinct from technical assignee

**Status:** Accepted (2026-07-02)

## Context

Tasks currently have `assignee_type` + `assignee_id` — the entity that DOES the work. Increasingly the assignee is an agent (per the External Agent Dispatcher and Roles picker landed in tasks `019ef65b-*` and `019f23c8-*`). Human accountability is diffused: when an agent is the assignee, who approves the plan, submits feedback on outputs, revokes bad outputs, is answerable for cost?

Today the engine's answer is implicit — the project owner, the epic owner, the person who filed the task. None of those are recorded on the task row itself. Notification routing falls back to `@mentions` in the execution space. That works for most work, but two concrete pain points motivate this ADR:

1. **Approver-of-record.** Plans reach `pending_review` and sit until "someone" from the team approves. On busy days it isn't clear who owns the approve. The product owner often does it because he's the terminal owner, but that isn't scalable.

2. **Output review.** Agents ship code, canvases, memory pages, meetings. When one goes wrong, who's the human authority to revoke or roll back? For code the answer is `git revert`, but for canvases / memory / meeting outputs there's no obvious "the human owner said so."

## Decision

Add a nullable `sponsor_user_id` field to tasks — a **human user** responsible for shepherding the task through to completion, distinct from the assignee who does the technical work.

The Sponsor is:
- The human accountable party for the task's outcome
- The natural approver of the plan (soft signal — see "Not yet decided" below for gate semantics)
- The one who submits qualitative feedback on outputs and can revoke/discard them
- The one notified when the task transitions to states that need human attention (`in_review`, `deploying`, `blocked`)
- Explicitly **distinct** from the assignee — the assignee does the work, the Sponsor owns the work

Nullable because:
- Routine chore work (dependency bumps, format fixes, backend maintenance) doesn't need a human owner
- The absence of a Sponsor doesn't block task creation or execution — the engine falls back to existing accountability mechanisms
- Migration burden: existing tasks predate this concept and stay Sponsor-less

## Consequences

**Positive**
- Clear dual-ownership model: `assignee = who does`, `sponsor = who owns`
- Approver-of-record becomes a queryable field, not a norm-that-you-guess
- Notification routing gets a first-class human target
- Aligns with the Roles picker pattern (`019f23c8`): any-human-can-fill Sponsor, just as any-agent-can-fill role

**Negative / cost**
- Every task-create surface (LiveView dialog, MCP `task_create`) gains a new optional field. Users have to learn what it means
- The nullable path — most tasks won't have a Sponsor at first — means UI must handle the empty state gracefully

**Not yet decided (deferred to follow-up ADRs if we need them)**
- **Does Sponsor block plan approval?** For v1: no, it's a soft signal. Anyone with project permissions can approve. A hard "only Sponsor approves" gate lands in a follow-up if we see approval drift
- **Does Sponsor block deploy?** Same answer. Soft signal for v1
- **Cross-project sponsorship.** Can a Sponsor sit outside the task's project org? The nullable FK to `users` assumes yes (there's no scoping constraint), but no UI surfaces cross-org users today. If we need explicit cross-org sponsorship, revisit
- **Notification infrastructure.** This ADR does NOT specify Sponsor notifications. That's a follow-up design — likely reuses the existing mention pipeline against the Sponsor's user_id

## Alternatives considered

**Make Sponsor a Role like Historian / Meeting Producer.** Rejected — Roles are per-org, one-agent-per-role. Sponsor is per-task, per-human. Different scoping entirely.

**Overload an existing "task owner" field.** Rejected — no such field exists. The closest is `assignee`, which is already scoped to "who does the work." Sponsor is orthogonal to assignee (an agent assignee + a human sponsor is the target shape).

**Many-to-many `task_sponsors` join table.** Rejected for v1 — one Sponsor per task keeps accountability crisp. If co-sponsorship becomes a real need, promote to a join table then. Migration is straightforward.

**Sponsor at epic level, inherited by tasks.** Rejected — the inheritance semantics get messy (what if a task's Sponsor differs from the epic's? which wins?) and it conflates two levels of abstraction. Epic ownership is a separate question.

## Implementation surface

Concrete in the follow-up task filed alongside this ADR:

- **Migration**: `alter table(:tasks) do add :sponsor_user_id, references(:users, on_delete: :nilify_all), null: true end`
- **Ecto schema**: `belongs_to :sponsor, User, foreign_key: :sponsor_user_id` on `Platform.Tasks.Task`
- **Task changeset**: cast `:sponsor_user_id`, foreign_key_constraint, no validation beyond the FK
- **UI create dialog**: nullable user-picker field (mirrors the assignee picker — reuse the same component or a slim variant)
- **UI edit view**: same picker
- **UI task detail**: display Sponsor's name + link to profile
- **MCP `task_create`**: optional `sponsor_user_id` param
- **MCP `task_update`**: optional `sponsor_user_id` param (including explicit-null to unset)
- **MCP `task_get`**: return sponsor info preloaded into the response envelope
- **Preload guidance**: sponsor is small and useful in most reads — preload in `list_tasks/N` + `get_task/1`
