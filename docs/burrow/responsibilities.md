---
title: Responsibilities
summary: Recurring agent duties, the roles that hold them, and how their dispatches arrive.
order: 10
verified_at: "837fba6e"
---

# Responsibilities

## What it is

A responsibility is a duty Burrow carries out on its own, without anyone filing a task: summarizing a meeting when it ends, reviewing a plan when it is submitted, curating org memory every few hours. Each one has a dotted key such as `meetings.summarize` or `architecture.review_plan`, a trigger, and a prompt that tells the agent what to do.

### Triggers

A responsibility fires on one of four kinds of trigger:

- **cron:** a schedule, such as a weekly review.
- **event_topic:** something happening in Burrow, such as a stage completing or a meeting ending.
- **chat_pattern:** a chat message that matches a pattern.
- **webhook:** an inbound call from outside Burrow.

Responsibilities are declared by the product and registered when Burrow starts. You do not create them; you decide who holds them.

### Roles

Responsibilities are grouped into **roles**. Each role bundles a fixed set of responsibilities, and one agent holds each role. The roles are:

- **Designer:** design critique, specs and brand checks.
- **Historian:** org memory curation and meeting decisions.
- **Meeting Producer:** classifying what people ask for in a live meeting.
- **Meeting Scribe:** meeting summaries, action items and follow-ups.
- **Triage Officer:** task triage, unblocking and the weekly review.
- **Security Guard:** periodic scans for vulnerable dependencies, risky code, deploy configuration and leaked secrets.
- **Architect:** plan review, drift audits and a weekly sweep.
- **Agents Leader:** the agents space's goal and its daily measurement.
- **Scientist:** running experiments and labelling their signals.

Assign roles on the Roles tab of the Agent Resources page (`/control`). A role holds one agent at a time; to hand it to another agent, unassign it first. Under the advanced view you can also override a single responsibility, so one agent handles that duty while the rest of the role stays with its holder.

### Who gets the dispatch

When a responsibility fires, Burrow finds its agent: the per-responsibility override if one is set, otherwise the agent holding the role whose bundle contains it. If nobody holds it, nothing is sent and the duty goes undone.

## When to use it

- **Work that must happen every time something occurs**, such as summarizing each meeting: it is already a responsibility. Make sure its role is held.
- **A duty going undone:** check the Roles tab. An unfilled role is the usual cause.
- **One-off work:** file a task. Responsibilities are only for duties Burrow already declares.
- **Moving a duty to a better-suited agent:** reassign the role, or override that one responsibility.

## How agents use it

- A responsibility dispatch reaches a federated agent's runtime as a **system event** rather than a chat message. It names the responsibility key, and it carries the rendered prompt plus, when the duty concerns a space, that space's id. A duty triggered by a chat pattern arrives the way a mention does.
- Read the key to know which duty fired, follow the prompt, and reply or write where it says: in the named space with `suite_reply`, as a canvas, or in org memory.
- Some dispatches say there is nothing to do this time, for example a meeting with no transcript. Acknowledge them and stop.
- `federation_status` shows whether your runtime is connected. A dispatch to an offline runtime is recorded, and the ones still worth doing are delivered when it reconnects.
- Agents do not assign roles. A person does that on the Agent Resources page.

## Common mistakes

- **Treating a system event as idle chatter.** It is assigned work, the same as a task.
- **Expecting a task for every duty.** Responsibilities run without tasks. Look for the system event, not a task assignment.
- **Leaving a role empty and expecting the duty to happen.** An unfilled responsibility fires and reaches nobody.
- **Giving a role to an agent that is rarely online.** Duties fire on their own schedule. A holder that is offline when they fire does them late or not at all.

_Last verified at 837fba6e._
