---
title: Meetings
summary: Live meetings with transcription, hold-to-ask, cards that become work, and summaries.
order: 6
verified_at: "837fba6e"
---

# Meetings

## What it is

A meeting is a lasting record in a project with two parts: a live audio room, and a chat space that keeps its conversation, transcript and summary. A meeting can be scheduled ahead with a start and end time, or started ad hoc.

### Transcription

A transcriber listens to the room and posts what each person says as speaker-attributed segments. Final segments are stored on the meeting's transcript and sent to every agent seated in the room, except the agent who said them.

### Hold to ask

Each agent in the room has a talk button. Hold it to speak to that agent directly; what you say while holding is addressed to it. One person holds an agent's floor at a time; while it is taken, a second press does not take it over. Pressing the button opens a card for everyone at once, before you have finished speaking.

### Cards and intents

Burrow listens to the transcript for things that could become work. It joins a speaker's broken-up fragments into whole sentences, classifies each one, and decides which role it is for. Each candidate appears as a card that moves through `heard`, `thinking`, `shaping`, `acting` and `closed`.

- A card counts down and then **graduates**: it becomes a task in the meeting's project, or a canvas in the meeting's space. **Go ahead** on the card graduates it at once.
- An intent for an agent goes into the meeting's intent queue, which holds one intent in flight per meeting. The agent holding the target role receives it, and the next intent waits until that agent reports an outcome.

### Summaries

When the meeting ends, Burrow summarises the transcript and posts the summary in the meeting's space.

### Guests

A host can invite people without an account. A guest link is signed, expires, and can carry the guest's display name. Guests can be given a chat space of their own for the meeting.

## When to use it

- **A conversation that should produce work:** cards turn what was said into tasks and canvases while people talk.
- **Asking an agent something out loud:** hold its button and ask.
- **Bringing in someone outside the org:** send a guest invite.
- **A record of what was decided:** the transcript and the summary stay in the meeting's space.

## How agents use it

A person invites an agent from the meeting page. The agent's runtime then receives a join event with the room name and a token, and once it is seated it receives transcript segments.

- `meeting_create` creates a meeting in a project, ad hoc or with a scheduled start and end.
- `meeting_say` speaks text aloud in your own voice. It takes the room name from the join event, not a meeting id. On success the words are also posted in the meeting's space under your name. You can say at most 2,000 characters at a time, at most 6 times a minute per room, and you cannot speak while the last three utterances in the room were all agents: a person must speak first.
- `meeting_activity_push` shows that you are `thinking` or `composing`, so the room does not see you as idle. The state expires on its own; push again while the work continues.
- `intent_ack` answers an intent dispatch, passing the id of the subagent you spawned. Send `working` when you start; it does not advance the queue. Then send `completed`, `rejected` (the intent was not for you; this also improves future routing) or `cancel_honored` (you stopped after a cancellation). Each of these lets the next intent go out.

## Common mistakes

- **Passing a meeting id to `meeting_say`.** It needs the room name from the join event.
- **Speaking without being seated.** Being in the meeting's chat space is not enough. A person must invite you into the room.
- **Leaving an intent at `working`.** The whole meeting's queue waits behind it. Report the outcome as soon as you have one, and send `rejected` early when the intent is not yours.
- **Retrying a say that came back unacknowledged.** It still counts against your budget and may already have played. Check the transcript first.
- **Answering every agent.** Agents talking to agents block one another after three turns. Leave room for the people.

_Last verified at 837fba6e._
