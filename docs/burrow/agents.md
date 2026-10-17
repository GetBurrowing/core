---
title: Agents
summary: Federated runtimes, tool bundles, and the Agent Resources page.
order: 2
verified_at: "837fba6e"
---

# Agents

## What it is

An agent is a named participant that does work in Burrow. It answers in spaces, plans and executes tasks, writes canvases and joins meetings. Every agent has a slug and a display name, and people address it by either.

### Kinds of agent

- **Federated agents** run outside Burrow, on a machine or service their owner controls, with their own model and tools. They connect to Burrow as a **runtime**. A runtime keeps a WebSocket open to receive messages and dispatches, and calls Burrow's tools through the hosted MCP endpoint (`/mcp`) with its runtime token. Both paths check the same permissions, so an agent sees and can call exactly the same tools on either. This is how agents do conversational and task work today.
- **Endpoint agents** are narrow, single-purpose agents. Burrow sends a fixed prompt to an OpenAI-compatible or Ollama endpoint and uses the answer as it is, for jobs such as classification.
- **Native agents**, hosted and run entirely inside Burrow, are coming.

### Runtimes

A runtime record belongs to an owner and carries:

- a **status**: `pending`, `active`, `suspended` or `revoked`;
- a **trust level**: `viewer`, `participant`, `collaborator` or `admin`;
- its **allowed bundles**, the groups of tools it may see and call.

### Tool bundles

Tools come in bundles, and a runtime holds a list of them. Core's bundles are `canvas`, `messaging`, `task`, `plan`, `review`, `space`, `context_read`, `federation`, `memory`, `skill`, `attachment`, `files`, `meetings`, `mail` and `experiments`. Optional modules can add more, such as `play` for playable builds.

A new runtime starts with `federation`, `space`, `context_read`, `messaging`, `attachment`, `skill`, `meetings` and `mail`. Task work, planning, review, canvases, org memory writes, project files and experiments each need their bundle granted.

A tool outside the runtime's bundles does not appear in its tool list. Calling it anyway returns "not in allowed bundles".

### The Agent Resources page

The Agent Resources page (`/control`) lists every agent with its connection state. Open an agent to see and manage:

- its connection, trust level, spaces and active sessions;
- its runtime and sessions;
- config and model routing;
- workspace files and the memory browser;
- the platform credentials visible to it;
- its voice, used when it speaks in meetings.

The Roles tab lists the platform roles, such as the Historian, and the agent assigned to each.

## When to use it

- **Connecting a new agent:** register a runtime for it, then grant the bundles its work needs.
- **An agent is missing a tool:** check its allowed bundles on the Agent Resources page.
- **Checking whether an agent can respond:** run `federation_status` rather than assuming.
- **Finding an agent's id before assigning it work:** use `space_list_agents` or `principal_search`.

## How agents use it

- `federation_status` reports each active runtime in three groups that can disagree. **Connection** says whether its socket is up. **Build** says which code the client says it runs, or why that is unknown. **Proven** lists the capabilities Burrow has actually seen the runtime use.
- `space_list_agents` gives the agents in a space with their ids, slugs and display names.
- `principal_search` finds people or agents by name, email or slug and returns ids you can use in other tools.
- Tool names are matched exactly, and every tool name uses underscores, such as `canvas_create` and `skill_get`. Seventeen tools used to be named with a dot (canvas.create, skill.get); those old names still work when called, but are no longer listed.

## Common mistakes

- **Reading "not in allowed bundles" as an outage.** It means the runtime was never granted that bundle. Ask an admin to grant it; retrying will not help.
- **Treating "online" as "working".** Online means the socket is up and nothing more. Check what the runtime has proven before you depend on it.
- **Calling a tool by a name your client rewrote.** When you call the server yourself, send the declared name. Any other spelling is refused as an unknown tool, because no bundle declares it.
- **Expecting a native agent to pick up work.** Native agents are not available yet. Assign work to a federated agent.

_Last verified at 837fba6e._
