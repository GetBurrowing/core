---
title: Task stacks
summary: How task stacks make several tasks ship as one piece of work; epics and projects.
order: 5
verified_at: "837fba6e"
---

# Task stacks

## What it is

A task stack groups the tasks that together make one feature, so the work ships together or not at all. Each member is an ordinary task with its own plan, stages and checks. The stack adds three things: an order between members, a shared branch, and one pull request that ships every member at once.

### How task stacks work

1. **Create the stack.** It belongs to a project and has a slug. Its rollup branch, `stack/<slug>`, is cut from the stack's base branch, `main` unless you set another.
2. **Add members.** Attach existing tasks. Members can declare in-stack dependencies ("this task waits for that one"). Burrow refuses cycles and dependencies on tasks outside the stack.
3. **Start planning.** Planning is dispatched to members in waves: first the members that depend on nobody, then the members that depend only on those, and so on. If no member has declared a dependency, Burrow infers the edges first. By default the next wave starts when the previous wave's plans are approved. With auto-plan on, every wave starts at once. With auto-accept on, each member's plan is approved as soon as it is submitted.
4. **Start the stack.** The stack moves from `forming` to `in_progress`. Members that depend on no other member start; the rest wait in `stack_pending` and start once the members they depend on have landed on the rollup branch.
5. **The commencement gate.** No member starts work until every member has an approved plan. Leaving out dependencies removes ordering, not this gate.
6. **Member work.** Each member works on its own branch, `task/<task id>`, cut from the rollup branch. When a member passes review, Burrow fast-forwards the rollup branch to it. Members get no deploy stage of their own.
7. **Ship.** When every member is on the rollup branch, Burrow opens one pull request from the rollup branch to the base branch. When it merges, the stack and all its members are `done`.

Stack statuses are `forming`, `in_progress`, `in_review`, `deploying`, `done`, `abandoned` and `blocked`.

### Epics and projects

- A **project** is a repository and its settings: the repo URL, the default branch, and the deploy configuration that tells tasks how to ship. Every task, stack and meeting belongs to a project.
- An **epic** groups related tasks under one theme, with acceptance criteria and optionally a target branch and a deploy target. An epic organises work; it does not make tasks ship together. Use a stack for that.

## When to use it

- **A feature that spans schema, back end and UI and is useless in part:** a stack.
- **Related tasks that can each ship alone:** separate tasks, grouped by an epic if you like.
- **A single change:** a plain task. A stack adds planning and merge overhead.
- **Scope you do not know yet:** wait. A stack works best when its members are known before it starts.

## How agents use it

- `stack_create` creates a stack in a project. `stack_update` changes its name, description or sponsor.
- `stack_add` attaches a task as a member, and `stack_eject` detaches one. Ejecting refuses while other members depend on it.
- `stack_add_dependency` and `stack_remove_dependency` manage in-stack dependency edges.
- `stack_assign_agents` sets planning, execution and review assignees for every member that has none of its own.
- `stack_start_planning` dispatches planning, and `stack_start` starts execution.
- `stack_get` shows the members, the dependency edges and which members can run now. `stack_list` lists stacks by project or status.
- `stack_retry_member_merge` retries one member's fast-forward after you rebase its branch onto the rollup branch.
- `stack_complete` closes a stack whose members all shipped through their own pull requests. Every member must already be `done`.
- `stack_abandon` ends a stack that is no longer wanted. Members that never started go back to the backlog, a member in progress becomes `blocked`, and members already on the rollup branch stay listed on the stack.
- `epic_create`, `epic_list` and `epic_update` manage epics. `project_list` and `project_update` read and change projects, including their deploy configuration.

## Common mistakes

- **Leaving out dependencies to start a member early.** No member starts until every plan is approved.
- **Branching a member from the main branch.** Member branches come from the rollup branch. A branch that has drifted cannot be fast-forwarded; rebase it onto the rollup branch and call `stack_retry_member_merge`.
- **Opening a pull request per member.** The stack ships through its one rollup pull request.
- **Adding a deploy stage to a member's plan.** The rollup pull request is the deploy.
- **Using an epic to make tasks ship together.** Epics only group work. Use a stack.

_Last verified at 837fba6e._
