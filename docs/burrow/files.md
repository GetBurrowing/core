---
title: Files
summary: Project documents - upload, text extraction, search, and files kept for people only.
order: 8
verified_at: "837fba6e"
---

# Files

## What it is

Files is each project's document store. A file belongs to one project. Burrow keeps the original bytes, extracts the text it can read, and indexes that text so agents can search it by meaning. People work with files on the Files page (`/files`); agents use the `files` tool bundle.

### Upload

- **People** drag files onto the Files page or use its upload button. Each upload has an **Include for agents** checkbox, checked by default.
- **Agents** call `file_add`. Pass the bytes as base64 for files up to 25 MB. For larger files, up to 500 MB, pass only the size: Burrow returns an upload URL, and you POST the raw bytes to it before it expires.
- An upload whose content matches a file already in the project is recognised as a duplicate and reuses the existing copy.

### Extraction

After upload, Burrow extracts text in the background. Each file carries two separate fields:

- `ingest_intent` is who the file is for: `attempt` (agents may read it) or `human_only` (people only).
- `ingest_status` is what extraction did: `pending`, `ingested`, `failed` or `not_attempted`.

Burrow reads PDF, Word (DOCX), Google Docs, CSV, plain text, Markdown and HTML. It reads text from PNG, JPEG and WebP images, and transcribes MP3, M4A, WAV, WebM and Ogg audio. PDFs and Google Docs keep a per-page split. A file in any other format is stored for people only by default, because there is nothing to extract.

When extraction fails, the row shows the failure and the Files page offers a retry, one file or all failed files at once. A file becomes searchable once its status is `ingested`.

### Files kept for people only

A file marked people only is stored and listed like any other, but agents never see its contents. `file_get_text` refuses it in both text and raw form, and search never returns it. On the Files page, the toggle on each file switches it between **Included for agents** and **People only**, in either direction and without a re-upload. Switching to people only removes its extracted text from agent search. Switching back extracts it again.

### Deleting

Deleting a file hides it everywhere and removes it from search at once. A person can undo it from the Files page for 30 days; after that it is purged.

## When to use it

- **Reference material the team works from** (specs, contracts, research, recordings): upload it to the project, so every agent working there can search it.
- **Something only people should read:** upload it with Include for agents unchecked.
- **A document you generated** (a report or an export): add it with `file_add` so it lives with the project rather than in a chat message.
- **Short notes or decisions:** write them to org memory instead. Files are for documents.

## How agents use it

- `file_list` lists a project's files, newest first, with each file's `ingest_status`, `ingest_intent` and whether its content is available to agents. Filter by content type if you need to.
- `file_search` finds files in one project by what they say, and returns snippets with the file ids.
- `file_get_text` returns a file's extracted text, the whole body or one page. Pass `binary: true` only when another tool needs the raw bytes.
- `file_get_metadata` returns one file's details (size, type, uploader, status) without its text.
- `file_add` uploads a file, and `file_delete` deletes one. There is no agent tool to undo a delete.
- `memory_search` with `memory_type: "document"` also reaches file text, alongside the rest of org memory.

## Common mistakes

- **Telling someone a file does not exist because you cannot read it.** A people-only file is still listed. Name it, quote the note that comes with it, and ask a person to describe what you need.
- **Reading a file before it is ready.** `file_get_text` has no text until the status is `ingested`. Check `file_list` first.
- **Taking an empty search as proof.** Search covers ingested files only. A file still pending or failed is not in it.
- **Deleting to free space.** A deleted file keeps its storage for the 30-day undo window.

_Last verified at 837fba6e._
