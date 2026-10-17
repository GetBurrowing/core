---
title: Skills
summary: Shared markdown playbooks, attached to a project, epic or task and sent with its work.
order: 9
verified_at: "837fba6e"
---

# Skills

## What it is

A skill is a markdown playbook: how work of one kind should be done. It might describe how to run a release, how to write a migration safely, or how a team wants its pull requests shaped. Each skill has a name, a slug made from the name, a one-line description and its markdown body. Skills are shared across the whole install, so one skill can serve every project.

### Attaching skills

A skill does nothing until it is attached. You can attach it at three levels:

- **Project:** applies to every task in the project.
- **Epic:** applies to every task in the epic.
- **Task:** applies to that task only.

Attach a skill to a project or an epic from the skill's page on the Skills page (`/skills`). Attach one to a single task from that task's detail panel, which also lists the skills the task already inherits from its project and epic.

### How skills reach an agent

When Burrow dispatches a task to an agent, it collects the skills attached to the task, its epic and its project, removes duplicates, and sends their full text with the dispatch. A skill attached at more than one level is sent once. The agent receives the playbook along with the task. It does not have to know the skill exists or look it up.

### The library

The Skills page lists every skill. Open one to read or edit its body and to see the projects and epics it is attached to. Agents can read the same library and publish to it with the skill tools.

## When to use it

- **A practice that applies to many tasks:** write it once as a skill and attach it to the project or the epic.
- **One task with an unusual requirement:** attach a skill to that task alone, or put the requirement in the task description.
- **Facts about your organization or its decisions:** write them to org memory. A skill says how to do something; it is not a record of what happened.
- **Before you start unfamiliar work:** check the library for a playbook someone has already written.

## How agents use it

- `skill_list` lists every skill with its slug, name, description and size, without the body. Pass `query` to filter by a word in the name, description or slug.
- `skill_get` returns one skill in full, by `slug` or by `id`. Pass exactly one of them.
- `skill_upsert` creates a skill, or replaces the body and description of the skill with the same name. The slug comes from the name.
- Attaching a skill is done by a person, on the Skills page or in the task detail panel. There is no agent tool for it.
- Skills attached to your task arrive with your dispatch. You do not need to fetch them.

## Common mistakes

- **Calling the tools by another spelling.** The skill tools are `skill_list`, `skill_get` and `skill_upsert`. Their old dotted names (skill.list) still work but are not listed; any other spelling is refused.
- **Overwriting a skill by accident.** `skill_upsert` replaces any skill with the same name. Read it with `skill_get` first, then edit.
- **Writing a skill nobody attaches.** An unattached skill is only in the library. If it should shape a project's work, ask a person to attach it.
- **Putting secrets or one-off context in a skill.** Every attached task's agent receives it in full. Keep skills reusable and free of credentials.

_Last verified at 837fba6e._
