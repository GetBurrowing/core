defmodule Platform.Regression.SystemEventEnvelopeRecordAuditTest do
  # The marker is assembled from two halves so that THIS file never contains it
  # contiguously. The audit walks a corpus SELECTED by the marker, and a literal
  # here would put the auditor inside its own corpus — the same piecewise trick
  # `adr_citation_audit_test.exs` uses for its fixture citations.
  @marker "ENVELOPE-" <> "RECORD"

  @moduledoc """
  Source-scan guard that makes the `#{@marker} N/3` decision records about the
  `system_event` attention envelope *navigable* — every cross-reference one
  record makes must resolve against the file it names, and the named file must
  independently agree about its own identity (task `019fa63a-02a0`, stage 3).

  THE BUG BEING PINNED: one decision was recorded three times, in three files,
  in two repos, and no copy pointed at the others. A reader who found one copy
  had no way to learn that two more existed, or that one of them carried a
  retirement condition the others did not. Two of the pointers that DID exist
  were position pins (`src/index.ts` + a line number for a file that had since
  moved; `agent_responder.ex` + a line range that had drifted 47 lines into an
  unrelated comment), so they pointed confidently at the wrong text.

  ## Why this audit resolves rather than compares

  The org's ruling is explicit (`process-patterns.md § Cite ADR Headings, Not
  Line Numbers`, anti-vacuity clause): "Asserting an emitted citation string
  equals an expected literal is circular — both sides can agree while pointing
  nowhere." So nothing here is compared to a hardcoded expectation. The audit

    1. EXTRACTS references from the records' real source text,
    2. RESOLVES the `core:` ones against the filesystem, and
    3. asserts the target carries the claimed `§` anchor AND the reciprocal
       self-header the reference claims it has.

  Step 3 is what makes it non-circular: a reference cannot pass by agreeing
  with a constant in this file, only by agreeing with a file that says the same
  thing about itself for its own reasons.

  ## What is enforced

    1. Each record carries exactly one self-header, and the numbers are
       distinct.
    2. Each record names both other records exactly once.
    3. Every `core:` reference resolves to a real file.
    4. Every `core:` reference's `§` anchor is a literal substring of its
       target. The `describe "…"` wrapper form is trimmed to its inner literal
       first — the source line for record 1's anchor carries a parenthetical
       suffix (`… (chatless responsibility fire)`) that the reference
       deliberately does not repeat, because repeating it would make the
       reference rot on a rename of the parenthetical alone.
    5. Every `core:` target carries the self-header the reference claims for
       it. THE RECIPROCITY ASSERTION.
    6. No reference carries a line pin.
    6b. No line pin appears ANYWHERE in a record file, in a reference or not.
       Numbered `6b` rather than renumbered into the sequence on purpose: this
       moduledoc, the assertion bodies and the mirror audit in
       `claude-code-suite-channel` all address these by number, and shifting
       7-9 down would rot every one of those pointers. A citation that breaks
       when something is inserted above it is the defect this whole task is
       about; the audit should not commit it in its own table of contents.
    7. Every record carries all four clause labels — `DECIDED:`, `WHY:`,
       `WHAT WOULD RETIRE THIS:`, `RETIREMENT STATUS`. This is the ticket's ask
       made enforceable: a record cannot be added without a falsifier.
    8. Cross-repo references are well-formed. SHAPE ONLY — see below.
    9. The scan is not vacuous.

  ## What this audit cannot do

  **It cannot resolve a cross-repo reference.** Record 3 lives in
  `claude-code-suite-channel` and is not on disk from here. Assertion 8 checks
  that such a reference names a KNOWN repo token and a source-file-shaped path;
  it does not and cannot check that the file exists, that the anchor is there,
  or that record 3 exists at all. Green on assertion 8 means "this reference is
  shaped like a reference", nothing more. Record 3's own resolution — and the
  mirror of this audit that performs it — belongs to its own repo.

  **It cannot check that a record is TRUE.** It checks that the records agree
  about each other's identity and location, that each carries a falsifier, and
  that the pointers resolve. Whether `WHAT WOULD RETIRE THIS:` states a
  condition worth retiring on is a human judgement.

  **It does not police prose.** The clause check is presence, not shape: a
  record may say more than the four labels, in any order, and the labels are
  matched anywhere in the file rather than inside a parsed block. A stricter
  rule would fail on the next record whose author writes it slightly
  differently, which trains authors to delete the audit rather than the defect.

  ## Corpus selection

  The corpus is DISCOVERED, not listed: `lib/**/*.ex` + `test/**/*.exs` under
  the app root, keeping every file that carries the marker. A hardcoded pair of
  paths would silently stop auditing a record the moment someone moved one.
  Exactly two are expected — records 1 and 2 are in core; record 3 is not
  reachable from here — and that count is asserted in `the scan is not
  vacuous`, deliberately in the same test as the emptiness floors so that a
  marker rename fails ONE assertion with one clear cause rather than nine.

  ## Anti-vacuity

  Every reference lives in a comment, so like `adr_citation_audit_test.exs`
  this audit must not strip comments — stripping would leave an empty buffer
  and pass forever. `the scan is not vacuous` is the control: without it,
  assertions 1-8 all pass against an empty corpus, because every one of them is
  a statement about a list.

  Cheap by construction (`File.read` + `Regex`, no DB, no PubSub) and carries
  no `@moduletag`, so it runs in the default `mix test` set. Peer of
  `adr_citation_audit_test.exs`.
  """

  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)
  @repo_root Path.expand("../../../../..", __DIR__)

  # The marker as a standalone token. The negative lookahead is load-bearing:
  # without it `#{@marker}X` still matches on the substring, so renaming the
  # marker would leave the files in the corpus with zero parseable headers and
  # fail assertion 1 for a cause that has nothing to do with headers.
  @marker_regex ~r/#{@marker}(?![A-Za-z0-9_-])/

  # A record's claim about its own identity. One per record file.
  @self_header_regex ~r/#{@marker}\s+(\d)\/3/

  # A reference to a sibling record: number, repo token, path, `§` anchor, and
  # the task that established it. The whole construct must be on one source
  # line — a reference wrapped across two lines is invisible to this audit
  # while still looking resolvable to a human reviewer.
  @reference_regex ~r/(\d)\/3\s+([a-z0-9-]+):(\S+)\s+§\s+(.+?)\s+\((019f[0-9a-f-]+)\)/

  # The head of a reference, used to catch lines that MEANT to be references —
  # including malformed ones the full grammar rejects — so a line pin cannot
  # escape assertion 6 by also breaking the parse.
  @reference_head_regex ~r/(\d)\/3\s+[a-z0-9-]+:/

  # A source path followed by a colon and a digit: the banned position pin.
  @line_pin_regex ~r/\.(ex|exs|ts):\d/

  # THE SAME BAN WITHOUT THE REFERENCE PREREQUISITE, applied to every line of a
  # record rather than to its reference heads alone.
  #
  # Assertion 6 consults `@line_pin_regex` only for lines `@reference_head_regex`
  # already selected, and that regex demands `N/3 <repo>:` — so it can only ever
  # catch a pin written inside a sibling reference. Every pin this task actually
  # found was BARE: a filename and a position, in ordinary prose, with no repo
  # token and no record number anywhere near it. The ban as first written was
  # therefore enforced against the one shape that had not rotted, and silent
  # about the shape that had. A reviewer demonstrated the escape on the mirror
  # side rather than arguing it — a bare pin appended inside the record scored a
  # full green.
  #
  # Core's two records carry no pins today, so this assertion is a guard against
  # recurrence rather than a fix. It is here anyway: a ban enforced in one repo
  # and not the other is the same gap wearing a different hat, and core is the
  # repo where both of the rotted targets actually live.
  #
  # The extension list is what keeps it off ordinary prose — a clock time, a
  # timestamp, a bare version, a port, a ratio, or a filename with no position
  # all fail it, because it demands a source-file extension immediately followed
  # by a colon and a digit.
  #
  # KNOWN BOUNDARY, measured and left in place: the list is SOURCE extensions,
  # so a pin into `package.json:5` or `process-patterns.md:12` does not match
  # and is not banned — awkward, given the org rule this enforces lives in a
  # markdown file. Widening it is a different decision with a different
  # false-positive profile (`.md:` and `.json:` appear in prose far more often
  # than `.ex:` does), and this task's defect was bare SOURCE pins. Recorded so
  # the next reader knows it is a boundary someone measured, not one nobody
  # noticed.
  #
  # The trailing `\d+(-\d+)?` is for the failure message rather than the
  # trigger: `:\d` matches identically but quotes back `foo.ex:4` for a pin
  # reading `foo.ex:485-487`.
  #
  # MEASURED, not assumed. Core's records are clean, so this assertion passes on
  # an unmutated tree — exactly the condition under which a new check is most
  # likely to be decorative. It was therefore run against an injected bare pin,
  # `(see attention.ts:207)` appended inside record 2/3 in `agent_responder.ex`:
  # 10 tests, ONE failure, this assertion alone, reporting
  # ``lib/platform/chat/agent_responder.ex (line 513) — line pin
  # `attention.ts:207` ``. Assertion 6 stayed GREEN under that same mutation,
  # which is the correct split — a bare mention is not a reference head.
  # Reverted; the suite returns 10 tests, 0 failures.
  @bare_line_pin_regex ~r/\b[\w.-]+\.(ex|exs|ts|tsx|js|mjs):\d+(-\d+)?/

  # An anchor written as the `describe`/`test` block that carries it. Trimmed
  # to the inner literal before resolution — see assertion 4 in the moduledoc.
  @block_anchor_regex ~r/^(?:describe|test)\s+"(.+)"$/

  @source_path_regex ~r/\.(ex|exs|ts|tsx|js|mjs)$/

  @known_repos ~w(core claude-code-suite-channel openclaw-suite-channel)

  @clause_labels ["DECIDED:", "WHY:", "WHAT WOULD RETIRE THIS:", "RETIREMENT STATUS"]

  @all_record_numbers MapSet.new([1, 2, 3])

  setup_all do
    records = scan_records()

    %{
      records: records,
      references: Enum.flat_map(records, & &1.references),
      file_count: length(records)
    }
  end

  describe "the envelope records cross-reference each other" do
    test "each core record carries exactly one self-header, and the two numbers are distinct",
         ctx do
      miscounted =
        for record <- ctx.records,
            length(record.self_headers) != 1,
            do:
              {record.path, first_line(record.self_headers),
               "carries #{length(record.self_headers)} self-headers " <>
                 "(#{inspect(Enum.map(record.self_headers, &elem(&1, 0)))}); a record must claim " <>
                 "exactly one identity"}

      duplicated =
        ctx.records
        |> Enum.filter(&(&1.number != nil))
        |> Enum.group_by(& &1.number)
        |> Enum.filter(fn {_number, records} -> length(records) > 1 end)
        |> Enum.flat_map(fn {number, records} ->
          claimants = Enum.map_join(records, ", ", & &1.path)

          for record <- records,
              do:
                {record.path, first_line(record.self_headers),
                 "claims to be record #{number}/3, and so does #{claimants} — " <>
                   "two files cannot be the same record"}
        end)

      offenders = Enum.sort(miscounted ++ duplicated)

      assert offenders == [],
             report(offenders, """
             A record's self-header is how every other record addresses it, and
             how assertion 5 confirms a reference landed where it claimed to.
             Exactly one per file, and no two files claiming the same number.
             """)
    end

    test "each record names both other records exactly once", ctx do
      offenders =
        for record <- ctx.records,
            record.number != nil,
            offence = sibling_offence(record),
            offence != nil,
            do: {record.path, first_line(record.self_headers), offence}

      assert offenders == [],
             report(offenders, """
             Each record must name the other two — that is the entire deliverable
             here. A reader who lands on one copy of this decision learns the
             others exist ONLY from these lines; a record that names one sibling
             instead of two restores exactly the condition this task was opened
             to fix.
             """)
    end

    test "every core: reference resolves to a real file", ctx do
      offenders =
        for reference <- core_references(ctx),
            not File.exists?(Path.join(@repo_root, reference.path)),
            do:
              {reference.record, reference.line,
               "points at `#{reference.path}`, which does not exist under the repo root"}

      assert offenders == [],
             report(offenders, """
             A `core:` reference names a path relative to the repository root.
             Either the target moved — update the reference — or the path was
             mistyped. Do not delete the reference to make this pass: a record
             with no siblings is the defect, not the fix.
             """)
    end

    test "every core: reference's anchor appears in its target", ctx do
      offenders =
        for reference <- core_references(ctx),
            offence = anchor_offence(reference),
            offence != nil,
            do: {reference.record, reference.line, offence}

      assert offenders == [],
             report(offenders, """
             The `§` anchor must be a literal substring of the file the
             reference names. This is what replaces the line pin: a heading or a
             function name either is in the file or is not, whereas a line number
             records no expectation at all and cannot be checked by anything.

             An anchor written as `describe "…"` is trimmed to its inner literal
             before the search, so a reference may name the block without
             repeating a parenthetical suffix. If the target renamed the thing,
             update the anchor to the new name; do not loosen the comparison,
             and do not edit the target to match the anchor.
             """)
    end

    test "every core: target carries the self-header the reference claims", ctx do
      offenders =
        for reference <- core_references(ctx),
            offence = reciprocity_offence(reference),
            offence != nil,
            do: {reference.record, reference.line, offence}

      assert offenders == [],
             report(offenders, """
             THE RECIPROCITY ASSERTION. A reference says "record N/3 lives in
             this file"; that file must independently say the same about itself.
             Nothing in this audit is compared to a constant — this is the
             assertion that makes it non-circular, because it can only pass when
             two files that were written separately agree.

             A failure means the reference is pointing at the wrong file, or at a
             file whose record was renumbered or removed.
             """)
    end

    test "no reference carries a line pin", ctx do
      offenders =
        for record <- ctx.records,
            {line, text} <- record.reference_lines,
            Regex.match?(@line_pin_regex, text),
            do: {record.path, line, "line-pinned reference: #{text}"}

      assert offenders == [],
             report(offenders, """
             A reference must name an anchor, never a line number. The rule and
             its rationale live in `process-patterns.md § Cite ADR Headings, Not
             Line Numbers`.

             Both pins this task found had already rotted, silently, and both
             still read as confident pointers:

               * a pin into `src/index.ts` at line 256 — pointing into a file the
                 code had since MOVED OUT OF, so the line resolved to unrelated
                 source in a file that no longer contained the thing cited;
               * a pin into `agent_responder.ex` at lines 485-487 — which had
                 drifted 47 lines and landed inside an unrelated comment block.

             Neither could be detected, because a line number records no
             expectation. Replace the pin with a `§` anchor naming the function,
             heading or `describe` block; assertion 4 then checks it for you on
             every run.
             """)
    end

    # ASSERTION 6b. Kept SEPARATE from assertion 6 rather than folded into it,
    # so the two mechanisms stay independently observable: a bare pin fails this
    # one alone, a pin inside a reference fails both, and the failing test name
    # says which selector caught it. Folding them together would leave the
    # narrower check unable to ever fail by itself, which is a check you can no
    # longer prove anything about.
    test "no line pin appears anywhere in a record, in a reference or not", ctx do
      offenders =
        for record <- ctx.records,
            {line, text, pin} <- record.pinned_lines,
            do: {record.path, line, "line pin `#{pin}`: #{text}"}

      assert offenders == [],
             report(offenders, """
             A line pin is banned WHEREVER it appears in a record — in a
             reference, in prose, in a code comment beside the thing being
             described. Assertion 6 only ever inspects lines that parse as
             sibling-reference heads, and every pin this task actually found was
             bare: a filename and a position, no repo token, no record number.
             The ban was enforced for the one shape that had not rotted and
             silent about the one that had.

             Both of the rotted pins pointed INTO THIS REPO — one into
             `agent_responder.ex` at lines 485-487, which had drifted 47 lines
             into an unrelated comment block, and one into `router.ex` at line
             1447, which no longer lands on the whitelist it named. Both still
             read as confident pointers. Neither could be detected, because a
             line number records no expectation.

             THIS IS NOT AN INSTRUCTION TO DELETE THE SENTENCE. A record's
             account of what rotted is the evidence for this rule and must
             survive. Name the file and the position separately — "pinned into
             `router.ex` at line 1447" carries the identical detail and is not a
             pointer anyone can follow into the wrong text. For a LIVE pointer,
             use a `§` anchor naming the function, heading or `describe` block;
             assertion 4 then checks it for you on every run.
             """)
    end

    test "every record carries all four clause labels", ctx do
      offenders =
        for record <- ctx.records,
            record.missing_labels != [],
            do:
              {record.path, first_line(record.self_headers),
               "is missing #{Enum.map_join(record.missing_labels, ", ", &"`#{&1}`")}"}

      assert offenders == [],
             report(offenders, """
             Every record states four things: what was DECIDED, WHY, WHAT WOULD
             RETIRE THIS, and the current RETIREMENT STATUS. The third is the
             falsifier and is the reason this audit exists — a decision recorded
             without one becomes an expired rule that a reader has no way to
             recognise as expired, which is the exact failure this task was
             opened for.

             Add the missing clause. If the honest answer is "nothing would
             retire this", write that down — a stated permanence is a claim
             someone can argue with; an absent clause is not.
             """)
    end

    test "cross-repo references are well-formed — SHAPE ONLY, this does not resolve them", ctx do
      offenders =
        for reference <- ctx.references,
            reference.repo != "core",
            offence = cross_repo_shape_offence(reference),
            offence != nil,
            do: {reference.record, reference.line, offence}

      assert offenders == [],
             report(offenders, """
             A reference into another repository cannot be resolved from here, so
             this is a SHAPE check and nothing more: the repo token must be one
             this org knows (#{Enum.join(@known_repos, ", ")}) and the path must
             look like a source file.

             GREEN HERE DOES NOT MEAN THE TARGET EXISTS. It does not mean record
             3 exists, that the file is where the reference says, or that the
             anchor is in it. Resolution of a cross-repo reference belongs to a
             mirror of this audit running inside that repository, where the file
             is actually on disk.
             """)
    end
  end

  describe "the audit itself" do
    test "the scan is not vacuous", ctx do
      # THE CONTROL. Every assertion above is a statement about a list, so all
      # eight pass against an empty corpus: rename the marker, break either
      # regex, or point the file walk at the wrong root, and the audit goes
      # green while guarding nothing. This test is the only thing standing
      # between that and a silent all-pass.
      assert ctx.file_count >= 2,
             "the corpus walk found #{ctx.file_count} record file(s). Two are known to " <>
               "exist in core. Either the marker was renamed, the file walk is pointed at " <>
               "the wrong root, or the records were deleted — in all three cases every " <>
               "other assertion in this file is now passing against an empty list."

      assert ctx.file_count == 2,
             "the corpus walk found #{ctx.file_count} record files: " <>
               "#{Enum.map_join(ctx.records, ", ", & &1.path)}. Exactly two are expected in " <>
               "core (record 3 is in another repo). A third core record is precisely the " <>
               "condition this task was opened about — one decision recorded in more places " <>
               "than its readers know about. If the new record is legitimate, it must name " <>
               "every sibling and be named BY every sibling, and this count updated " <>
               "deliberately."

      assert length(ctx.references) >= 4,
             "the scan found #{length(ctx.references)} sibling references; two records " <>
               "naming two siblings each is four. The reference regex has stopped matching " <>
               "the corpus that is known to be there."

      seen_repos = ctx.references |> Enum.map(& &1.repo) |> Enum.uniq() |> Enum.sort()

      assert "core" in seen_repos,
             "no `core:` reference was parsed (saw #{inspect(seen_repos)}), so the " <>
               "resolution assertions — path, anchor and reciprocity — all ran on an " <>
               "empty list."

      assert Enum.any?(seen_repos, &(&1 != "core")),
             "every parsed reference is `core:` (saw #{inspect(seen_repos)}), so the " <>
               "cross-repo shape assertion ran on an empty list. Record 3 lives in " <>
               "another repo and both core records are supposed to name it."
    end
  end

  # ── Scanning ──────────────────────────────────────────────────────

  defp scan_records do
    for path <- candidate_files(),
        source = File.read!(path),
        Regex.match?(@marker_regex, source),
        do: build_record(Path.relative_to(path, @app_root), source)
  end

  defp candidate_files do
    ["lib/**/*.ex", "test/**/*.exs"]
    |> Enum.flat_map(&(@app_root |> Path.join(&1) |> Path.wildcard()))
    |> Enum.reject(&(String.contains?(&1, "/_build/") or String.contains?(&1, "/deps/")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp build_record(relative_path, source) do
    numbered = source |> String.split("\n") |> Enum.with_index(1)

    self_headers =
      for {line, index} <- numbered,
          [_, number] <- Regex.scan(@self_header_regex, line),
          do: {String.to_integer(number), index}

    references =
      for {line, index} <- numbered,
          [raw, number, repo, path, anchor, task] <- Regex.scan(@reference_regex, line),
          do: %{
            record: relative_path,
            line: index,
            number: String.to_integer(number),
            repo: repo,
            path: path,
            anchor: anchor,
            task: task,
            raw: String.trim(raw)
          }

    reference_lines =
      for {line, index} <- numbered,
          Regex.match?(@reference_head_regex, line),
          do: {index, String.trim(line)}

    # No selector runs first. That is the whole point — the selector is what the
    # bare pins escaped through.
    pinned_lines =
      for {line, index} <- numbered,
          pin = Regex.run(@bare_line_pin_regex, line),
          do: {index, String.trim(line), hd(pin)}

    %{
      path: relative_path,
      number: sole_self_header_number(self_headers),
      self_headers: self_headers,
      references: references,
      reference_lines: reference_lines,
      pinned_lines: pinned_lines,
      missing_labels: Enum.reject(@clause_labels, &String.contains?(source, &1))
    }
  end

  defp sole_self_header_number([{number, _line}]), do: number
  defp sole_self_header_number(_), do: nil

  # ── Resolution ────────────────────────────────────────────────────

  defp core_references(ctx), do: Enum.filter(ctx.references, &(&1.repo == "core"))

  defp sibling_offence(record) do
    numbers = Enum.map(record.references, & &1.number)
    expected = MapSet.delete(@all_record_numbers, record.number)

    cond do
      numbers != Enum.uniq(numbers) ->
        "names #{inspect(Enum.sort(numbers))} — a sibling is referenced more than once"

      MapSet.new(numbers) != expected ->
        "is record #{record.number}/3 and names #{inspect(Enum.sort(numbers))}, but must " <>
          "name exactly #{inspect(Enum.sort(MapSet.to_list(expected)))}"

      true ->
        nil
    end
  end

  defp anchor_offence(reference) do
    needle = anchor_needle(reference.anchor)

    case File.read(Path.join(@repo_root, reference.path)) do
      {:error, reason} ->
        "claims anchor `#{reference.anchor}` in `#{reference.path}`, which cannot be read " <>
          "(#{inspect(reason)}) — an unresolvable path cannot carry an anchor"

      {:ok, body} ->
        if String.contains?(body, needle) do
          nil
        else
          "claims anchor `#{reference.anchor}` in `#{reference.path}`, which does not " <>
            "contain `#{needle}`"
        end
    end
  end

  # `describe "site 3 — …"` names a block; the resolvable literal is the block's
  # name, not the `describe` line, because the real source line may carry a
  # parenthetical the reference deliberately does not repeat.
  defp anchor_needle(anchor) do
    trimmed = String.trim(anchor)

    case Regex.run(@block_anchor_regex, trimmed) do
      [_, inner] -> inner
      nil -> trimmed
    end
  end

  defp reciprocity_offence(reference) do
    claimed = ~r/#{@marker}\s+#{reference.number}\/3/

    case File.read(Path.join(@repo_root, reference.path)) do
      {:error, reason} ->
        "claims `#{reference.path}` is record #{reference.number}/3, but that file " <>
          "cannot be read (#{inspect(reason)})"

      {:ok, body} ->
        if Regex.match?(claimed, body) do
          nil
        else
          "claims `#{reference.path}` is record #{reference.number}/3, but that file does " <>
            "not carry that self-header — the target does not agree about its own identity"
        end
    end
  end

  defp cross_repo_shape_offence(reference) do
    cond do
      reference.repo not in @known_repos ->
        "names repo `#{reference.repo}`, which is not one of #{inspect(@known_repos)}"

      not Regex.match?(@source_path_regex, reference.path) ->
        "names `#{reference.path}` in `#{reference.repo}`, which is not shaped like a " <>
          "source file"

      true ->
        nil
    end
  end

  # ── Reporting ─────────────────────────────────────────────────────

  defp first_line([{_number, line} | _]), do: line
  defp first_line(_), do: 0

  defp report(offenders, explanation) do
    sites =
      Enum.map_join(offenders, "\n", fn {path, line, detail} ->
        "  #{path} (line #{line}) — #{detail}"
      end)

    """
    #{String.trim_trailing(explanation)}

    Offending sites:

    #{sites}
    """
  end
end
