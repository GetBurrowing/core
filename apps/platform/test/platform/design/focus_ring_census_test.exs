defmodule Platform.Design.FocusRingCensusTest do
  @moduledoc """
  Census guard: no raw `focus-visible:ring-primary` may survive in application
  code, and the `focus-visible:ring-focus-ring` call sites that replaced it must
  still be there.

  ## What this closes

  Task `01a0833d` minted a theme-split `ring-focus-ring` utility (stage 1) and
  converted all 37 raw call sites (stages 2 and 3). The old utility painted
  `--color-primary` at 60% or 40% opacity, which measured 1.4775:1 on light
  `base-100` and 1.2026:1 on the `base-300` hover ground — well under the 3:1
  WCAG 2.2 SC 1.4.11 floor for a non-text indicator. Nothing stops a new
  component being written the old way, and nothing in CI would notice. This
  file is that check.

  It deliberately does NOT assert any contrast ratio.
  `test/platform/design/primary_contrast_sweep_test.exs` and
  `focus_ring_slot_test.exs` own the arithmetic; a ratio literal here would
  duplicate it in a guard whose question is only *which class names appear
  where*.

  ## Scope, and why it stops where it does

  Scanned: `lib/`, `assets/css/`, `assets/js/`, `assets/test/` and `test/`
  under `apps/platform`. Test files are in scope on purpose — a stale test
  assertion pinning the old class is one of the ways a repoint half-lands while
  the suite stays green, which is the same reasoning
  `border_token_direction_test.exs` gives for scanning `test/`.

  **Not scanned: `docs/` and `audit/`.** Those are prose. `audit/` still quotes
  the old utility in a May 2026 token cheatsheet, correctly — it is a record of
  what the design system said at the time, not an instruction. `docs/` was
  corrected in stage 3 and currently contains no occurrence of the forbidden
  literal at all, but it stays out of scope because the *right* content for a
  doc is to be able to name the thing it forbids. A guard that reds on
  documentation of what it forbids gets narrowed until it stops guarding.

  ## The two vacuity traps this file is built around

  **It matches its own source.** To search for `focus-visible:ring-primary` this
  file has to contain that string, several times over. Scanning `test/` therefore
  finds it here. The wrong fix is to narrow the glob until the self-match stops,
  because that is indistinguishable from narrowing it until nothing is scanned.
  The right fix is an explicit, asserted exclusion of exactly this one path — and
  test (a3) is the positive control on it: it asserts this file's own source
  really does contain the literal, so the exclusion is doing work rather than
  being decoration. If a future edit removes the literal from this file, (a3)
  fails and tells you the exclusion is now unnecessary, instead of leaving a
  silent carve-out behind.

  **A glob typo is invisible.** `Path.wildcard/1` on a wrong path returns `[]`,
  the forbidden-string assertion passes over zero files, and it passes forever
  after. `assert hits == []` cannot tell "nothing forbidden is present" from
  "nothing was looked at". Test (a1) is the floor: the scanned set is non-empty
  and contains named members that are known to exist and known to carry these
  classes.

  ## The detector is shown a case where it must say nothing

  Describe block (b) points `scan_text/2` at input whose correct output is no
  hits: text with no ring class, text carrying the *converted* class (which
  contains both `focus-visible:` and `ring-`, so a sloppy matcher flags it), and
  a bare non-focus `ring-primary`, which is a legitimate utility this repo uses
  live for the meeting speaking indicator and the message-anchor highlight. Then
  (b4) shows it firing on all three forbidden forms. The pair matters: a detector
  that has only ever been shown positives has not been shown to discriminate.
  """
  use ExUnit.Case, async: true

  @app_root Path.expand("../../..", __DIR__)

  # The class this task removed. Any occurrence in application code is a
  # regression: it paints --color-primary under the SC 1.4.11 floor in light,
  # and at /40 it was under the floor in dark as well.
  @forbidden "focus-visible:ring-primary"

  # What replaced it. Theme-split via --focus-ring, no alpha modifier ever.
  @required "focus-visible:ring-focus-ring"

  @scan_globs [
    "lib/**/*.ex",
    "lib/**/*.heex",
    "assets/css/**/*.css",
    "assets/js/**/*.js",
    "assets/test/**/*.js",
    "test/**/*.exs"
  ]

  # This file, and only this file. It must contain @forbidden in order to search
  # for it. Asserted exactly in (a2) so an entry cannot be quietly added.
  @self_path "test/platform/design/focus_ring_census_test.exs"
  @excluded [@self_path]

  # Re-derived from the tree at commit 4ad2c59c, not copied from the stage brief.
  # It happens to agree with the brief's breakdown exactly: 37 across 9 files.
  # New files carrying the class are fine (the total is a floor); these nine are
  # pinned so a conversion cannot silently regress.
  #
  # Task 01a0d8de stage 3 added three controls that carry the ring:
  # chat_message.ex's header "Context" button and hover-row "Summarise what
  # led here" button (9 -> 11), and overlays.ex's actions-sheet row "What
  # this message is answering" (7 -> 8).
  @expected_required_sites %{
    "assets/css/app.css" => 5,
    "lib/platform_web/components/chat_message.ex" => 11,
    "lib/platform_web/components/chat_message_editor.ex" => 3,
    "lib/platform_web/components/chat_version_history.ex" => 1,
    "lib/platform_web/components/empty_state.ex" => 1,
    "lib/platform_web/components/inbox_item.ex" => 1,
    "lib/platform_web/components/sheet.ex" => 1,
    "lib/platform_web/live/chat/partials.ex" => 9,
    "lib/platform_web/live/chat/partials/overlays.ex" => 8
  }

  @expected_required_total 37

  # ── (a) the scan surface ──────────────────────────────────────────────────

  describe "(a) the scan surface is real" do
    test "the scanned file set is non-empty and contains known carriers" do
      paths = scanned_paths()

      refute paths == [],
             "the census scanned ZERO files. Every assertion in this file is then " <>
               "vacuous: `assert hits == []` passes trivially when nothing was read, " <>
               "and would keep passing forever. The globs are #{inspect(@scan_globs)} " <>
               "relative to #{@app_root}. Fix the globs; do not trust the green."

      for known <- [
            "assets/css/app.css",
            "lib/platform_web/components/chat_message.ex",
            "lib/platform_web/live/chat/partials.ex"
          ] do
        assert known in paths,
               "#{known} is not in the scanned set (#{length(paths)} files scanned). " <>
                 "That file is known to carry focus-ring classes, so its absence means " <>
                 "the glob list no longer covers the code this guard exists to watch."
      end
    end

    test "the exclusion list is exactly this file, and nothing else" do
      assert @excluded == [@self_path],
             "the census exclusion list is #{inspect(@excluded)}, expected exactly " <>
               "[#{inspect(@self_path)}]. Every added entry is a file this guard no " <>
               "longer watches. If a file legitimately needs to name the old class, " <>
               "reword the prose or move it to docs/ — do not carve it out here."
    end

    test "the exclusion is load-bearing: this file's own source carries the literal" do
      source = File.read!(__ENV__.file)

      assert source =~ @forbidden,
             "this file no longer contains #{inspect(@forbidden)}, so the exclusion of " <>
               "#{@self_path} is now a carve-out that protects nothing. Either the " <>
               "search string changed (in which case update @forbidden) or the " <>
               "exclusion should be deleted. A silent unnecessary exclusion is how a " <>
               "census stops covering a file nobody remembers removing."

      unexcluded =
        Path.join(@app_root, "test/**/*.exs")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, @app_root))

      assert @self_path in unexcluded,
             "this file is not matched by the test glob, so it could never have " <>
               "self-matched and the exclusion is untested. The scan globs must cover " <>
               "test/ — a stale assertion pinning the old class is how a repoint " <>
               "half-lands while the suite stays green."

      refute @self_path in scanned_paths(),
             "#{@self_path} is in the scanned set despite being excluded. The " <>
               "exclusion is not being applied and this suite is about to fail on its " <>
               "own source code."
    end
  end

  # ── (b) the detector discriminates ────────────────────────────────────────

  describe "(b) the detector" do
    test "says nothing for text carrying no ring class at all" do
      assert scan_text("x.ex", ~s|class="flex items-center gap-2 rounded"|) == []
    end

    test "says nothing for the CONVERTED class" do
      # This is the case a sloppy matcher gets wrong: the converted class
      # contains both "focus-visible:" and "ring-", and the substring
      # "ring-focus-ring" sits where "ring-primary" used to.
      text = ~s|class="focus-visible:outline-none focus-visible:ring-2 #{@required}"|

      assert scan_text("x.ex", text) == [],
             "the detector flagged the class this task migrated TO. It would red the " <>
               "tree permanently and the only way to green it would be to revert the fix."
    end

    test "says nothing for a bare non-focus ring-primary" do
      # Live in this repo: the meeting speaking indicator uses `ring-primary`
      # and the message-anchor highlight uses `ring-primary/20`. Neither is a
      # focus indicator and neither is in scope for SC 1.4.11 here.
      for text <- [
            ~s|class="ring-2 ring-primary"|,
            ~s|class="ring-1 ring-primary/20"|,
            ~s|assert html =~ "ring-primary"|
          ] do
        assert scan_text("x.ex", text) == [],
               "the detector flagged #{inspect(text)}, which is a legitimate " <>
                 "non-focus use of ring-primary. Flagging it would push someone to " <>
                 "change a speaking indicator or an anchor highlight for no reason."
      end
    end

    test "reports the line for every forbidden form" do
      text = """
      line one is clean
      class="focus-visible:ring-2 focus-visible:ring-primary/60"
      also clean
      class="focus-visible:ring-2 focus-visible:ring-primary/40"
      class="focus-visible:ring-2 focus-visible:ring-primary"
      """

      hits = scan_text("some/file.ex", text)

      assert hits == ["some/file.ex:2", "some/file.ex:4", "some/file.ex:5"],
             "the detector did not report all three forbidden forms (/60, /40 and " <>
               "bare) at their line numbers. Got: #{inspect(hits)}. All three shipped " <>
               "in this repo before task 01a0833d, so all three must be caught."
    end
  end

  # ── (c) the census ────────────────────────────────────────────────────────

  describe "(c) the census" do
    test "no raw #{@forbidden} survives in application code" do
      hits = Enum.flat_map(scanned_paths(), &scan_file/1)

      assert hits == [],
             "raw #{@forbidden} is back in application code, at:\n\n" <>
               Enum.map_join(hits, "\n", &("  " <> &1)) <>
               "\n\nThat utility paints --color-primary at partial opacity: 1.4775:1 " <>
               "on light base-100 at /60, 1.2026:1 on the base-300 hover ground, and " <>
               "at /40 it is under the 3:1 floor in DARK as well. Use " <>
               "`#{@required}` with NO alpha modifier. See " <>
               "docs/design-system/04-accessibility.md section 1.2.1."
    end

    test "the #{@required} call sites are still present, per file" do
      actual = required_sites()
      total = actual |> Map.values() |> Enum.sum()

      assert total >= @expected_required_total,
             "only #{total} #{@required} sites remain, expected at least " <>
               "#{@expected_required_total}. Measured breakdown:\n" <>
               render(actual) <>
               "\nA drop means focus rings were removed rather than converted — the " <>
               "forbidden-string test above passes just as happily when a control has " <>
               "no focus ring at all."

      for {path, expected} <- @expected_required_sites do
        got = Map.get(actual, path, 0)

        assert got == expected,
               "#{path} has #{got} #{@required} sites, expected #{expected}. " <>
                 "Full measured breakdown:\n" <>
                 render(actual) <>
                 "\nThese nine files are pinned because they are the ones task " <>
                 "01a0833d converted; a change here means a ring was added or lost in " <>
                 "a file whose count was deliberate. Update this map in the same " <>
                 "commit and say which control changed."
      end
    end
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  # Relative paths, sorted, with the explicit exclusions removed.
  defp scanned_paths do
    @scan_globs
    |> Enum.flat_map(&Path.wildcard(Path.join(@app_root, &1)))
    |> Enum.map(&Path.relative_to(&1, @app_root))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in @excluded))
    |> Enum.sort()
  end

  defp scan_file(path), do: scan_text(path, read(path))

  defp read(path), do: File.read!(Path.join(@app_root, path))

  # The detector. Returns "path:line" for every line containing the forbidden
  # class. A plain substring match is deliberate: it catches /60, /40, the bare
  # form and any future alpha, while `ring-primary` on its own — which is a
  # legitimate non-focus utility here — cannot match because the "focus-visible:"
  # prefix is part of the needle.
  defp scan_text(path, text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {line, _n} -> String.contains?(line, @forbidden) end)
    |> Enum.map(fn {_line, n} -> "#{path}:#{n}" end)
  end

  defp required_sites do
    scanned_paths()
    |> Enum.map(fn path -> {path, count_occurrences(read(path), @required)} end)
    |> Enum.reject(fn {_path, count} -> count == 0 end)
    |> Map.new()
  end

  defp count_occurrences(text, needle) do
    text |> String.split(needle) |> length() |> Kernel.-(1)
  end

  defp render(map) do
    map
    |> Enum.sort()
    |> Enum.map_join("\n", fn {path, n} -> "  #{n}  #{path}" end)
  end
end
