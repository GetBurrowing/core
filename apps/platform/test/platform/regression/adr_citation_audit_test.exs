defmodule Platform.Regression.AdrCitationAuditTest do
  @moduledoc """
  Source-scan guard that makes every ADR citation in the umbrella *resolve*
  against the ADR it names, and that bans the position-pinned citation form
  outright (task `019fa2aa`, stage 2).

  THE BUG BEING PINNED: commit `d31610af` inserted 25 lines into
  `docs/decisions/0046-design-and-architecture-phases-in-planning.md`.
  Nine citations of the form `ADR-NNNN:LINE` pointing at line 95 of ADR-0046
  silently became pointers at a *closing code fence* — the end of an unrelated
  `@type fire_outcome` block — while the rule they claimed to cite moved to
  line 120. Two of the nine were agent-facing: one inside an MCP **tool
  description** that agents read straight out of the tool catalogue, and one in
  an `Ecto.Changeset` error string. The headings did not move.

  Nothing could see it. That is the whole point. A line number records **no
  expectation**, so no guard can ever tell whether it still resolves; the best
  a guard could do is re-read a line it has no expectation for. A heading names
  a string that either is in the file or is not. Stage 1 converted all 41
  line-pinned citations across 21 files to

      0046-design-and-architecture-phases-in-planning.md § Architect prompt contract

  and this audit is what makes that conversion permanent rather than a
  one-time sweep. See `apps/platform/AGENTS.md` § Citing ADRs for the
  author-facing rule.

  ## What is enforced

    1. **No `ADR-NNNN:LINE` anywhere in umbrella source.** No allowlist, no
       exclusions, including this file.
    2. **Every `<file>.md § <heading>` citation resolves**: the named ADR
       exists in `docs/decisions/`, and the cited heading is a verbatim
       heading in *that* file.
    3. **Citations stay contiguous on one source line.** A citation whose
       heading has been wrapped onto the following line is rejected by name.
    4. **No citation inside a `test` / `describe` name.** The full filename
       makes a 150-character test name; put it in a comment above instead.
    5. **No bare ADR number carrying a section sign.** An ADR number written
       as a bare number and immediately followed by a section sign claims a
       section of a document it never names, so rule 2 has no file to resolve
       the heading against and cannot see it at all. Added last, and numbered
       5 rather than folded into rule 2 on purpose: the failure heredocs and
       `AGENTS.md` § Citing ADRs address rules 2 and 3 **by position**, and
       renumbering rots pointers, which is the defect this whole file exists
       to stop. `system_event_envelope_record_audit_test.exs` hit the identical
       fork and numbered its new assertion `6b` for the identical reason.
       The 60 sites that predate the rule are registered in
       `@dangling_anchor_pins`; see the ratchet comment below.

  ## Why rule 3 rejects rather than rejoins

  A rejoining detector would have to guess where the heading ends, and the
  citation grammar gives it nothing to guess with: the heading runs to the end
  of the line, and the terminators in practice are a closing backtick, an
  em-dash, a quote or simply the newline. Remove the newline as a terminator
  and the grammar becomes genuinely ambiguous — a detector that rejoins either
  truncates the heading (passes a broken citation) or swallows the following
  prose into it (fails a correct one). "Split" is decidable; "where does the
  split heading end" is not. So the split is named as its own offence.

  This is belt-and-braces rather than the only line of defence: a citation
  split *mid-heading* is already caught by rule 2, because the truncated
  heading does not exist in the ADR. Rule 3 exists to catch the case where the
  break falls right after the `§`, which leaves no heading text to resolve at
  all, and to produce an error message that says what actually happened.

  **This argument is about rule 3 and does not carry to rule 5.** It is an
  argument about where a HEADING ends, and only rule 3 reads heading text.
  Rule 5 fires on two tokens — an ADR number and a section sign — and its
  selector stops at the sign, so a one-line lookahead across the break has
  nothing to guess and cannot truncate or over-swallow anything. Rule 5
  therefore affords the lookahead rule 3 cannot, and it takes it (see the
  widened third escape below). This paragraph exists because the unqualified
  version of the section above read as a decision already made for the whole
  file, which is how the wrapped bare anchor stayed out of scope for as long
  as it did.

  ## What is deliberately NOT covered

  **THE SECTION SIGN IS THE BOUNDARY.** Rule 5 moved it: a bare ADR number
  that is immediately followed by a section sign is now in scope, because it
  makes a claim about a named section that no file can be found for. A bare
  number carrying **no** section sign stays out of scope, and that is where
  the line falls today.

  **Bare ADR numbers with no section sign (`ADR-0042`), and decision ordinals
  (`ADR-0046 decision 7`, `Decision 4`).** ~120 sites across the umbrella.
  Three reasons, and the gap is documented here rather than left implicit
  because an undocumented gap in an audit reads as coverage:

    * The large majority name **no document at all** — `Decision 1 from the
      stack`, `decision 6`, `Decision 3`. They are not ADR citations; a rule
      that resolved them would first have to solve "which document" for a form
      that identifies none.
    * They are **not this defect class**. The defect is *silent* rot: an edit
      that changes no meaning (25 blank-ish lines) invalidates the pointer and
      nobody is looking. Renumbering a decision list is a semantic edit to the
      ADR's own `## Decision` section, which that ADR's `## Implementation
      order` and `## Consequences` also index — it cannot happen without an
      author editing the very list the numbers point into.
    * **No non-circular check exists at the current call sites.** `ADR-0046
      decision 7` carries no expectation, so an audit could only assert "the
      ADR has at least 7 decisions" — existence, not correctness, which is the
      same circularity the citation form was adopted to escape. Making it
      checkable means changing the form at every site to carry the decision's
      lead phrase (`ADR-0046 decision 7 (Failure falls open, visibly.)`). That
      is a worthwhile change and a separate task; it is not a rider on this
      audit, and shipping it half-done would be worse than the documented gap.

  Four numbers in `docs/decisions/` name two files each — **0017, 0036, 0042,
  0044** — so a bare `ADR-0044` is a coin flip, not a reference. Rule 2 already
  makes the *anchored* form immune to that, because it names the file.

  `docs/decisions/` itself is out of scope: ADRs cross-reference each other in
  prose, and stage 1 left the documents untouched by design.

  ### A third escape, found later and WIDENED rather than named

  The list below reads as exhaustive and was not. A third escape existed and
  is now closed: **line-wrapping**. An author who put the newline between the
  ADR number and the section sign fell out of rule 5 entirely — not because
  the selector forbade it (its trailing `\\s*` spans a newline perfectly well)
  but because `line_offences/5` hands the detector one line at a time. The
  per-line feed was the constraint, and nothing in the escape inventory said
  so.

  **Provenance.** It was found by the end-to-end reviewer of task `019fb9e2`,
  reading this file against sha `90bab4f0`: two sites in the tree, and a
  whole-file scan reporting 60 sites across 30 files where the line-scoped
  scan reported 58 across 29. The two-site delta IS the escape; it was not
  inferred from the prose, it was measured by running the selector two ways.

  The fork was real: name it as a fourth documented escape, or widen. Widening
  won, for three reasons.

    * The terminator argument that keeps the *anchored* form's lookahead
      modest does not transfer. It is an argument about where a heading ENDS,
      and rule 5 never reads heading text at all — it fires on the number and
      the sign, both of which are unambiguous across a line break.
    * The mechanism already existed in this file and was already pinned. Rule
      3's second branch does exactly this bounded one-line lookahead, under
      `the detector names the two split shapes and clears the wrapped-prose
      fix`. This is a mirror of a proven in-file pattern, not a new capability.
    * **Documenting only would have left a live bypass.** The other two
      escapes below are shapes that carry no reliable signal — widening to
      catch them would fire on ordinary prose. This one is the banned form
      exactly, defeated by pressing Enter one character earlier. A ratchet
      with a keystroke-sized bypass is not a ratchet, and a gate an author can
      step around without changing what they meant is worse than an absent
      one, because it reports green.

  Two sites in the tree were escaping this way and are now in scope and
  pinned. Neither was rewritten to make anything green: the prose in both is
  byte-identical to what it was before this rule saw it.

  ### Two measured escapes from rule 5, named and NOT widened

  Recorded the way the precedent recorded its `#L485` gap: measured, scoped,
  left alone rather than chased. Unlike the wrapping escape above, widening
  for either of these would fire on ordinary prose.

    * **The parenthetical dodge.** `lib/platform/tasks/stacks.ex` (currently
      line 5132, stated for orientation only — locate it by content) reads
      `Mirrors the convention documented in ADR 0041 (Branch model) so
      callers`. Same unresolvable claim as a bare anchor, in parentheses
      instead of after a section sign, so rule 5 does not fire. Widening to
      ban parentheses after an ADR number would fire on ordinary prose
      constantly — `(ADR 0041)`, `(see ADR 0044)` and `(ADR 0041 stack-level
      agent assignment)` are all in this same file — so the parenthetical form
      carries no reliable signal that a *section* is being claimed. Named,
      measured, left alone.
    * **The number-free anchor.** A section sign with a name but no ADR number
      in front of it — `process-patterns.md § Cite ADR Headings, Not Line
      Numbers`, cited in `system_event_envelope_record_audit_test.exs` — is
      out of BOTH selectors by design. Rule 5's selector requires an ADR
      number; `@citation_head_regex` requires the `NNNN-name.md` ADR filename
      shape, which `process-patterns.md` does not have. It names a non-ADR
      corpus, which is the same reason the `(?<!notes\\/)` lookbehind exists:
      `notes/2026-07-26-boot-telemetry-detach.md` *does* have the ADR filename
      shape and had to be excluded explicitly. Resolving either against
      `docs/decisions/` would report a missing ADR that was never claimed.

  ### The ratchet cannot see an over-greedy bare-anchor selector

  Measured, not reasoned: stage 2 of task `01a0851f` mutated the wrapped
  branch's lookahead to be greedy — matching an ADR number at end of line no
  matter what followed on the next line — and the ratchet **did not move**.
  Two tests failed, both fixtures; zero ratchet reds, zero count drift.

  The mechanism is worth stating, because a reader who knows only the
  conclusion will delete the control that catches it as redundant.
  `bare_anchor_counts/1` and `sites_for/2` do not carry the ADR number out of
  the match; they recover it by re-scanning the offence's `detail` with
  `@bare_anchor_regex`, which requires a section sign. A greedy match fires on
  roughly 120 lines that merely END on an ADR number, whose successor lines
  carry no section sign, so the joined detail carries none either, recovery
  matches nothing, and those sites contribute **zero** `{path, number}` keys.
  The ratchet compares key sets, so it sees no change. And the vacuity control
  `the scan is not vacuous` asserts a floor of 40, not equality, so ~120 extra
  raw sites sail past it too.

  So the guard against the greedy direction is **not** the ratchet and **not**
  the vacuity floor. It is the full-list negative control
  `one scan over the four wrapped shapes returns exactly the two that offend`,
  which asserts the non-offending shapes are absent from the result and is the
  only assertion in this file that goes red on over-selection. Do not weaken
  it, and do not delete it as duplicated by the ratchet — the ratchet is
  structurally unable to do its job.

  ### What green means, and what it does not

  Green here means two things: every citation that names a section also names
  a file whose headings resolve, AND every dangling citation that has not been
  fixed is registered in the pin list. It does **not** mean the registered
  citations are correct — they are known-broken by construction. They are
  pinned so the set cannot grow, not blessed. Two shapes of fix apply and the
  failure message distinguishes them: some anchors exist as a heading in a
  *different* ADR (`Branch model` is a real heading in
  `0045-task-stacks-v2.md`, so those sites repoint and nothing needs writing),
  and most exist nowhere under `docs/decisions/` (write the section, then
  anchor to it).

  ## Anti-vacuity

  Every ADR citation lives in a comment, a `@moduledoc`, or a string literal,
  so unlike the peer audits in this directory this one **must not strip
  comments** — stripping would leave an empty scan buffer and pass forever.
  `the scan is not vacuous` is the control: it fails if the file walk or the
  citation regex stops finding the corpus that is known to be there.

  Cheap by construction (`File.read!` + `Regex`, no DB, no PubSub) and carries
  no `@moduletag`, so it runs in the default `mix test` set. Peer of
  `task_alias_shadowing_audit_test.exs` and `supervised_task_repo_audit_test.exs`.
  """

  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @umbrella_apps Path.expand("../../../..", __DIR__)
  @repo_root Path.expand("../../../../..", __DIR__)
  @adr_dir Path.join([@repo_root, "docs", "decisions"])

  # An ADR number, a colon, a line number — with or without a range suffix,
  # and with either a hyphen or a space after `ADR`. The COLON is what makes it
  # a position pin; `ADR 0042 Decision 8` deliberately does not match (see the
  # moduledoc's out-of-scope note).
  @line_pinned_regex ~r/\bADR[\s-]?\d{4}\s*:\s*\d/

  # An ADR number written as a bare number, immediately followed by a section
  # sign: the citation CLAIMS to name a section of a document it never names.
  # There is no filename to resolve the heading against, so rule 2 cannot see
  # it at all — 15 sites of this shape sat in the corpus unauditable by
  # construction while the audit reported clean.
  #
  # THE SECTION SIGN IS THE LINE, and it is deliberate. A bare number with NO
  # sign (`ADR-0046 decision 7`, `ADR-0042`, `Decision 4` — ~120 sites) stays
  # out of scope exactly as the moduledoc's out-of-scope note argues: it makes
  # no resolvable claim, so there is nothing to check that is not circular. A
  # bare number WITH a sign makes a claim that cannot be checked, which is a
  # different thing and the one this bans.
  #
  # BANNED RATHER THAN RESOLVED-BY-NUMBER, and that was measured. Mapping the
  # number to a file is wrong three ways:
  #
  #   1. Ambiguous. Four numbers name two ADR files each (0017, 0036, 0042,
  #      0044 — see the moduledoc above). 8 of the 49 measured sites cite 0042.
  #   2. It SWALLOWS the anchored check. Resolve-by-number reports a bare
  #      citation as `:unresolved_heading` — the same kind an anchored-but-wrong
  #      citation produces. "Names no file" and "names a file whose heading is
  #      gone" collapse into one red, and neither can fail alone any more. That
  #      is the quiet hazard, and it is why this is its own kind.
  #   3. It buys nothing. Measured against `9d925d18`: NONE of the anchors the
  #      bare sites name (Status divergence handling, Rollup-branch merge,
  #      Stack-level deploy, DAG validation, Status mapping, Branch model,
  #      Unblock threshold, Status cascade, Validation routing, sponsor-bypass,
  #      architect-finding-1) exists as a heading anywhere under
  #      `docs/decisions/`. Resolve-by-number produces the identical red with
  #      more machinery and less discriminative power.
  #
  # Its own source is safe from the self-scan for the same reason
  # `@line_pinned_regex`'s is: the `ADR` here is followed by `[`, not a digit.
  #
  # MEASURED AGAINST THE REAL TREE, not assumed. Both this selector and the
  # anchored one pass on an unmutated tree — exactly the condition under which
  # a new check is most likely to be decorative — so stage 3 ran four mutations
  # in `lib/platform/tasks/stack.ex`, above `@statuses`, and reverted each.
  # Every citation below is DESCRIBED rather than spelled, because this file is
  # inside the corpus the audit walks and a contiguous instance would be a real
  # offence (see the fixture comments below).
  #
  #   1. BARE ONLY — `ADR`, the invented number 0099, a section sign, then a
  #      quoted invented heading. 14 tests, ONE failure: `no bare-anchor
  #      citation is unpinned` alone, quoting `stack.ex:35`. The three anchored
  #      assertions stayed GREEN.
  #   2. ANCHORED-BUT-WRONG ONLY — the 0046 planning ADR's real filename, a
  #      section sign, and a heading that is not in it. 14 tests, ONE failure:
  #      `every anchored citation names a heading that exists in that ADR`
  #      alone, quoting `stack.ex:35`. The bare-anchor assertions stayed GREEN.
  #   3. BOTH AT ONCE — 14 tests, exactly TWO failures, one per kind, each
  #      reporting ONLY its own site (`stack.ex:35` for the anchored one,
  #      `stack.ex:36` for the bare one). This is the swallow control against
  #      the real tree: the two selectors do not overlap, and neither is
  #      passing on the other's behalf.
  #   4. RATCHET DIRECTION — the pinned bare citation in that same file was
  #      FIXED (rewritten into a resolvable anchored form) with the pin left
  #      alone. 14 tests, ONE failure: `no pin names a citation that no longer
  #      exists`, saying "A pinned citation was FIXED — shrink the pin" and
  #      naming `{"lib/platform/tasks/stack.ex", "0041", _}`. Direction-correct
  #      — NOT a new-citation message, which is the whole point of stage 2's
  #      three-way decomposition.
  #
  # All four reverted; the file returns 14 tests, 0 failures. The independence
  # observed in mutation 3 is kept permanently by `a bare anchor and a broken
  # anchored citation are reported under different kinds` below, in the same
  # way assertion 6b is kept separate from assertion 6 in
  # `system_event_envelope_record_audit_test.exs`.
  @bare_anchor_regex ~r/\bADR[\s-]?(\d{4})\s*§/

  # The same bare form, wrapped: the line ENDS on the ADR number and the
  # section sign opens the next line. `@bare_anchor_regex`'s `\s*` would span a
  # newline on its own, but it never sees one — `line_offences/5` feeds the
  # detector a single line at a time, so the per-line feed is the constraint,
  # not the pattern. This regex is paired with the EXISTING
  # `@orphan_section_regex` on the following line rather than cloning it: rule
  # 3 already established that "the next line resumes with a section sign"
  # shape, and one definition keeps the two lookaheads from drifting apart.
  #
  # Disjoint from rule 3 by construction, and asserted below: rule 3's
  # lookahead branch requires the line to END on an ADR `.md` filename, this
  # one requires it to END on four digits, and no line can do both.
  # MEASURED AGAINST THE REAL TREE, mirroring the four-mutation run recorded
  # above `@bare_anchor_regex`. Stage 2 ran four mutations of the wrapped
  # branch, one at a time, reverting between; the file holds 21 tests and 0
  # failures unmutated. Citations are DESCRIBED, never spelled — a contiguous
  # instance here would be a real offence against this file's own rule.
  #
  #   1. BRANCH DELETED — the wrapped clause removed entirely. 21 tests, FIVE
  #      failures: `one scan over the four wrapped shapes returns exactly the
  #      two that offend`, `a bare anchor wrapped across a line break is
  #      caught, and reports both lines`, `the wrapped offence's detail is
  #      what the ratchet recovers its ADR number from`, and BOTH ratchet
  #      tests — `no pin names a citation that no longer exists` and `no pin
  #      carries a stale count`, because the two pinned wrapped sites vanish.
  #   2. LOOKAHEAD MADE GREEDY — the next-line-section-sign requirement
  #      dropped, so any line ending on an ADR number offends. 21 tests, TWO
  #      failures, BOTH of them fixture tests: the full-list scan and the
  #      wrapped-line test. **THE RATCHET DID NOT MOVE, and that is a
  #      measurement worth stating rather than an oversight.** The ~120
  #      out-of-scope trailing-number sites this mutation swallows all have a
  #      successor line with no section sign, so their joined `detail` carries
  #      no sign either, `@bare_anchor_regex` recovers no number from it, and
  #      they contribute ZERO `{path, number}` keys. The ratchet compares
  #      keys, and `the scan is not vacuous` asserts a FLOOR of 40, so an
  #      over-greedy selector is invisible to every set-equality test in this
  #      file. Only a full-list assertion on a fixture — one that fails by
  #      gaining a tuple — can see it. That is why the negative control in
  #      `one scan over the four wrapped shapes` is the highest-value
  #      assertion in the stage.
  #   3. DETAIL DEGRADED TO FIRST-LINE-ONLY — the join dropped. 21 tests, FIVE
  #      failures: the vacuity control, the full-list scan, the wrapped-line
  #      test, and both ratchet tests (the pinned wrapped sites stop
  #      contributing keys, so the pin reads as naming citations that no
  #      longer exist). The vacuity control detonates through
  #      `bare_anchor_counts/1`, the consumer, not through the string's shape.
  #   4. MUTATIONS 2 AND 3 TOGETHER. Mutation 1 is not independent of these —
  #      deleting the branch subsumes both, so "all three at once" is not a
  #      constructible state and the honest combination is this pair. TWO
  #      things broken, FIVE distinct failures, and the failing set is exactly
  #      the UNION of mutation 2's and mutation 3's (they overlap on the two
  #      fixture tests). Union, not a subset: no test is passing on another's
  #      behalf, and each break still has at least one test that fires on it
  #      alone — the greedy lookahead through the full-list negative control,
  #      the dropped join through the vacuity control.
  #
  # All reverted; the file returns 21 tests, 0 failures.
  @wrapped_bare_anchor_regex ~r/\bADR[\s-]?(\d{4})\s*$/

  # The anchored form's head: an ADR filename immediately followed by `§`. The
  # heading is NOT captured here — it is resolved against the target file's
  # real headings instead of guessed at with a terminator (see moduledoc).
  #
  # The `(?<!notes\/)` lookbehind was added when this branch merged main.
  # `\d{4}-[a-z0-9-]+\.md` is the ADR filename shape, but it is ALSO the shape
  # of the date-named files in `apps/platform/notes/` — main's
  # `notes/2026-07-26-boot-telemetry-detach.md` matches it on the `2026`.
  # `telemetry_handler_test.exs` cites that note in the anchored form, which is
  # a perfectly resolvable citation; it just names a different corpus, so
  # resolving it against `docs/decisions/` reported a missing ADR that was
  # never claimed to exist.
  #
  # Disambiguated on the explicit directory prefix rather than by narrowing the
  # number to `0\d{3}`: the prefix is what actually carries the "this is not an
  # ADR" information, and a shape-based rule would quietly stop auditing ADR
  # 1000 one day. A citation that names no directory is still audited as an
  # ADR, which is the bare form every real citation in the repo uses.
  @citation_head_regex ~r/(?<!notes\/)(\d{4}-[a-z0-9-]+\.md)\s*§/

  # An ADR filename on its own, used only to recover which ADRs a batch of
  # offences cited so the failure can enumerate that file's real headings.
  @adr_filename_regex ~r/\d{4}-[a-z0-9-]+\.md/

  # `§` is the last thing on the line: the heading was wrapped away.
  @dangling_section_regex ~r/\d{4}-[a-z0-9-]+\.md\s*§\s*$/

  # The line ends on the filename …
  @dangling_filename_regex ~r/\d{4}-[a-z0-9-]+\.md\s*$/

  # … and the next line resumes with `§`, through any comment marker.
  @orphan_section_regex ~r/^\s*(?:#+|\*|\/\/|<%!--)?\s*§/

  @test_name_regex ~r/^\s*(?:test|describe)\s+"/

  # ── The dangling-citation ratchet ─────────────────────────────────
  #
  # Every bare-anchor site that existed when this gate landed, keyed
  # `{path_relative_to_@app_root, adr_number, count}`. It is a REGISTRATION
  # ratchet, not an exemption list: the three tests below assert set EQUALITY
  # against the live scan, so a new site goes red (nothing exempts it), and
  # fixing a registered one ALSO goes red until the row is removed. The list
  # can therefore only shrink.
  #
  # Three deliberate omissions:
  #
  #   * No line number. A position-pinned entry is the exact defect this file
  #     bans; it would rot on the first insertion above it.
  #   * No verbatim citation text. Storing it would put a contiguous instance
  #     of the banned form inside the corpus this audit walks (see the fixture
  #     comments below), and it would force this list to decide where an anchor
  #     ENDS — the terminator problem the moduledoc declines to solve. The
  #     number and the count carry everything the ratchet needs; the failure
  #     message quotes the offending line from source at report time, which is
  #     where the text belongs.
  #   * No aggregate total. A single number would let one new site hide behind
  #     one fixed site.
  #
  # Measured against `origin/main` at `e844c1c2` + this branch: 58 sites across
  # 29 files. The plan was written against a 49/26 measurement and did not list
  # ADR 0044 at all; ten 0044 sites landed in between with the auto-approve
  # fan-out work (tasks 01a05877 / 01a0589b).
  #
  # Re-measured at `ccb93cb4` after rule 5 grew its wrapped branch: **60 sites
  # across 30 files**, 35 rows. The delta is exactly the two LINE-WRAPPED sites
  # the widening brought into scope and nothing else — `stack_graph.ex` is a
  # new file key (the 30th), `stacks.ex` goes 8 -> 9. Both were escaping every
  # rule in this file before; neither citation was touched to produce this.
  # Confirmed by a scan run independently of this list, not derived from it:
  # 60 sites / 30 files / 35 `{path, number}` keys, per-key diff empty in both
  # directions, zero count drift. The 49/26 note above stands as the record of
  # the plan's wrong figure.
  @dangling_anchor_pins [
    {"lib/platform/audit/event.ex", "0040", 1},
    {"lib/platform/federation/invocation_visibility_grant.ex", "0040", 2},
    {"lib/platform/federation/owner_handle.ex", "0040", 1},
    {"lib/platform/federation/task_attrs.ex", "0044", 2},
    {"lib/platform/federation/tool_surface.ex", "0041", 1},
    {"lib/platform/federation/tool_surface.ex", "0042", 1},
    {"lib/platform/federation/tool_surface.ex", "0044", 4},
    {"lib/platform/orchestration/context_assembler.ex", "0042", 1},
    {"lib/platform/orchestration/execution_lease.ex", "0040", 1},
    {"lib/platform/orchestration/runtime_event.ex", "0040", 1},
    {"lib/platform/orchestration/runtime_supervision.ex", "0040", 1},
    {"lib/platform/org/preamble_builder.ex", "0042", 1},
    {"lib/platform/security.ex", "0043", 1},
    {"lib/platform/security/sweeper.ex", "0043", 1},
    {"lib/platform/tasks.ex", "0018", 2},
    {"lib/platform/tasks.ex", "0041", 3},
    {"lib/platform/tasks/rollup_webhook_processor.ex", "0041", 1},
    {"lib/platform/tasks/stack.ex", "0041", 1},
    {"lib/platform/tasks/stack_graph.ex", "0041", 1},
    {"lib/platform/tasks/stacks.ex", "0041", 9},
    {"lib/platform_web/controllers/github_webhook_controller.ex", "0041", 1},
    {"priv/repo/migrations/20260501202512_add_owner_identity_to_runtime_tables.exs", "0040", 1},
    {"priv/repo/migrations/20260512000000_add_metadata_to_task_stacks.exs", "0041", 1},
    {"test/platform/federation/task_attrs_test.exs", "0044", 3},
    {"test/platform/federation/tool_surface_stacks_test.exs", "0041", 1},
    {"test/platform/federation/tool_surface_test.exs", "0044", 1},
    {"test/platform/org/preamble_builder_test.exs", "0042", 2},
    {"test/platform/responsibilities/event_topic_delivery_test.exs", "0043", 1},
    {"test/platform/tasks/plan_engine_stack_member_merge_test.exs", "0041", 1},
    {"test/platform_web/controllers/github_webhook_controller_test.exs", "0041", 2},
    {"test/platform_web/live/tasks_live_test.exs", "0018", 3},
    {"test/platform_web/live/tasks_live_test.exs", "0041", 4}
  ]

  setup_all do
    headings_by_adr = adr_headings_by_file()

    scanned =
      for path <- source_files() do
        {path, File.read!(path)}
      end

    {citations, offenders} =
      Enum.reduce(scanned, {[], []}, fn {path, source}, acc ->
        scan_source(Path.relative_to(path, @app_root), source, headings_by_adr, acc)
      end)

    %{
      file_count: length(scanned),
      citations: citations,
      offenders: offenders,
      headings_by_adr: headings_by_adr
    }
  end

  describe "ADR citations resolve" do
    test "no source carries a position-pinned ADR citation", ctx do
      offenders = of_kind(ctx, :line_pinned)

      assert offenders == [],
             report(
               offenders,
               """
               A position-pinned ADR citation (`ADR-NNNN` + `:` + a line number)
               is banned. Line 95 of ADR-0046 was cited by nine sites — two of
               them read by agents out of the MCP tool catalogue — and pointed at
               a closing code fence for weeks because an unrelated commit inserted
               25 lines above it. Nothing could detect that, because a line number
               records no expectation.

               Replace it with the anchored form:

                   0046-design-and-architecture-phases-in-planning.md § Architect prompt contract

               If you are writing PROSE ABOUT the banned form rather than a
               citation, say "line 95 of ADR-0046" — which reads better anyway,
               because it describes a line rather than pretending to cite a rule.
               That is how this file, `AGENTS.md` and `architecture_gate_test.exs`
               all discuss the original bug without tripping the ban. There is no
               exclusion list and adding one is not an option.
               """
             )
    end

    test "every anchored citation names an ADR that exists", ctx do
      offenders = of_kind(ctx, :unknown_adr)

      assert offenders == [],
             report(
               offenders,
               """
               The cited file is not in `docs/decisions/`. Either the ADR was
               renamed — update the citation — or the filename was mistyped.
               Note that four numbers name two files each (0017, 0036, 0042,
               0044), so the full filename is load-bearing.
               """
             )
    end

    test "every anchored citation names a heading that exists in that ADR", ctx do
      offenders = of_kind(ctx, :unresolved_heading)

      assert offenders == [],
             report(
               offenders,
               """
               The cited ADR exists but has no heading matching the cited text.
               Either the heading was renamed — update the citation to the new
               text — or the section was removed, in which case find where the
               rule went and cite that. The match is verbatim against the ADR's
               `#`-headings, which is exactly what makes this form checkable at
               all; do not "fix" a failure by loosening the comparison.

               Update the citation or restore the heading; do not add an
               exclusion.
               """,
               ctx.headings_by_adr
             )
    end

    test "no citation is split across two source lines", ctx do
      offenders = of_kind(ctx, :split)

      assert offenders == [],
             report(
               offenders,
               """
               The citation's heading has been wrapped onto the following line.
               A split citation still LOOKS resolvable to a human reviewer while
               being invisible to this audit — the worst available failure mode,
               because it passes review by eye and passes CI by silence.

               Wrap the prose AROUND the citation, not through it. The line will
               be long. That is the trade.
               """
             )
    end

    test "no citation appears inside a test or describe name", ctx do
      offenders = of_kind(ctx, :test_name)

      assert offenders == [],
             report(
               offenders,
               """
               An ADR filename inside a `test` / `describe` name produces a
               150-character name that reads as noise in the failure output. Put
               the citation in a comment directly above the block instead — it
               stays greppable, this audit still resolves it, and the name stays
               readable.
               """
             )
    end
  end

  describe "the dangling-citation ratchet" do
    # Set equality against @dangling_anchor_pins, decomposed into three
    # DIRECTIONAL assertions. Not `MapSet.subset?` — subset is an exemption
    # list wearing a ratchet's clothes, and a new site would slot into the
    # exempted class and never fire. Not one `assert scanned == pinned` either:
    # a bare equality failure says something moved without saying WHICH WAY,
    # and the two directions need opposite actions. Mirrors the decomposition
    # in `repo_lookup_boundary_test.exs`, whose `@inventory` solves this
    # identically.
    test "no bare-anchor citation is unpinned", ctx do
      scanned = bare_anchor_counts(ctx)
      unpinned = Enum.reject(Map.keys(scanned), &(&1 in pin_keys()))

      assert unpinned == [],
             """
             A NEW dangling citation appeared — it names a section of a
             document it never names, so nothing can resolve it and rule 2
             cannot see it at all.

             Fix the citation by naming the ADR file it means, in the anchored
             form. Do NOT add a row to `@dangling_anchor_pins` to quiet this;
             the pin registers what already existed, and it only ever shrinks.

             #{sites_for(ctx, unpinned)}
             """
    end

    test "no pin names a citation that no longer exists", ctx do
      scanned = bare_anchor_counts(ctx)
      stale = Enum.reject(pin_keys(), &Map.has_key?(scanned, &1))

      assert stale == [],
             """
             A pinned citation was FIXED — shrink the pin.

             These `@dangling_anchor_pins` rows no longer match anything in the
             tree. Delete them:

             #{Enum.map_join(stale, "\n", fn {path, number} -> "  {\"#{path}\", \"#{number}\", _}" end)}

             This assertion is what makes the list monotonically decreasing: a
             repair that left its row behind would silently re-open the slot
             for the next bare citation in that file.
             """
    end

    test "no pin carries a stale count", ctx do
      scanned = bare_anchor_counts(ctx)

      drifted =
        for {path, number, pinned} <- @dangling_anchor_pins,
            actual = Map.get(scanned, {path, number}),
            actual != nil,
            actual != pinned,
            do: {{path, number}, pinned, actual}

      assert drifted == [],
             """
             A pinned count no longer matches the tree. Each line below states
             the direction, and the two directions need opposite actions.

             #{Enum.map_join(drifted, "\n\n", &count_drift_line/1)}

             #{sites_for(ctx, Enum.map(drifted, fn {key, _, _} -> key end))}
             """
    end
  end

  describe "the audit itself" do
    test "the scan is not vacuous", ctx do
      # Without this control a typo in @citation_head_regex, or a file walk
      # that silently matches nothing, would make every assertion above pass
      # forever against an empty corpus. Stage 1 converted 41 citations across
      # 21 files; the floors are set well below that so ordinary churn does not
      # trip them, and well above zero so a broken scanner does.
      assert ctx.file_count > 500,
             "the umbrella source walk found only #{ctx.file_count} files — the " <>
               "wildcard or the exclusions are wrong"

      assert length(ctx.citations) >= 20,
             "the scan found only #{length(ctx.citations)} anchored ADR citations. " <>
               "There were 41 after task 019fa2aa stage 1. Either the citation " <>
               "regex is broken or the citations were mass-deleted; both mean " <>
               "this audit is no longer guarding anything."

      assert map_size(ctx.headings_by_adr) > 40,
             "docs/decisions/ yielded #{map_size(ctx.headings_by_adr)} ADRs — " <>
               "@adr_dir does not point where it should"

      # Every ADR the scan is resolving against must have parsed into real
      # headings; an empty heading list would fail citations for the wrong
      # reason.
      assert Enum.all?(ctx.headings_by_adr, fn {_file, headings} -> headings != [] end)

      # The ratchet's own controls. A widened bare-anchor selector that matched
      # nothing would leave every ratchet assertion below comparing two empty
      # sets and shipping green over a tree known to carry dozens of sites.
      bare_anchors = of_kind(ctx, :bare_anchor)

      assert length(bare_anchors) >= 40,
             "the scan found only #{length(bare_anchors)} bare-anchor sites. There " <>
               "were 58 across 29 files when this gate landed; the floor sits well " <>
               "below that so ordinary repairs do not trip it, and far above zero " <>
               "so a broken @bare_anchor_regex does."

      assert length(@dangling_anchor_pins) > 0,
             "@dangling_anchor_pins is empty. Either every registered citation was " <>
               "repaired — in which case delete the pin and the three ratchet tests, " <>
               "and the bare-anchor ban stands alone with no registration at all — " <>
               "or the scan broke and the ratchet is comparing two empty sets."

      pin_keys = Enum.map(@dangling_anchor_pins, fn {path, number, _count} -> {path, number} end)

      assert Enum.uniq(pin_keys) == pin_keys,
             "duplicate keys in @dangling_anchor_pins: " <>
               inspect(pin_keys -- Enum.uniq(pin_keys)) <>
               ". One row per {path, ADR number}; the count column carries multiplicity."
    end

    test "the detector flags a broken citation and clears a correct one" do
      headings = adr_headings_by_file()

      # Built piecewise: this file is scanned by the audit above, so a literal
      # citation in a heredoc here would be a real citation subject to real
      # resolution — including the deliberately-broken fixtures.
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"
      good = "  # " <> adr <> " " <> "§ Architect prompt contract" <> " — the rule."
      renamed = "  # " <> adr <> " " <> "§ Architect prompt contracts" <> " — the rule."
      missing_adr = "  # " <> "9999-no-such-adr" <> ".md " <> "§ Architect prompt contract"

      assert offences_in("fixture.ex", good, headings) == []

      assert [{:unresolved_heading, _, 1, detail}] = offences_in("fixture.ex", renamed, headings)
      assert detail =~ "Architect prompt contracts"

      assert [{:unknown_adr, _, 1, _}] = offences_in("fixture.ex", missing_adr, headings)
    end

    test "the detector survives a shift of every line in the cited ADR" do
      # The defect-class proof, made permanent. The original bug was a 25-line
      # insertion; this shifts by 30, which is larger, and every citation must
      # still resolve because headings are content, not position. A regression
      # that reintroduced any positional assumption fails here.
      headings = adr_headings_by_file()
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"
      body = File.read!(Path.join(@adr_dir, adr))
      shifted = String.duplicate("\n", 30) <> body

      shifted_headings = Map.put(headings, adr, headings_in(shifted))

      assert headings_in(shifted) == Map.fetch!(headings, adr)

      line = "  # " <> adr <> " " <> "§ Per-step outcome" <> "."
      assert offences_in("fixture.ex", line, shifted_headings) == []
    end

    test "the detector names the two split shapes and clears the wrapped-prose fix" do
      headings = adr_headings_by_file()
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"

      # Break right after the section sign.
      after_section = "  # " <> adr <> " " <> "§" <> "\n  # Per-step outcome — the rule."
      assert [{:split, _, 1, _}] = offences_in("fixture.ex", after_section, headings)

      # Break right before it.
      before_section = "  # see " <> adr <> "\n  # " <> "§ Per-step outcome" <> " — the rule."
      assert [{:split, _, 1, _}] = offences_in("fixture.ex", before_section, headings)

      # Break mid-heading. Not detectable as a split — the first line looks
      # like a complete citation — but resolution catches it anyway, which is
      # why rule 3 is belt-and-braces rather than the only defence.
      mid = "  # " <> adr <> " " <> "§ Per-step" <> "\n  # outcome — the rule."
      assert [{:unresolved_heading, _, 1, _}] = offences_in("fixture.ex", mid, headings)

      # The fix: prose wrapped around the citation, not through it.
      fixed =
        "  # The rule is\n  # " <> adr <> " " <> "§ Per-step outcome" <> ", which says\n  # so."

      assert offences_in("fixture.ex", fixed, headings) == []
    end

    test "the detector flags the position-pinned form and citations in block names" do
      headings = adr_headings_by_file()
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"

      assert [{:line_pinned, _, 1, _}] =
               offences_in(
                 "fixture.ex",
                 "  # see " <> "ADR-" <> "0046:95" <> " for the rule",
                 headings
               )

      assert [{:line_pinned, _, 1, _}] =
               offences_in("fixture.ex", "  # see " <> "ADR 0044" <> ":27-28", headings)

      # Prose about the banned form, which is how this file and AGENTS.md
      # discuss the bug, must NOT trip it.
      assert offences_in("fixture.ex", "  # never use the ADR-NNNN:LINE form", headings) == []
      assert offences_in("fixture.ex", "  # line 95 of ADR-0046 was a fence", headings) == []

      # A bare number or a decision ordinal is out of scope by design.
      assert offences_in("fixture.ex", "  # ADR-0046 decision 7 falls open", headings) == []

      named = "  test \"the gate (" <> adr <> " " <> "§ Per-step outcome" <> ")\" do"
      assert [{:test_name, _, 1, _}] = offences_in("fixture.ex", named, headings)
    end

    test "a bare anchor and a broken anchored citation are reported under different kinds" do
      # Mutation 3 of the measurement above, made permanent. Two sites, one of
      # each shape, scanned in ONE call: the returned list must be exactly one
      # `:bare_anchor` and one `:unresolved_heading`, each on its own line. If
      # either selector ever widens to subsume the other, this collapses to a
      # single kind or reports one site twice, and it fails here rather than in
      # a mutation run nobody re-runs.
      headings = adr_headings_by_file()
      sign = "§"
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"

      source =
        "  # see ADR " <>
          "0099" <>
          " " <>
          sign <>
          "\"Phantom halt semantics\"\n" <>
          "  # " <> adr <> " " <> sign <> " Phantom halt semantics" <> " governs this."

      assert [
               {:bare_anchor, "fixture.ex", 1, bare_detail},
               {:unresolved_heading, "fixture.ex", 2, heading_detail}
             ] = offences_in("fixture.ex", source, headings)

      assert bare_detail =~ "0099"
      assert heading_detail =~ adr
      refute bare_detail =~ adr
      refute heading_detail =~ "0099"
    end

    test "a bare anchor wrapped across a line break is caught, and reports both lines" do
      # Fixtures piecewise across the line boundary, harder here than anywhere
      # else in this file: the form under test IS a line ending on an ADR
      # number followed by a line opening with a section sign, which is
      # precisely what this source file must never contain. Every `<>` below
      # is load-bearing — collapse one into a literal and this file becomes a
      # real offender against its own rule.
      headings = adr_headings_by_file()
      sign = "§"
      number = "0099"

      wrapped =
        "  # positions map to the digits per ADR " <>
          number <> "\n" <> "  " <> sign <> "\"Phantom halt semantics\"; the rest."

      assert [{:bare_anchor, "fixture.ex", 1, detail}] =
               offences_in("fixture.ex", wrapped, headings)

      # THE ANTI-VACUITY ASSERTION. `bare_anchor_counts/1` and `sites_for/2`
      # recover the ADR number by re-scanning this `detail` with the on-line,
      # section-sign-requiring `@bare_anchor_regex`. If `detail` were the first
      # line alone the recovery would find nothing, the offence would
      # contribute no `{path, number}` key, and it would be invisible to all
      # three ratchet tests while still appearing in `offences_in/3` — a
      # detector that fires attached to a ratchet that cannot see it. Asserting
      # the recovery directly, rather than the string shape, is what makes this
      # fail if the join is ever dropped.
      assert detail =~ number
      assert detail =~ sign

      assert [[_match, ^number]] = Regex.scan(@bare_anchor_regex, detail)

      # The orphaned section line is reported as part of line 1's offence, not
      # as a second site: one wrapped citation is one offence.
      assert length(offences_in("fixture.ex", wrapped, headings)) == 1

      # The unwrapped equivalent is still exactly one offence, same kind, and
      # its detail recovers the same number — the two branches agree.
      inline = "  # positions map to the digits per ADR " <> number <> " " <> sign <> "\"X\"."

      assert [{:bare_anchor, "fixture.ex", 1, inline_detail}] =
               offences_in("fixture.ex", inline, headings)

      assert [[_m, ^number]] = Regex.scan(@bare_anchor_regex, inline_detail)

      # A line ending on an ADR number whose successor does NOT open with a
      # section sign stays out of scope, exactly as the unwrapped bare-number
      # form does. Widening rule 5 to the wrapped shape must not widen it to
      # every trailing ADR number in the repo — there are roughly 120 of those.
      trailing = "  # the rule is in ADR " <> number <> "\n" <> "  # and it says so."
      assert offences_in("fixture.ex", trailing, headings) == []
    end

    test "rule 3's wrapped split and rule 5's wrapped bare anchor cannot both fire" do
      # Disjointness, stated in the regex comment and CHECKED here rather than
      # left as an argument. Rule 3's lookahead branch requires the line to end
      # on an ADR `.md` filename; rule 5's new branch requires it to end on
      # four digits. No line can end on both, so a wrapped citation that names
      # a file is a `:split` and never also a `:bare_anchor`.
      headings = adr_headings_by_file()
      sign = "§"
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"

      # The word ADR and a four-digit number are present on the first line, and
      # deliberately so: without them the bare selector could not have fired
      # here whatever its anchoring, and the assertion below would pass for the
      # wrong reason. With them, the ONLY thing keeping rule 5 off this line is
      # the end-of-string anchor — drop it from `@wrapped_bare_anchor_regex`
      # and this test goes red, which is the positive control that the
      # disjointness claim is about the anchor and not about the fixture.
      split =
        "  # see ADR " <> adr <> "\n" <> "  # " <> sign <> " Per-step outcome" <> " — the rule."

      offences = offences_in("fixture.ex", split, headings)

      assert [{:split, "fixture.ex", 1, _}] = offences
      refute Enum.any?(offences, &(elem(&1, 0) == :bare_anchor))
    end

    test "one scan over the four wrapped shapes returns exactly the two that offend" do
      # THE FULL-LIST PIN. One call, and the whole returned list is asserted —
      # kinds, path, LINE INDICES and all — rather than "at least one offence
      # was found". A selector that got greedier would have to fail by
      # producing an EXTRA tuple, which no `assert ... =~` or non-emptiness
      # check can see. The four shapes are in one string so they are scanned
      # with real neighbours, which is the only way a lookahead bug can show.
      #
      # Fixtures piecewise across every line boundary, and that is
      # load-bearing rather than stylistic: this file is inside the corpus the
      # audit walks, and the shape under test IS a line ending on an ADR
      # number above a line opening with a section sign. A literal heredoc
      # here would make this file a genuine offender against its own rule, and
      # the resulting red would read as a detector bug.
      headings = adr_headings_by_file()
      sign = "§"
      number = "0099"
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"

      # THE WRAPPED BARE ANCHOR. Offends, at the FIRST line's index.
      wrapped =
        "  # positions map to the digits per ADR " <>
          number <> "\n" <> "  " <> sign <> "\"Phantom halt semantics\"; the rest.\n"

      # RULE 3's WRAPPED SPLIT. Offends as `:split`, never also as
      # `:bare_anchor`: the line ends on an ADR `.md` filename, not on four
      # digits. The disjointness control.
      split =
        "  # see " <> adr <> "\n" <> "  # " <> sign <> " Per-step outcome" <> " — the rule.\n"

      # NEGATIVE CONTROL, and the highest-value one in the file. A line ending
      # on a bare ADR number whose successor does NOT open with a section sign
      # is the ~120-site out-of-scope corpus. An over-greedy lookahead — one
      # that drops the next-line requirement — swallows all of it, and this is
      # what says so.
      trailing = "  # the rule is in ADR " <> number <> "\n" <> "  # and it says so.\n"

      # NEGATIVE CONTROL. A correct anchored citation, spanning nothing. It
      # clears every rule.
      anchored = "  # " <> adr <> " " <> sign <> " Per-step outcome" <> " governs this."

      source = wrapped <> split <> trailing <> anchored

      joined =
        "# positions map to the digits per ADR " <>
          number <> " " <> sign <> "\"Phantom halt semantics\"; the rest."

      assert [
               {:bare_anchor, "fixture.ex", 1, ^joined},
               {:split, "fixture.ex", 3, _}
             ] = offences_in("fixture.ex", source, headings)
    end

    test "the wrapped offence's detail is what the ratchet recovers its ADR number from" do
      # THE VACUITY CONTROL for the detail-join, asserted through the consumer
      # that depends on it rather than through the string's shape.
      # `bare_anchor_counts/1` does not carry the ADR number forward from the
      # detector — it RE-SCANS each offence's `detail` with the on-line,
      # section-sign-requiring `@bare_anchor_regex`. A wrapped offence whose
      # detail were its first line alone carries no section sign, so the
      # recovery matches nothing, the offence contributes ZERO `{path, number}`
      # keys, and it disappears from all three ratchet tests while still being
      # "detected" — the widening green and asserting nothing.
      #
      # Stage 1 measured that hole once, by hand, and reverted. This is the
      # permanent form: trim the detail back to one line and this goes red.
      headings = adr_headings_by_file()
      sign = "§"
      number = "0099"

      wrapped =
        "  # positions map to the digits per ADR " <>
          number <> "\n" <> "  " <> sign <> "\"Phantom halt semantics\"; the rest."

      offences = offences_in("fixture.ex", wrapped, headings)

      assert %{{"fixture.ex", number} => 1} ==
               bare_anchor_counts(%{offenders: offences, headings_by_adr: headings})
    end

    test "the advisory anchor read handles the three shapes in the corpus, and decides nothing" do
      # Fixtures piecewise, as everywhere in this file: a contiguous literal of
      # the banned form here would be a real offence against the rule.
      sign = "§"

      # The three shapes actually present in the corpus.
      quoted = " " <> "\"Rollup-branch merge\"" <> ", which never landed."
      quoted_with_space = "  " <> "\"Status divergence handling\"" <> " — see below."
      bare_word = " Rationale, and the rest of the sentence."

      assert extract_anchor_text(quoted) == "Rollup-branch merge"
      assert extract_anchor_text(quoted_with_space) == "Status divergence handling"
      assert extract_anchor_text(bare_word) == "Rationale"

      # Bare-word variants that are not words.
      assert extract_anchor_text("D3") == "D3"
      assert extract_anchor_text("3") == "3"

      # Nothing to read is reported as nothing, not as a guess.
      assert extract_anchor_text("") == ""
      assert extract_anchor_text("   ") == ""

      # Bounded: a runaway read cannot paste a paragraph into the advice.
      long = " " <> String.duplicate("a", 200)
      assert String.length(extract_anchor_text(long)) <= 60

      # THE LOAD-BEARING ASSERTION. The offence tuple — which is what every
      # ratchet assertion is computed from — must be identical whatever this
      # heuristic would read off the line. Two lines whose anchor TEXT differs
      # wildly produce the same kind, and the detail stays the trimmed source
      # line rather than anything the heuristic produced.
      headings = adr_headings_by_file()
      readable = "  # see ADR " <> "0041" <> " " <> sign <> "\"Rollup-branch merge\""
      unreadable = "  # see ADR " <> "0041" <> " " <> sign

      assert [{:bare_anchor, _, 1, readable_detail}] =
               offences_in("fixture.ex", readable, headings)

      assert [{:bare_anchor, _, 1, unreadable_detail}] =
               offences_in("fixture.ex", unreadable, headings)

      assert readable_detail == String.trim(readable)
      assert unreadable_detail == String.trim(unreadable)
    end

    test "the advice names every file carrying an ambiguous number, and says when a section exists nowhere" do
      headings = adr_headings_by_file()
      sign = "§"

      # FACT 1, ambiguous case. Two files under docs/decisions/ carry 0042; the
      # advice must name BOTH, because naming one would be the coin flip the
      # bare form is banned for.
      ambiguous = "  # see ADR " <> "0042" <> " " <> sign <> "\"Context inheritance\""
      advice = anchor_advice(ambiguous, headings)

      carriers_0042 =
        headings |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "0042" <> "-"))

      assert length(carriers_0042) == 2,
             "expected two ADR files numbered 0042; found #{inspect(carriers_0042)}"

      assert advice =~ "AMBIGUOUS"

      for file <- carriers_0042 do
        assert advice =~ file, "the ambiguity advice omitted #{file}"
      end

      # FACT 1, unambiguous case. One file carries 0041, and it is the
      # org-memory ADR — NOT the stacks ADR that the 0041 citations in this
      # tree are reaching for. The advice names the file it really is.
      single = "  # see ADR " <> "0041" <> " " <> sign <> "\"Rollup-branch merge\""
      single_advice = anchor_advice(single, headings)

      carriers_0041 =
        headings |> Map.keys() |> Enum.filter(&String.starts_with?(&1, "0041" <> "-"))

      assert [only_0041] = carriers_0041
      assert single_advice =~ only_0041

      # FACT 2, the ticket's finding made self-evident at failure time. The
      # section this citation names is in NO ADR, so the message must say the
      # section was never written rather than imply a repointing fix.
      assert files_carrying_heading("Rollup-branch merge", headings) == []
      assert single_advice =~ "NO file"
      assert single_advice =~ "never"
      assert single_advice =~ "Do not delete the citation."

      # FACT 2, the other branch. A heading that DOES exist somewhere gets the
      # "anchor to that file" advice instead — otherwise the no-carrier
      # message above would be unfalsifiable boilerplate that fires for
      # everything.
      {carrier, [heading | _]} =
        Enum.find(headings, fn {_file, hs} -> hs != [] end)

      existing = "  # see ADR " <> "0041" <> " " <> sign <> "\"" <> heading <> "\""
      existing_advice = anchor_advice(existing, headings)

      assert existing_advice =~ "Anchor the citation to that file."
      assert existing_advice =~ carrier
      refute existing_advice =~ "NO file"
    end

    test "the detector flags the bare-anchor form and clears the anchored and ordinal forms" do
      headings = adr_headings_by_file()

      # Every fixture is built piecewise for the same reason the fixtures above
      # are: this file is inside the corpus the audit walks, so a contiguous
      # literal of the banned form written here would be a real offence against
      # the rule this test is adding.
      sign = "§"
      bare = fn number, tail -> "  # see ADR " <> number <> " " <> sign <> tail end

      # FIRES. The shape the ticket found, plus the punctuation variants in the
      # corpus, plus the SPACED variant (a space between the sign and the quoted
      # heading) which `tasks_live_test.exs` uses and which must not escape.
      for line <- [
            bare.("0041", "\"Rollup-branch merge\""),
            "  # ADR-" <> "0043" <> " " <> sign <> " Rationale",
            "  # ADR " <> "0040" <> " " <> sign <> "D3",
            "  # ADR" <> "0042" <> sign <> "3",
            bare.("0041", " \"Status divergence handling\"")
          ] do
        assert [{:bare_anchor, _, 1, detail}] = offences_in("fixture.ex", line, headings),
               "expected a bare-anchor offence for: " <> line

        assert detail == String.trim(line)
      end

      # SWALLOW CONTROL — the load-bearing assertion. The anchored form must
      # keep failing (or passing) on its OWN mechanism. Assert the FULL list,
      # not `Enum.any?`, so a second kind appearing beside the first fails.
      adr = "0046-design-and-architecture-phases-in-planning" <> ".md"

      good = "  # " <> adr <> " " <> sign <> " Architect prompt contract" <> " — the rule."
      assert offences_in("fixture.ex", good, headings) == []

      wrong = "  # " <> adr <> " " <> sign <> " Architect prompt contracts" <> " — the rule."
      assert [{:unresolved_heading, _, 1, _}] = offences_in("fixture.ex", wrong, headings)

      # DISCRIMINATION CONTROL. None of these are the banned form, and each is
      # a shape a greedier selector would swallow.
      for line <- [
            "  # ADR-0046 decision 7 falls open",
            "  # see ADR-0042 for the topology",
            "  # line 95 of ADR-0046 was a fence",
            "  # never use the ADR-NNNN:LINE form",
            "  # " <> sign <> " Branch model, with no ADR number before it",
            "  # ADR 0041 (Branch model)"
          ] do
        assert offences_in("fixture.ex", line, headings) == [],
               "expected no offence for: " <> line
      end
    end
  end

  # ── Scanning ──────────────────────────────────────────────────────

  defp source_files do
    @umbrella_apps
    |> Path.join("**/*.{ex,exs,heex}")
    |> Path.wildcard()
    # `/_build` rather than `/_build/`: OTP-version-suffixed build paths
    # (`_build_otp28/`, used to run this suite under the CI image on a host
    # whose Erlang is too old) hold verbatim COPIES of `priv/` sources, so the
    # narrower match reported every migration twice — once as the real file and
    # once as its build artefact. Any directory whose name starts `_build` is
    # output, never authored source.
    |> Enum.reject(
      &(String.contains?(&1, "/_build") or String.contains?(&1, "/deps/") or
          String.contains?(&1, "/node_modules/"))
    )
    |> Enum.sort()
  end

  defp scan_source(relative_path, source, headings_by_adr, {citations, offenders}) do
    lines = String.split(source, "\n")
    found = offences_in(relative_path, source, headings_by_adr)

    resolved =
      for {line, index} <- Enum.with_index(lines, 1),
          {adr, tail} <- citation_heads(line),
          heading = longest_heading_prefix(tail, Map.get(headings_by_adr, adr, [])),
          heading != nil,
          do: {relative_path, index, adr, heading}

    {resolved ++ citations, found ++ offenders}
  end

  # The whole detector, over a source string. Returns
  # `{kind, path, line_number, detail}` tuples, sorted by line. Kept
  # source-string-shaped rather than path-shaped so the tests above can pin it
  # on synthetic fixtures without touching the filesystem.
  defp offences_in(relative_path, source, headings_by_adr) do
    lines = String.split(source, "\n")
    numbered = Enum.with_index(lines, 1)
    next_lines = Enum.drop(lines, 1) ++ [""]

    Enum.zip(numbered, next_lines)
    |> Enum.flat_map(fn {{line, index}, next_line} ->
      line_offences(relative_path, line, index, next_line, headings_by_adr)
    end)
  end

  defp line_offences(path, line, index, next_line, headings_by_adr) do
    split_offences(path, line, index, next_line) ++
      resolution_offences(path, line, index, headings_by_adr) ++
      pin_offences(path, line, index) ++
      bare_anchor_offences(path, line, index, next_line) ++
      test_name_offences(path, line, index)
  end

  defp split_offences(path, line, index, next_line) do
    cond do
      Regex.match?(@dangling_section_regex, line) ->
        [{:split, path, index, "the heading is missing — `§` is the last thing on the line"}]

      Regex.match?(@dangling_filename_regex, line) and
          Regex.match?(@orphan_section_regex, next_line) ->
        [{:split, path, index, "`§` and its heading were wrapped onto the next line"}]

      true ->
        []
    end
  end

  defp resolution_offences(path, line, index, headings_by_adr) do
    for {adr, tail} <- citation_heads(line),
        offence = resolve_citation(adr, tail, headings_by_adr),
        offence != nil,
        do: {elem(offence, 0), path, index, elem(offence, 1)}
  end

  defp resolve_citation(adr, tail, headings_by_adr) do
    case Map.fetch(headings_by_adr, adr) do
      :error ->
        {:unknown_adr, "no `docs/decisions/#{adr}`"}

      {:ok, headings} ->
        cond do
          tail == "" -> nil
          longest_heading_prefix(tail, headings) != nil -> nil
          true -> {:unresolved_heading, "#{adr} has no heading matching `#{tail}`"}
        end
    end
  end

  defp pin_offences(path, line, index) do
    if Regex.match?(@line_pinned_regex, line) do
      [{:line_pinned, path, index, String.trim(line)}]
    else
      []
    end
  end

  # Deliberately NOT folded into `test_name_offences/3`'s `cited?` disjunction.
  # A bare anchor inside a test name is already caught here, wherever on the
  # line it appears; adding it there would report one site under two kinds,
  # which is the collapse problem of rationale 2 above running in reverse.
  #
  # Two branches, ONE kind. The wrapped form is the same defect with a newline
  # in it, and the ratchet is keyed off `:bare_anchor`; a separate kind would
  # need a parallel pin set for two sites and would let each half hide behind
  # the other's count.
  #
  # The wrapped branch's `detail` is the JOINED text of both lines, and that is
  # load-bearing, not cosmetic. `bare_anchor_counts/1` and `sites_for/2` do not
  # carry the ADR number forward — they RECOVER it by re-scanning the offence's
  # own `detail` with `@bare_anchor_regex`, which requires the section sign. A
  # wrapped offence whose detail were its first line alone carries no section
  # sign, so the recovery would match nothing, the offence would contribute
  # ZERO `{path, number}` keys, and it would vanish from every pin comparison
  # while still being "detected" — all three ratchet tests green, the pin never
  # moving, the widening asserting nothing. Measured, not assumed: with the
  # first-line-only detail the pin stayed satisfied at its pre-widening total;
  # with the joined detail the ratchet went red naming both new sites. Joining
  # here rather than special-casing the wrapped shape in the two consumers
  # keeps that recovery a single unbranched path.
  defp bare_anchor_offences(path, line, index, next_line) do
    cond do
      Regex.match?(@bare_anchor_regex, line) ->
        [{:bare_anchor, path, index, String.trim(line)}]

      Regex.match?(@wrapped_bare_anchor_regex, line) and
          Regex.match?(@orphan_section_regex, next_line) ->
        [{:bare_anchor, path, index, String.trim(line) <> " " <> String.trim(next_line)}]

      true ->
        []
    end
  end

  defp test_name_offences(path, line, index) do
    cited? =
      Regex.match?(@citation_head_regex, line) or Regex.match?(@line_pinned_regex, line)

    if Regex.match?(@test_name_regex, line) and cited? do
      [{:test_name, path, index, String.trim(line)}]
    else
      []
    end
  end

  # ── Citation parsing ──────────────────────────────────────────────

  # `{adr_filename, text_following_the_section_sign}` for every anchored
  # citation head on one line. Byte offsets throughout — `§` is two bytes in
  # UTF-8 and `Regex.scan/3` with `return: :index` reports bytes, which is what
  # `binary_part/3` wants.
  defp citation_heads(line) do
    @citation_head_regex
    |> Regex.scan(line, return: :index)
    |> Enum.map(fn [{head_start, head_length}, {file_start, file_length}] ->
      adr = binary_part(line, file_start, file_length)
      tail_start = head_start + head_length

      tail =
        line
        |> binary_part(tail_start, byte_size(line) - tail_start)
        |> String.trim_leading()

      {adr, tail}
    end)
  end

  # The longest ADR heading that `tail` starts with, or nil. Resolving against
  # the file's real headings — rather than parsing the heading out of the line
  # with a terminator — is what lets a heading contain a comma, an em-dash or a
  # backtick without the detector having to know. The boundary check stops
  # `§ Context` from matching a citation of `§ Contextual drift`.
  defp longest_heading_prefix(tail, headings) do
    headings
    |> Enum.filter(&heading_prefix?(tail, &1))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  defp heading_prefix?(tail, heading) do
    if String.starts_with?(tail, heading) do
      rest = binary_part(tail, byte_size(heading), byte_size(tail) - byte_size(heading))
      rest == "" or not Regex.match?(~r/^[[:alnum:]]/u, rest)
    else
      false
    end
  end

  defp adr_headings_by_file do
    @adr_dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Map.new(fn path -> {Path.basename(path), headings_in(File.read!(path))} end)
  end

  defp headings_in(body) do
    ~r/^#+\s+(.+?)\s*$/m
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
  end

  # ── The ratchet ───────────────────────────────────────────────────

  # `%{{path, adr_number} => count}` over the live scan. Counted per ANCHOR,
  # not per line: `bare_anchor_offences/3` emits one offence per offending
  # line, and a line can carry two anchors, so the numbers are recovered by
  # re-scanning the offence's own detail with the same regex that flagged it.
  defp bare_anchor_counts(ctx) do
    ctx
    |> of_kind(:bare_anchor)
    |> Enum.flat_map(fn {_kind, path, _index, detail} ->
      @bare_anchor_regex
      |> Regex.scan(detail)
      |> Enum.map(fn [_match, number] -> {path, number} end)
    end)
    |> Enum.frequencies()
  end

  defp pin_keys do
    Enum.map(@dangling_anchor_pins, fn {path, number, _count} -> {path, number} end)
  end

  defp count_drift_line({{path, number}, pinned, actual}) when actual > pinned do
    "  #{path} (ADR #{number}): count went UP, #{pinned} -> #{actual}. A NEW " <>
      "dangling citation landed in a file that already had some. Fix the new " <>
      "one by naming the ADR file; do not raise the pinned count."
  end

  defp count_drift_line({{path, number}, pinned, actual}) do
    "  #{path} (ADR #{number}): count went DOWN, #{pinned} -> #{actual}. A " <>
      "citation was fixed. Decrement the row to #{actual} so the ratchet " <>
      "holds the new floor."
  end

  # The offending lines themselves, quoted from source at report time. This is
  # where the citation text lives — deliberately not in the pin.
  #
  # Each site carries two COMPUTED facts under it (see `anchor_advice/2`).
  # Nothing here is hardcoded: both are derived from `docs/decisions/` at
  # report time, so they cannot go stale against the tree the way a written
  # list of "known-bad anchors" would.
  defp sites_for(ctx, keys) do
    key_set = MapSet.new(keys)
    headings_by_adr = Map.get(ctx, :headings_by_adr, %{})

    sites =
      ctx
      |> of_kind(:bare_anchor)
      |> Enum.filter(fn {_kind, path, _index, detail} ->
        @bare_anchor_regex
        |> Regex.scan(detail)
        |> Enum.any?(fn [_match, number] -> MapSet.member?(key_set, {path, number}) end)
      end)
      |> Enum.map_join("\n\n", fn {_kind, path, index, detail} ->
        "  #{path}:#{index} — #{detail}\n" <> anchor_advice(detail, headings_by_adr)
      end)

    """
    Offending sites. Under each one: which file(s) actually carry that ADR
    number, and whether the cited section exists anywhere under
    docs/decisions/ at all.

    A citation whose section exists NOWHERE is not a misnumbered pointer — it
    is a reference to a section nobody wrote. The repair is to write that
    section into the ADR that should own it and then anchor the citation to
    it. That is the worked example already pinned by this audit: rather than
    delete a citation whose target was missing, the section was added to the
    ADR and the citation anchored to the new heading. Deleting the citation to
    make this test green is not one of the options — it destroys the only
    record that the decision was ever claimed to exist.

    #{sites}
    """
  end

  # ── Bare-anchor advice ────────────────────────────────────────────
  #
  # Two computed facts per offending anchor, both read out of
  # `docs/decisions/` at report time:
  #
  #   1. Which file(s) carry the cited ADR number. For a number owned by two
  #      files this says so explicitly — that ambiguity is the whole reason the
  #      bare form is banned (moduledoc, and `apps/platform/AGENTS.md`).
  #   2. Whether the cited section exists anywhere under `docs/decisions/`. If
  #      it does, the fix is "anchor to that file". If it does not, the section
  #      was never written and the fix is to write it.
  #
  # Fact 2 needs the anchor TEXT, and reading it back off the line is exactly
  # the terminator problem the moduledoc refuses to solve for the anchored form
  # (rule 3 rationale). `extract_anchor_text/1` is therefore an openly
  # BEST-EFFORT read, and it is confined to advice: the pass/fail decision
  # stays purely "is there a filename before the section sign", made by
  # `bare_anchor_offences/3` without consulting any of this. A heuristic that
  # decides nothing cannot be wrong in a way that matters — the worst it can do
  # is offer a reader a lookup on a truncated string, which the reader can see
  # because the message quotes what it read.
  defp anchor_advice(detail, headings_by_adr) do
    @bare_anchor_regex
    |> Regex.scan(detail, return: :index)
    |> Enum.map_join("\n", fn [{match_start, match_length}, {number_start, number_length}] ->
      number = binary_part(detail, number_start, number_length)
      tail_start = match_start + match_length
      tail = binary_part(detail, tail_start, byte_size(detail) - tail_start)
      text = extract_anchor_text(tail)

      "      " <>
        number_advice(number, headings_by_adr) <>
        "\n      " <> heading_advice(text, headings_by_adr)
    end)
  end

  defp number_advice(number, headings_by_adr) do
    case adr_files_for(number, headings_by_adr) do
      [] ->
        "No file under docs/decisions/ carries the number #{number} at all — " <>
          "the citation names a document that does not exist."

      [only] ->
        "ADR #{number} is `#{only}` — name it: `#{only} § <heading>`."

      several ->
        "AMBIGUOUS: #{length(several)} files carry the number #{number} — " <>
          Enum.join(several, ", ") <>
          ". A bare `#{number}` is a coin flip between them, which is why " <>
          "this form is banned; only the filename disambiguates."
    end
  end

  defp heading_advice("", _headings_by_adr) do
    "No section text follows the sign on this line, so there is nothing to " <>
      "look up — name the file and the heading you mean."
  end

  defp heading_advice(text, headings_by_adr) do
    case files_carrying_heading(text, headings_by_adr) do
      [] ->
        "Cited section (best-effort read of this line): `#{text}`. NO file " <>
          "under docs/decisions/ has that heading. The section was never " <>
          "written — write it into the ADR that should own it, then anchor " <>
          "the citation to it. Do not delete the citation."

      files ->
        "Cited section (best-effort read of this line): `#{text}` — that " <>
          "heading exists in " <>
          Enum.join(files, ", ") <>
          ". Anchor the citation to that file."
    end
  end

  defp adr_files_for(number, headings_by_adr) do
    headings_by_adr
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, number <> "-"))
    |> Enum.sort()
  end

  defp files_carrying_heading(text, headings_by_adr) do
    for({file, headings} <- headings_by_adr, text in headings, do: file) |> Enum.sort()
  end

  # BEST-EFFORT, advisory only. Strip a leading quote and cut at the closing
  # one; failing that, cut at the first terminator the corpus actually uses.
  # Capped so a runaway read cannot paste a whole line of prose into the
  # advice. It is never consulted by any assertion.
  @anchor_text_cap 60
  @anchor_terminators [".", ",", ")", "—", "`", "\""]

  defp extract_anchor_text(tail) do
    tail = String.trim_leading(tail)

    text =
      case tail do
        "\"" <> rest -> rest |> String.split("\"", parts: 2) |> hd()
        _ -> cut_at_terminator(tail)
      end

    text
    |> String.slice(0, @anchor_text_cap)
    |> String.trim()
  end

  defp cut_at_terminator(text) do
    @anchor_terminators
    |> Enum.reduce(text, fn terminator, acc ->
      acc |> String.split(terminator, parts: 2) |> hd()
    end)
  end

  # ── Reporting ─────────────────────────────────────────────────────

  defp of_kind(ctx, kind) do
    ctx.offenders
    |> Enum.filter(&(elem(&1, 0) == kind))
    |> Enum.sort_by(fn {_kind, path, index, _detail} -> {path, index} end)
  end

  defp report(offenders, explanation), do: report(offenders, explanation, %{})

  defp report(offenders, explanation, headings_by_adr) do
    sites =
      Enum.map_join(offenders, "\n", fn {_kind, path, index, detail} ->
        "  #{path}:#{index} — #{detail}"
      end)

    """
    #{String.trim_trailing(explanation)}

    The rule and its rationale live in `apps/platform/AGENTS.md` § Citing ADRs.

    Offending sites:

    #{sites}
    #{existing_headings(offenders, headings_by_adr)}
    """
  end

  # The other half of "say what to do". A bare mismatch tells the reader that
  # 29 sites broke and leaves them to go find what the heading was renamed TO;
  # when the rename is the cause — which it usually is — the new name is in
  # this list and the fix is a copy. Mirrors `architecture_gate_test.exs`'s
  # `Headings that DO exist:` block, which only ever fires for the single
  # citation it hard-codes.
  #
  # Emitted once per cited ADR rather than once per site: the sites here share
  # a handful of ADRs between them, and repeating one file's heading list 29
  # times buries the answer it exists to hand over.
  defp existing_headings(offenders, headings_by_adr) do
    offenders
    |> Enum.flat_map(fn {_kind, _path, _index, detail} ->
      @adr_filename_regex |> Regex.scan(detail) |> List.flatten()
    end)
    |> Enum.uniq()
    |> Enum.flat_map(fn adr ->
      case Map.fetch(headings_by_adr, adr) do
        {:ok, headings} -> ["\nHeadings that DO exist in #{adr}: #{Enum.join(headings, ", ")}"]
        :error -> []
      end
    end)
    |> Enum.join("\n")
  end
end
