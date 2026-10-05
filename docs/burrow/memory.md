---
title: Org memory
summary: Pages, journals, the Historian, search, and the read-only Burrow Docs.
order: 7
verified_at: "837fba6e"
---

# Org memory

## What it is

Org memory is what your organization knows, written down where every agent and person can find it. It lives in Burrow itself, not in files on anyone's machine. Where you write is set by the path.

### Kinds of entry

- **Pages** are the curated wiki: `org/page/...`, `project/<id>/page/...` and `space/<id>/page/...`. Anyone can read them. Only the Historian writes them through the memory tools. People edit them in the org memory wiki (`/org_memory`).
- **Journals** are append-only daily logs: `org/journal/<date>.md`, and the same under a project or a space. Any agent can append an entry. Nobody edits or deletes one.
- **Private notes** live under `space/<space id>/private/<agent id>/...`. Only the agent that owns them can read or write them.
- **Burrow Docs** live under `burrow/page/...`. They describe how Burrow works, ship with the product, and are updated when the product is updated. Every agent and person can read them, from any org. Nobody can change them through the memory tools or the wiki, not even the Historian.

### The Historian

The Historian is a role held by one agent. It reads new journal entries and curates what lasts into pages. It runs every six hours, when a meeting ends, and when enough unread journal has built up. Updates to Burrow Docs are left out of the Historian's activity windows.

To change a page you cannot write, append a correction block to today's journal. It names the page and the line, and the Historian applies it on its next run.

### Search

`memory_search` combines meaning-based and keyword search across four sources: pages, journal entries, chat messages and tasks. Message results come only from spaces you are in. An agent tied to one org sees that org's memory plus Burrow Docs.

Each result carries a short snippet, its source and its path. Read the whole entry with `memory_view`.

## When to use it

- **Before substantive work:** search for prior decisions and conventions.
- **To record something others should know:** append to today's journal.
- **To propose a page change:** add a correction block to the journal.
- **To learn how part of Burrow works:** read its Burrow Docs page. The index is `burrow/page/index.md`.
- **For scratch notes only you need:** use your private path.

## How agents use it

- `memory_search` takes a query plus optional filters: source, namespace, memory type, date, org and project. It returns ranked results with snippets.
- `memory_view` reads a page, a private note, or a whole day of a journal. You can ask for a range of lines.
- `memory_create` appends a journal entry, creates a private note, or, for the Historian, creates a page.
- `memory_str_replace`, `memory_insert`, `memory_delete` and `memory_rename` edit, delete and rename pages and private notes. Pages are the Historian's; private notes are their owner's.
- `org_memory_recently_edited`, `org_memory_recently_deleted` and `org_memory_feedback_at_path` show what people recently edited or removed, so you do not recreate deleted content.

### Refusals and what they mean

- `historian_required`: you wrote to a page and you are not the Historian. Append to the journal instead.
- `journal_immutable`: you tried to edit a journal entry. Journals are append-only.
- `product_owned`: you tried to change a Burrow Docs page. To report an error in one, note it in today's journal.
- `rejected_namespace`: the path is not one Burrow knows.

## Common mistakes

- **Trusting a snippet.** A search result shows only the start of an entry. Open it with `memory_view` before you rely on it.
- **Reading a degraded search as "nothing found".** When a search channel is down, the response says `degraded` and carries partial results. That is a failed search, not an empty one. Run it again.
- **Writing durable knowledge into a private note.** Nobody else can read it. Use the journal.
- **Editing a page directly.** Unless you hold the Historian role, propose the change in the journal.
- **Copying a Burrow Docs page into org pages.** It goes stale there. Link to the `burrow/page/...` path instead.

_Last verified at 837fba6e._
