defmodule Platform.TestQuarantine do
  @moduledoc """
  The registry of tests this suite knows are not trustworthy, and *why*.

  ## Why this exists

  Until 2026-07-26 the whole mechanism was one line in `test/test_helper.exs`:

      ExUnit.start(exclude: [:files_service, :cascade_repro])

  Two tags, one shared bucket, no schema, no owner, no class. That single
  bucket is how task `019fa06a` survived multiple briefs. Its target test —
  `Mix.Tasks.Platform.CleanupGhostTasksTest` "live task with active router +
  lease" — failed **19 of 30 file-isolated runs (63%) on the merge-base tree**,
  and appeared in **1 of 2** baseline full-suite runs. It was a real defect, not
  a flake: this branch takes it to 0/30 isolated and 0/2 full-suite. But it
  raised a `DBConnection.OwnershipError`, the same *symptom* as a known flake
  class, so every agent that met it recognised the shape and moved on instead of
  investigating. Three separate production defects were eventually found
  underneath that pattern-match (`019fa06a`, `019fa003`, `019f9d80`).

  An earlier revision of this paragraph said the test "failed 5/5 in isolation
  and 3/3 at the branch point" and "never flaked once". Those were small samples
  taken under unknown load, and the 63% figure above — measured across 30 seeds
  on a quiet box — is what they were estimating. Correcting it here rather than
  quietly dropping it is the point: asserting determinism from a handful of runs
  is the same reasoning error CORRECTION 1 catches in the `task_router_test.exs`
  safety-net entry below. The registry's thesis does not need the test to have been
  deterministic; it needs the *cause* to have been, and it was.

  The generalised finding, from `org/journal/2026-07-26.md`:

  > The intermittency was real; the inference "therefore flake" was wrong.
  > *Intermittent surfacing* is not the same as a *nondeterministic cause*.
  > An order-dependent bug is fully deterministic given an order, and looks
  > exactly like a flake through the lens of a randomised runner.

  A category that absorbs unexplained failures will always fill up with real
  bugs. So this registry splits the bucket by **cause**, and — the one rule
  that makes it load-bearing rather than documentation that rots —
  `excluded_tags/0` derives the ExUnit exclusion list from the class. An entry
  whose cause is deterministic or unknown is *structurally incapable* of being
  hidden by the exclusion mechanism. Not "we'll remember to check": the wrong
  thing is impossible, not merely discouraged.

  ## Classes

    * `:intermittent` — the **cause** is nondeterministic: timing, scheduling
      or contention on a shared resource. Excluding it is a reasonable trade.
      **Excludable.** A `:reason` must name the contended resource.

    * `:environment` — fails on a property of the box, the clock, or missing
      infrastructure, not on the code. Not a flake at all. **Excludable.**
      A `:ticket` is optional for this class.

    * `:deterministic` — the **cause** is deterministic: the test fails on
      every run of some fixed scope or order. It may still *appear*
      intermittent in a randomised full-suite run — that is surfacing, not
      cause, and it is exactly the confusion this registry exists to end.
      A test that passes only because another test leaked state into it is
      **broken**, not flaky. **Never excludable. Must carry a ticket.**

    * `:unexplained` — observed to fail; cause not yet bisected. This class
      exists because "unexplained" and "intermittent" are different claims,
      and collapsing them is how `019fa06a` started. Recording a failure as
      `:intermittent` asserts you know the cause is a race. If you do not,
      say so here. **Never excludable.** It *should* acquire a ticket.

  `excluded_tags/0` returns tags for `:intermittent` and `:environment` only.

  ## Entry schema

  Each entry is a map with exactly these keys:

    * `:tag` — the ExUnit tag that identifies the test, or `nil`.
    * `:test` — human locator, `"<path>: <test name>"`. Keyed on test **name**,
      not `file:line`: `019fa121` shifted every line in `task_router_test.exs`
      by +89 with a single comment block, so line numbers are not a stable key.
    * `:class` — one of `classes/0`.
    * `:ticket` — owning task id, or `nil` where the class permits.
    * `:reason` — why it fails, with the evidence. Prose, not a label.
    * `:added_on` — `Date`.

  ### `:tag` may be `nil`, and that means something

  An entry with a `nil` tag is **recorded but not gated**: the test still runs
  in the default suite. Most entries here are like that, deliberately — the
  point of writing them down is so the next reader does not re-diagnose them
  or, worse, dismiss a real regression as "the known flake". Only an entry
  that is *both* excludable by class *and* carries a real ExUnit tag actually
  disappears from `mix test`. See `recorded_only/0`.

  Adding a tag to a `:deterministic` or `:unexplained` entry is still useful:
  it makes the test runnable on demand (`mix test --only <tag>`) without ever
  making it excludable.

  ## What does NOT belong here

  A test that currently passes. `CleanupGhostTasksTest` — the incident that
  produced this module — is deliberately absent: stages 1 and 2 of `019fa06a`
  fixed it, so it earns no entry, and adding it would violate the invariant
  that every entry names a test the suite cannot currently trust. Its history
  belongs in the commit log and the journal, which is where it is.

  ## Known follow-up (deliberately not built here)

  A `mix platform.test_quarantine` task that re-runs every entry N times and
  reports drift — an `:intermittent` entry that now passes 20/20, or one that
  now fails 20/20 and should be reclassified `:deterministic`. That is what
  would have caught `019fa06a` automatically. It needs a decision about CI
  wiring and runtime budget, so it belongs in its own task.
  """

  @classes [:intermittent, :environment, :deterministic, :unexplained]

  # The whole point of the module. Adding a class here makes it hideable;
  # removing one makes it loud. Nothing else in the codebase decides this.
  @excludable_classes [:intermittent, :environment]

  @required_keys [:tag, :test, :class, :ticket, :reason, :added_on]

  @entries [
    # ── :environment ────────────────────────────────────────────────────
    %{
      tag: :files_service,
      test:
        "test/platform/federation/tool_surface_files_e2e_test.exs: " <>
          "[Case B] file_get_text on uploaded PDF returns the verbatim phrase from files-service",
      class: :environment,
      ticket: nil,
      reason: """
      PROVENANCE: tag confirmed present here (`tool_surface_files_e2e_test.exs:272`);
      exclusion dates from #466. Behaviour unchanged by this stage.

      Requires the files-service sidecar. The test `flunk/1`s outright when
      `FILES_SERVICE_URL` is unset, which is the default for every developer
      box and for CI. Nothing about the code under test is broken — the
      dependency simply is not running. This is not a flake and never was;
      it was only ever filed next to one because there was one list.
      """,
      added_on: ~D[2026-06-25]
    },
    %{
      tag: nil,
      test:
        "test/platform/agents/historian_dispatcher_test.exs: " <>
          "(a) 120KB transcript, tight-range oversize path stamps day_bytes on today",
      class: :environment,
      ticket: nil,
      reason: """
      PROVENANCE: failure inherited (019f9d80 stage 2 and the 019f9b29-5ecd
      stack, independently). The MECHANISM was re-derived here by reading
      `historian_dispatcher_test.exs:403` directly — the filter really does key
      on `one_hour_ago` while the message interpolates `today_utc`.

      Fails for ANY run started inside the 00:00–01:00 UTC hour, on every
      branch. The assertion filters drained telemetry by the UTC date of
      `one_hour_ago` while the seeded data and the `day_bytes` histogram key
      on the UTC date of `now`. Inside that hour the two dates differ and the
      filter matches nothing — the failure message even says "on 2026-07-27"
      while filtering for `2026-07-26`. Confirmed independently by two agents:
      3/3 RED on an untouched `b19eee64` control at 00:47 UTC, 3/3 GREEN on
      the same tree at 01:05 UTC.

      Clock, not code — hence `:environment`. Not excluded: outside that hour
      it is a real, passing assertion and excluding it would cost coverage for
      23 hours a day. The fix is one line (filter on today's UTC date, or pin
      the cursor inside a single UTC day).
      """,
      added_on: ~D[2026-07-26]
    },
    %{
      tag: nil,
      test:
        "test/platform/execution/local_runner_test.exs: " <>
          "setup_git_worktree is idempotent when called twice",
      class: :environment,
      ticket: nil,
      reason: """
      PROVENANCE: failure inherited; mechanism re-derived here by reading
      `local_runner_test.exs:440` (`temp_dir/1`) directly.

      `temp_dir("wt-idempotent")` builds its path from
      `System.unique_integer([:positive, :monotonic])`, which restarts near 1
      in every fresh BEAM. So run N+1 reuses `/tmp/wt-idempotent-1` left behind
      by run N, and `setup_git_worktree` meets a worktree it did not create.

      Clear `/tmp/wt-idempotent-*`, `/tmp/git-repo-*` and `/tmp/wt-root-*`
      before a run and it passes. Box state, not code.

      Do NOT extend this diagnosis to the other `LocalRunnerTest` entry below —
      that one was reproduced *with* those directories cleared, and assigning it
      to this neighbouring cause is precisely the habit this registry exists to
      break.
      """,
      added_on: ~D[2026-07-26]
    },

    # ── :intermittent ───────────────────────────────────────────────────
    %{
      tag: :cascade_repro,
      test:
        "test/platform/regression/task_supervisor_ownership_leak_test.exs: " <>
          "(whole module, @moduletag :cascade_repro)",
      class: :intermittent,
      ticket: "019f3440",
      reason: """
      PROVENANCE: moved verbatim from the 31-line comment block that sat above
      `ExUnit.start/1` in `test_helper.exs` until this stage. Not re-measured
      here — the rationale travels with the data now instead of sitting as a
      comment above a line it only half explained.

      `:cascade_repro` tags the deterministic repro for the 2026-07-03
      DBConnection.OwnershipError cascade (task 019f3440).

      History worth knowing: the exclusion was added by stage 1 of PR #485 while
      the test was intentionally red, and the fix it guards landed in stage 2 of
      that SAME PR — but the exclusion was never lifted. The repro has therefore
      been dark ever since, which is how a regression of this fix would go
      unnoticed.

      It is STILL excluded, but for a different and narrower reason than before.
      Measured on `fix/test-suite-flakes` (2026-07-20):

        * `mix test --only cascade_repro`  -> PASSES. The stage-2 fix is intact.
        * inside the full parallel suite   -> FAILS intermittently, on assertion
          (B) only ("transcript reaches a terminal state"). Assertion (A), the
          actual leak guard (`exit_reason == :normal`), passes.

      Assertion (B) depends on `Summarizer.safe_fail_transcript/1`'s
      `try_borrow_sandbox/0` recovery — a TEST-ONLY hack that reaches for a
      DataCase-allowed singleton's sandbox connection so the terminal-status
      write can land from an unowned process. Under a full parallel run that
      singleton is frequently allowed to a DIFFERENT case's sandbox, the borrow
      returns `:no_sandbox`, and the transcript stays "processing". So (B) is
      asserting on scaffolding, not on production behaviour — in production
      `fail_transcript/1` simply succeeds and no borrow is involved.

      Un-excluding it as-is would trade a silent-regression risk for a ~50%
      flaky test in CI, which is a worse deal. The real fix is to drop or
      rewrite assertion (B) so the test depends only on (A) and (E), both of
      which are parallel-safe, and then delete this exclusion for good.
      Until then, run it explicitly: `mix test --only cascade_repro`.

      Contended resource: the DataCase-allowed singleton's sandbox connection.
      """,
      added_on: ~D[2026-07-20]
    },
    %{
      tag: nil,
      test: "test/platform/orchestration/task_router_test.exs: (whole file)",
      class: :intermittent,
      ticket: "019fa121",
      reason: """
      PROVENANCE: 15-run harness inherited from 019fa121 stage 1; partially
      corroborated here (5 file-scope runs on `31fe9474` after the box quieted:
      0 failures at seeds 0, 7, 13, 42 and 3 failures at seed 99, three
      different tests). Note the contrast with the pre-quiet numbers below —
      this file's failure rate is a function of box load, so any figure quoted
      from it must carry the load it was taken under.

      Read this before writing off any full-suite failure: this file is a
      SOURCE of the suite's noise floor, not a victim of it.

      116 fixed `Process.sleep` calls (11.1s of pure sleep per run) across 66
      tests. Measured over 15 runs (5 seeds x 3 reps) on a pristine control
      worktree: **0 of 15 green**, 84 failures, 17 distinct tests, and
      membership drifted at 5 of 5 seeds — a fixed seed does not reproduce a
      fixed failing set, so the cause is timing, not ordering. Failure count
      tracks sleep count per file: this file 116 sleeps / 71 failures, while
      both zero-sleep files in the same family were clean across all 15 runs.

      It fails MORE on unmodified `main` (5–6) than on a fixed tree (3), so a
      branch that shows failures here is not thereby implicated.

      Contended resource: the scheduler. Task `019fa121` owns the conversion to
      `TaskRouter.current_status/1` mailbox barriers, which its stage-1 analysis
      shows makes all 116 removable in principle.

      Not excluded: 66 real tests would go dark, and one of its cases is a
      genuine `:deterministic` entry (below) that must stay loud.
      """,
      added_on: ~D[2026-07-26]
    },
    %{
      tag: nil,
      test:
        "test/platform/orchestration/task_router_test.exs: " <>
          "safety-net fire: deadline in the past → single loud broadcast + blocker post",
      class: :intermittent,
      ticket: "019fa121",
      reason: """
      PROVENANCE: measured here, on `31fe9474`, isolated DB, 2026-07-27. The
      classification was CHANGED mid-stage by that measurement — read the
      correction below before quoting this entry, because it is the clearest
      worked example in the registry of how the classes get confused.

      Symptom, run alone (`task_router_test.exs:758`):
      `** (BadMapError) expected a map, got: nil` at `:776`,
      `{task.id, %{lease | safety_net_at: past_deadline}}`.
      `LeaseManager.get(task.id)` returned `nil` because the router's own lease
      write had not landed within the fixed `Process.sleep(75)` above it.

      Measurements, alone, 10 seeds 0–9: **4 RED / 10**. Whole file, 5 seeds
      (0, 7, 13, 42, 99): 0 failures in 4 of 5 runs; the one failing run
      (seed 99, 3 failures) did NOT include this test.

      CORRECTION 1 — it is NOT deterministic. An earlier pass in this same
      stage recorded 3/3 RED alone and filed it `:deterministic`. That pass ran
      while four orphaned `while :; do :; done` busy-loops (PPID 1, ~250% of a
      core, 3h20m old) were saturating the box. Once those were reaped the same
      command at the same seeds fell to 4/10. **A failure rate measured under
      unknown load is not evidence of a class.** Repeat count, not seed match,
      is what separates these two classes in the `TaskRouter*` cluster.

      CORRECTION 2 — the mechanism is not leaked state. The standing note said
      this test "passes under the full suite because another test's LeaseManager
      write leaks in". That is structurally impossible:
      `:orchestration_lease_manager` is keyed by `task_id`
      (`lease_manager.ex:314`) and the module `setup` mints a fresh
      project/task/plan/stage per test, so no sibling can write THIS row. What
      differs between scopes is how much CPU the router gets in its first 75ms.

      Contended resource: the scheduler. Owned by `019fa121`, whose
      sleep-to-`current_status/1`-barrier conversion removes the cause rather
      than lengthening the sleep. Not excluded (tag `nil`): the assertion is
      real and worth keeping loud until that lands.
      """,
      added_on: ~D[2026-07-26]
    },

    # ── :deterministic ──────────────────────────────────────────────────
    %{
      tag: :leaked_telemetry_detach,
      test:
        "test/platform/accounts/external_admission_notifier_test.exs: " <>
          "a holding event persists an Audit.Event (durable queue source)",
      class: :deterministic,
      ticket: "019f9d80",
      reason: """
      PROVENANCE: re-measured here on `31fe9474`, isolated DB, 2026-07-27,
      after the box was quiet. Confirms the 019f9d80 stage-1 diagnosis.

      On the standing known-flakes list for weeks. It is not a flake:

        * `audit/historian_latency_test.exs` + this file in ONE BEAM —
          **5/5 RED** at seeds 0–4, always this same test.
        * this file ALONE — **3/3 GREEN** at seeds 0–2.

      Load-independent, unlike the `:intermittent` entries above: the two
      scopes give 100% and 0% regardless of how busy the box is. Deterministic
      given a scope, invisible in a randomised full run — which is precisely
      how "intermittent surfacing" gets misread as "nondeterministic cause".

      Cause: five test files `:telemetry.detach/1` a boot-attached handler and
      never restore it (`audit/historian_latency_test.exs`,
      `audit/telemetry_handler_test.exs`,
      `federation/tool_surface_alarm_silence_test.exs`,
      `meetings/telemetry_handler_test.exs`, `vault/telemetry_handler_test.exs`).
      Every audit path that emits via `:telemetry.execute` afterwards silently
      drops its row. An audit assertion that passes because nothing is listening
      is indistinguishable from one that passes because the system behaved.

      Operational consequence, which matters more than the diagnosis: **a green
      full suite is not evidence this is fixed.** Verification has to be the
      pair in one BEAM. `--trace` shows CLI argument order does not control
      ExUnit execution order, so the invariant is "same BEAM", not "this order".

      Deliberately tagged rather than left anonymous:
      `mix test --only leaked_telemetry_detach` runs it on demand. The tag can
      never exclude it — `excluded_tags/1` filters on class before it ever
      looks at the tag.

      Fix landed on `task/019f9d80` (idempotent `attach/0` + an unconditional
      re-attaching `on_exit`), pair 10/10 RED before and 10/10 GREEN after. Not
      on `main` as of `b19eee64`. **Delete this entry and its tag when that
      merges** — leaving it here afterwards guarantees the next agent dismisses
      a real failure.
      """,
      added_on: ~D[2026-07-26]
    },

    # ── :unexplained ────────────────────────────────────────────────────
    %{
      tag: nil,
      test:
        "test/platform/execution/local_runner_test.exs: " <>
          "injects credential lease env into the child process",
      class: :unexplained,
      ticket: nil,
      reason: """
      PROVENANCE: inherited from 019f9d80 stage 1. NOT re-measured here — which
      is itself part of the entry: nobody has bisected this, including me.

      Cause unknown. Recorded honestly rather than assigned to a neighbour.

      Observed: RED at control seeds 1 and 2, GREEN at seed 0, **with**
      `/tmp/git-repo-*` and `/tmp/wt-root-*` cleared before every run. Shape is
      `assert String.trim(File.read!(output_file)) == "test-token-…"` failing
      with `left: ""` — the child wrote nothing, or nothing yet.

      It has repeatedly been filed under the stale-temp-dir diagnosis that
      genuinely explains the sibling `setup_git_worktree is idempotent` case
      above. **That diagnosis is wrong for this test** — the directories were
      clear. A spawn/read race is the current guess, and a guess is not a class.

      This entry is why `:unexplained` exists. Calling it `:intermittent` would
      assert that the cause is a race, which nobody has shown; and
      `:intermittent` is excludable, so the wrong label would also make it
      hideable. It needs a ticket and a bisect, not a label.
      """,
      added_on: ~D[2026-07-26]
    }
  ]

  @doc "Every quarantine entry, in declaration order."
  @spec entries() :: [map()]
  def entries, do: @entries

  @doc "The four recognised classes."
  @spec classes() :: [atom()]
  def classes, do: @classes

  @doc """
  The classes whose entries `excluded_tags/1` is willing to hide.

  `:deterministic` and `:unexplained` are absent by construction: a broken test
  and an un-diagnosed one must both stay loud.
  """
  @spec excludable_classes() :: [atom()]
  def excludable_classes, do: @excludable_classes

  @doc "The keys every entry must carry."
  @spec required_keys() :: [atom()]
  def required_keys, do: @required_keys

  @doc "Entries of one class."
  @spec classified(atom()) :: [map()]
  def classified(class) when class in @classes do
    Enum.filter(@entries, &(&1.class == class))
  end

  @doc """
  The ExUnit exclusion list, derived from the registry.

  This is the function `test/test_helper.exs` calls. The class filter runs
  FIRST and the `nil`-tag filter second, so a `:deterministic` entry that
  carries a real tag is dropped because of its **class**, not because it
  happens to lack a tag. `excluded_tags/1` is public so that property can be
  asserted against a synthetic entry list rather than depending on whichever
  entries the registry happens to hold today.
  """
  @spec excluded_tags([map()]) :: [atom()]
  def excluded_tags(entries \\ @entries) do
    entries
    |> Enum.filter(&(&1.class in @excludable_classes))
    |> Enum.map(& &1.tag)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Entries that are written down but do not gate anything — either because the
  class forbids it or because no ExUnit tag has been applied to the test.

  These still run in the default suite. They are here so a reader who meets one
  in a failure list can tell "known, diagnosed, still red on purpose" from
  "new regression".
  """
  @spec recorded_only() :: [map()]
  def recorded_only do
    excluded = excluded_tags()
    Enum.reject(@entries, &(&1.tag in excluded))
  end
end
