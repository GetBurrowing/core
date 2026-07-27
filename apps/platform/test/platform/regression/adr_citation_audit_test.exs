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

  ## What is deliberately NOT covered

  **Bare ADR numbers (`ADR-0042`), and decision ordinals (`ADR-0046 decision
  7`, `Decision 4`).** ~120 sites across the umbrella. Three reasons, and the
  gap is documented here rather than left implicit because an undocumented gap
  in an audit reads as coverage:

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
  end

  # ── Scanning ──────────────────────────────────────────────────────

  defp source_files do
    @umbrella_apps
    |> Path.join("**/*.{ex,exs,heex}")
    |> Path.wildcard()
    |> Enum.reject(
      &(String.contains?(&1, "/_build/") or String.contains?(&1, "/deps/") or
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
