# T4 migration guard: red/green demonstration on disk

Task 019fba52 stage 4. Evidence that the guard replacing
`@t4_allowed_new_migrations` actually fires, produced by putting real files in
`apps/platform/priv/repo/migrations` and running
`test/platform/org/wiki/context_t4_e2e_test.exs` against each one — not by
reasoning about what would happen.

Run against a scratch database (`PLATFORM_TEST_DATABASE=platform_test_019fba52_scratch`),
because `mix test` runs `ecto.create --quiet` + `ecto.migrate --quiet` first
(`mix.exs`, `aliases/0`) and would otherwise execute the throwaway migrations
against the shared `platform_test` DB and record them in `schema_migrations`.
Every throwaway carried an empty `change/0`.

Inventory re-derived by counting on this branch: **207 files, 95 historical
(below `20_260_520_000_000`), 112 admitted, 0 malformed names.**

Baseline with a clean tree: `12 tests, 0 failures`, exit 0.

## 1. Red when present and unadmitted

`mix ecto.gen.migration throwaway_admission_probe` →
`20260731233839_throwaway_admission_probe.exs`, 111 bytes, verbatim generator
output, no `@moduledoc`. Counts moved 207/112 → 208/113.

```
  1) test Case 5 — scope-creep guard every post-boundary migration documents itself and cites the work that admitted it (Platform.Org.Wiki.ContextT4E2ETest)
     test/platform/org/wiki/context_t4_e2e_test.exs:438
     Undocumented migration(s) at or above version 20260520000000:

       20260731233839_throwaway_admission_probe.exs
           (a) no @moduledoc of at least 40 characters
           (b) no task id / ADR number / PR number anywhere in the file
...
12 tests, 1 failure
```

Exit 2. The message names the offending filename and both things it lacks.

## 2. Green when admitted

Same file, same path, `@moduledoc` added — 130 trimmed characters, citing
`019fba52`. Still counted in `admitted` (113).

```
Running ExUnit with seed: 128071, max_cases: 16
Excluding tags: [:files_service, :cascade_repro]

............
Finished in 0.4 seconds (0.00s async, 0.4s sync)
12 tests, 0 failures
```

Exit 0 **with the throwaway still on disk**. This is the direction that shows
the guard is not simply always-red: admission is a property the file itself can
satisfy, by an edit to the file the branch just created and nothing else.

After `rm`, tree back to 207/95/112: `12 tests, 0 failures`.

## 3. The historical pin still bites

`20260101000000_throwaway_backdate_probe.exs`, back-dated below the boundary and
made fully compliant with the content property on purpose — valid filename shape,
202-character `@moduledoc`, cites `019fba52`. Historical count 95 → 96.

```
  1) test Case 5 — scope-creep guard the pre-T4-boundary migration inventory still matches T3 HEAD (Platform.Org.Wiki.ContextT4E2ETest)
     test/platform/org/wiki/context_t4_e2e_test.exs:325
     The pre-T4-boundary migration inventory changed.

     Expected below version 20260520000000: 95
     Actually found below it: 96
...
12 tests, 1 failure
```

Exit 2, and **one** failure, not two: the content property stayed green because
the file genuinely satisfies it. The pin is what catches a migration that hides
below the boundary, and it is the only thing that does. The two assertions catch
disjoint inputs — neither is redundant with the other.

After `rm`: `12 tests, 0 failures`.

## 4. The stray file

`touch priv/repo/migrations/notes.md`.

```
  1) ... the pre-T4-boundary migration inventory still matches T3 HEAD
     Unexpected file(s) in apps/platform/priv/repo/migrations:

       notes.md
...
  2) ... every post-boundary migration documents itself and cites the work that admitted it
     Undocumented migration(s) at or above version 20260520000000:

       notes.md
           (a) no @moduledoc of at least 40 characters
           (b) no task id / ADR number / PR number anywhere in the file
...
12 tests, 2 failures
```

Exit 2, both assertions. A name with no parseable version is deliberately placed
in `admitted` rather than dropped, so it is reported by the filename-shape
assertion *and* reaches the content property instead of vanishing between the two
halves. The shape assertion is load-bearing, not duplicate coverage.

After `rm`: `12 tests, 0 failures`, `git status --porcelain` empty.

## All four fired

No direction failed to produce its predicted failure, and none disagreed with the
predictions stage 3 recorded from its own on-disk runs.

## This task's own footprint

This task adds **no migration of its own**. That is why it can rewrite the guard
across a single branch without ordering trouble: if it had added one, that
migration would have had to enter the very inventory the task is changing, and
stages 1-3 would have had to be sequenced around it. The ordering was not
arbitrary.

## Merge note

A branch that appended to `@t4_allowed_new_migrations` will conflict. The
attribute is gone and must not be re-added. Resolve by dropping the list entry,
keeping the migration file, and giving that file a `@moduledoc` of at least 40
characters citing its task id / ADR / PR.
