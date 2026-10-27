# Deleted guards (task 01a17ac3, stage 3)

One line per deleted source-reading guard: test file:line, construct, reason,
proof command. A guard is deleted only when the construct it forbids cannot
come back: (a) the module, file or function it guards is gone, shown by an
empty `git grep`, or (b) the compiler rejects it under
`mix compile --warnings-as-errors`, with the error text reproduced by planting
the construct once.

| test file:line | construct | reason | proof command |
|---|---|---|---|
| (none) | | | |

## Why the table is empty

No guard met either bar.

- The "removed names" guards (`message_actions_removed_test.exs`, the
  `@gone` list) have an empty `git grep` today (for example
  `git grep -n longpress_menu -- apps/platform/lib apps/platform/assets` is
  empty). That is the property the guard holds, not a reason to remove it.
  The construct is a string any commit can reintroduce, and no compiler check
  rejects a string or comment. Deleting the guard would let it return.
- The T3/T4/T5 `*_forbidden_paths` scope guards (`indexer_t3_e2e_test.exs:244`,
  `context_t4_e2e_test.exs:227`, `tool_surface_t5_e2e_test.exs:342`) forbid
  files that do not exist. Neither bar applies: the file is not "gone", it was
  never added, and a new file at that path would be legitimate.

## Recommendations (not deleted; need an owner's decision)

- `system_event_scheduler_t6_e2e_test.exs:845` and `:871`: `@tag :skip`
  (superseded by ADR 0042). They never run, so deleting them loses no
  coverage, but they shell out to `git diff origin/main`, which is branch
  relative, so neither bar (a) nor (b) applies. Recommend deletion.
- `chat/edit_permissions_test.exs:192`: `@tag :skip`, body is `assert true`.
  Guards no construct. Recommend deletion.
- `tool_surface_files_e2e_test.exs:269` (`:files_service`) and
  `task_supervisor_ownership_leak_test.exs` (`:cascade_repro`) are always
  excluded by tag. Not source guards; left alone.
- `candidate_rail_test.exs:613` (`:pending_fix`): owned by another task, left
  alone.

## Guards that shell out to `git` (flagged, unchanged)

A `git` failure inside the CI job container (no `.git`, or dubious ownership)
exits 128.

- `test/platform/regression/burrow_env_fallback_guard_test.exs:88`:
  `{out, 0} = System.cmd("git", ... "ls-files" ...)` crashes, not skips, on a
  non-zero exit. It passes `-c safe.directory=...` to survive the ownership
  case, but a missing `.git` still crashes.
- `test/platform/federation/tool_surface_t5_e2e_test.exs:364` and `:427`:
  `git ls-tree` / `git diff`; skip silently on non-zero.
- `test/platform/agents/system_event_scheduler_t6_e2e_test.exs:850`, `:877`:
  skipped tests (see above).

## Kept guards made cheaper

`Platform.TestSupport.SourceIndex` (`apps/platform/test/support/source_index.ex`)
is a read-only per-VM cache of `Path.wildcard/2` listings and `File.read!/1`
contents (`:persistent_term`, a file is re-read if its mtime or size changed).
It uses `File`/`Path` only, no `git`. Consumers keep their patterns and globs;
only the call that reads changed.

| module | before (local, 2 modules together) | after |
|---|---|---|
| `extension_boundary_test.exs` + `lazy_html_selector_guidance_audit_test.exs` | 128.1 s | 24.1 s |
