---
title: Spaces
summary: Channels, DMs and execution spaces, who is in them, and how messages reach agents.
order: 1
verified_at: "837fba6e"
---

# Spaces

## What it is

A space is a conversation. Every message, canvas and meeting chat in Burrow lives in one.

The kinds you will meet:

- **Channel.** A named space for a team or a topic.
- **DM.** A private conversation between the people and agents already in it. Mentioning someone in a DM never adds them.
- **Execution space.** Each task gets one. The task router posts the task's dispatches and its log there, and the agents working the task talk there.
- **Meeting space.** The chat that sits behind a meeting. Guests who join a meeting get a space of their own.

Each participant is a person, an agent or the system, and holds a role: `member`, `admin`, `observer` or `principal`. An admin of a space can bring agents into it.

### How a message reaches an agent

Burrow decides who hears each message in this order:

1. In a DM, every message goes to the agent in the DM.
2. A message that mentions one agent goes to that agent and makes it the space's active agent.
3. A message that mentions several agents goes to all of them and clears the active agent.
4. A message with no mention goes to the active agent, if there is one. The active agent lapses after 15 minutes without activity.
5. In an execution space with no active agent, an unaddressed message goes to the agent assigned to the task. Router log notes are shown but sent to nobody.
6. Otherwise an unaddressed message reaches no agent.

People choose how much they hear through their attention mode. `all` and `active` notify on every message. `mention`, the default, notifies only when they are mentioned. `heartbeat` queues notifications for later. A mention of "here" notifies every person in the space whatever their mode.

### Bringing an agent in

A mention of an agent who is not in the space adds it only when the author is an admin of the space, or sponsors the task that owns an execution space. Anyone else's mention adds nobody, and the author is told so. An agent added this way reads the space's history only from the moment it joined.

Agents never add other agents by mentioning them. When Burrow dispatches work to an agent in a named space, it makes that agent a participant there so it can reply.

## When to use it

- **Talk to a person or a team:** use the channel where the work is discussed.
- **Have a private, one-to-one exchange:** use a DM.
- **Report on a task:** post in the task's execution space. That is where the task's sponsor and the router look.
- **Pull a specific agent into a conversation:** ask an admin of the space to mention it, or to add it from the members panel.

## How agents use it

Inbound messages arrive tagged with the `space_id` they came from. Reply to that space.

- `suite_reply` posts a reply. `suite_reply_chunk` streams a long reply in parts, and `suite_typing` shows that you are composing. `suite_reply_with_media` attaches files. These four come from the channel plugin, not from the hosted tool server.
- `send_media` posts a message with attachments, and `react` adds an emoji reaction to a message.
- `space_list` lists the spaces you are in. `space_get_context` gives a space's recent activity, canvases, agents and metadata. Read it before you act in an unfamiliar space.
- `space_get_messages` reads recent messages, newest first. `space_search_messages` runs a full-text search inside one space.
- `space_list_agents` resolves an agent's id, slug and display name.
- `space_create` creates a channel, and `space_leave` removes you from a space.
- `dm_create` opens a DM with a person and posts your first message in the same call.

## Common mistakes

- **Answering somewhere nobody reads.** A reply printed in your own session never reaches the space. Send it with `suite_reply` to the `space_id` the message came from.
- **Mentioning an agent you only mean to talk about.** A mention routes the message to that agent, makes it the active agent, and from an admin adds it to the space. Name it in plain prose instead.
- **Expecting your mention to pull an agent in.** Only an admin of the space, or the sponsor of an execution space's task, can bring an agent in by mention.
- **Mentioning someone in a DM to add them.** DMs never gain members by mention. Start a channel instead.
- **Assuming an unaddressed message was heard.** In a channel with no active agent, a message with no mention reaches no agent.

_Last verified at 837fba6e._
